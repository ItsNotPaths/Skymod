package worldstate

// What an actor wears and holds (sources: build/out/wsP/formulas/equip_*). Every item fills a set of
// engine slots (gamedb.slots_of), held items included; putting one on takes off whatever shares a
// slot. It starts as the actor's outfit, whose gear is part of its starting contents (inv_start); a
// reset puts the outfit back.

import "../gamedb"
import "../actorstate"

// (hole npc-auto-equip :tags ai :sev gap :needs (gear-stats armor-rating)) an NPC never swaps to better armor or picks a weapon from its inventory (UESP Followers): nothing rates gear. Decided: it re-picks when its inventory changes (or every 1 s if that is cheaper); the pick is AI package logic.

Worn :: struct {
	item:  Form_ID,
	slots: gamedb.Slots,
	kept:   bool, // EquipItem's abPreventRemoval: another EquipItem cannot take it off
	outfit: bool, // put on from the actor's outfit; SetOutfit takes it away
	sleep:  bool, // the outfit is its sleep outfit
}

Equipment :: struct {
	worn: [dynamic]Worn,
}

// Equip_Change is one item going on or off, for OnObjectEquipped / OnObjectUnequipped.
Equip_Change :: struct {
	actor, item: Form_ID,
	on:          bool,
}

// equipment is what `actor` wears now; the first read puts on its outfit.
equipment :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> ^Equipment {
	inv_start(ws, db, actor)
	if actor not_in ws.equipment {ws.equipment[actor] = {}}
	return &ws.equipment[actor]
}

// worn_has_keyword: an item the actor wears or holds has the keyword.
worn_has_keyword :: proc(ws: ^World_State, db: ^gamedb.DB, actor, keyword: Form_ID) -> bool {
	for w in equipment(ws, db, actor).worn {
		if gamedb.has_keyword(db, w.item, keyword) {return true}
	}
	return false
}

// equip puts `item` on `actor`, taking off what shares a slot (those go off first). `hand` picks
// the hand for an either-hand item. False when the item equips nowhere or a kept item is in the way.
equip :: proc(ws: ^World_State, db: ^gamedb.DB, actor, item: Form_ID, hand: Maybe(gamedb.Slot) = nil, keep := false) -> bool {
	return put_on(ws, db, equipment(ws, db, actor), actor, item, hand, keep, announce = true)
}

// unequip takes `item` off `actor`; false when it was not worn.
unequip :: proc(ws: ^World_State, db: ^gamedb.DB, actor, item: Form_ID) -> bool {
	eq := equipment(ws, db, actor)
	for w, i in eq.worn {
		if w.item != item {continue}
		ordered_remove(&eq.worn, i)
		append(&ws.equip_changes, Equip_Change{actor, item, false})
		return true
	}
	return false
}

unequip_all :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) {
	eq := equipment(ws, db, actor)
	for len(eq.worn) > 0 {unequip(ws, db, actor, eq.worn[0].item)}
}

is_equipped :: proc(ws: ^World_State, db: ^gamedb.DB, actor, item: Form_ID) -> bool {
	for w in equipment(ws, db, actor).worn {
		if w.item == item {return true}
	}
	return false
}

// in_slot is the item filling `slot` on `actor` (0 = none).
in_slot :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, slot: gamedb.Slot) -> Form_ID {
	for w in equipment(ws, db, actor).worn {
		if slot in w.slots {return w.item}
	}
	return 0
}

// equipped_item_type is GetEquippedItemType for a hand: 0 fists, 1 sword, 2 dagger, 3 war axe,
// 4 mace, 5 greatsword, 6 battleaxe or warhammer, 7 bow, 8 staff, 9 spell or scroll, 10 shield,
// 11 torch, 12 crossbow.
equipped_item_type :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, hand: gamedb.Slot) -> i32 {
	s, ok := gamedb.equip_slot_of(db, in_slot(ws, db, actor, hand))
	if !ok {return 0}
	#partial switch s.kind {
	case .Weapon: return 12 if s.weapon_type == 9 else i32(s.weapon_type)
	case .Spell, .Scroll: return 9
	case .Armor: return 10 // a shield
	case .Light: return 11
	}
	return 0
}

// weapon_anim_type is the right hand's WEAP animation type: 0 hand to hand ... 8 staff, 9 crossbow.
weapon_anim_type :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> i32 {
	s, ok := gamedb.equip_slot_of(db, in_slot(ws, db, actor, .RightHand))
	return i32(s.weapon_type) if ok && s.kind == .Weapon else 0
}

@(private)
put_on :: proc(ws: ^World_State, db: ^gamedb.DB, eq: ^Equipment, actor, item: Form_ID, hand: Maybe(gamedb.Slot), keep, announce: bool, outfit := false, sleep := false) -> bool {
	slots, either := item_slots(ws, db, item)
	if slots == {} {return false}
	if either {slots = {pick_hand(slots, hand)}}
	for w in eq.worn {
		if w.slots & slots != {} && w.kept && w.item != item {return false}
	}
	for i := 0; i < len(eq.worn); {
		w := eq.worn[i]
		if w.slots & slots == {} {i += 1; continue}
		ordered_remove(&eq.worn, i)
		if announce {append(&ws.equip_changes, Equip_Change{actor, w.item, false})}
	}
	append(&eq.worn, Worn{item, slots, keep, outfit, sleep})
	if announce {append(&ws.equip_changes, Equip_Change{actor, item, true})}
	return true
}

// pick_hand chooses one of an either-hand item's slots: the asked hand, else the right. EquipItem has
// no hand and "always just equips items in the right hand"; the player picks one in the menu
// (build/out/wsP/research/findings.md section 4).
@(private)
pick_hand :: proc(choices: gamedb.Slots, hand: Maybe(gamedb.Slot)) -> gamedb.Slot {
	if h, ok := hand.?; ok && h in choices {return h}
	return .RightHand if .RightHand in choices else .LeftHand
}

// wear_outfit puts the first read's outfit gear on, without events.
@(private)
wear_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, gear: []gamedb.Content_Entry) {
	if actor not_in ws.equipment {ws.equipment[actor] = {}}
	eq := &ws.equipment[actor]
	for e in gear {put_on(ws, db, eq, actor, e.item, nil, false, false, outfit = true)}
}

// outfit_items is the gear list of an actor's outfit, or of its sleep outfit: one a script set on
// the actor or its NPC_, else its records'.
outfit_items :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, sleep := false) -> []Form_ID {
	record := record_of(ws, actor)
	base := record
	if r, ok := gamedb.ref_by_formid(db, record); ok {base = r.base}
	set := &ws.sleep_outfits if sleep else &ws.outfits
	for key in ([2]Form_ID{actor, base}) {
		if o, ok := set[key]; ok {return db.outfits[o]}
	}
	return gamedb.outfit_of(db, record, actor_pick(ws, db, actor), sleep)
}

// wear_spare_armor puts on armor from the actor's inventory where nothing is worn: its outfit, after
// it was taken off, or what it was given.
wear_spare_armor :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) {
	eq := equipment(ws, db, actor)
	for item in inv_items(ws, db, actor) {
		s, ok := db.equip_slots[item]
		slots, _ := gamedb.slots_of(db, item)
		if !ok || s.kind != .Armor || slots == {} || worn_in(eq, slots) {continue}
		put_on(ws, db, eq, actor, item, nil, false, true)
	}
}

@(private = "file")
worn_in :: proc(eq: ^Equipment, slots: gamedb.Slots) -> bool {
	for w in eq.worn {
		if w.slots & slots != {} {return true}
	}
	return false
}

// set_outfit is SetOutfit: `outfit` becomes the actor's outfit, or its sleep outfit. It stays
// through resets; the actor changes into it now if it wears that kind.
set_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor, outfit: Form_ID, sleep := false) {
	(&ws.sleep_outfits if sleep else &ws.outfits)[actor] = outfit
	items, _ := db.outfits[outfit] // not `for x in m[k]`: a missing key hangs (odin-map-index-iteration)
	if in_sleep_outfit(ws, db, actor) == sleep {dress(ws, db, actor, items, sleep)}
}

// restore_outfit puts an actor back in the outfit it wore before a jail outfit: a script's, or with
// 0 its records'.
restore_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor, outfit: Form_ID) {
	if outfit != 0 {
		set_outfit(ws, db, actor, outfit)
		return
	}
	delete_key(&ws.outfits, actor)
	dress(ws, db, actor, outfit_items(ws, db, actor), false)
}

// apply_state_changes does what follows the actor-state changes since the last call: an actor with
// a sleep outfit changes into it or out.
apply_state_changes :: proc(ws: ^World_State, db: ^gamedb.DB) {
	changes := make([dynamic]actorstate.Change, context.temp_allocator)
	actorstate.drain(&ws.states, &changes)
	for c in changes {
		if (c.from == actorstate.SLEEP) != (c.to == actorstate.SLEEP) {sleep_outfit(ws, db, c.actor, c.to == actorstate.SLEEP)}
	}
}

@(private = "file")
sleep_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, asleep: bool) {
	if asleep == in_sleep_outfit(ws, db, actor) || len(outfit_items(ws, db, actor, true)) == 0 {return}
	dress(ws, db, actor, outfit_items(ws, db, actor, asleep), asleep)
}

@(private)
in_sleep_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> bool {
	for w in equipment(ws, db, actor).worn {
		if w.outfit {return w.sleep}
	}
	return false
}

// dress changes an actor's outfit gear: the old gear is taken off and out of its inventory, the
// new, rolled at the player's level, goes in and on.
@(private)
dress :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, items: []Form_ID, sleep: bool) {
	eq := equipment(ws, db, actor)
	for i := 0; i < len(eq.worn); {
		w := eq.worn[i]
		if !w.outfit {i += 1; continue}
		ordered_remove(&eq.worn, i)
		append(&ws.equip_changes, Equip_Change{actor, w.item, false})
		inv_add(ws, actor, w.item, -1)
		move_items(ws, {base = w.item, from = actor, count = 1})
	}
	gear := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	for item in items {roll(ws, db, item, player_level(ws, db), 1, &gear)}
	for e in gear {
		inv_add(ws, actor, e.item, e.count)
		move_items(ws, {base = e.item, to = actor, count = e.count})
		put_on(ws, db, eq, actor, e.item, nil, false, true, outfit = true, sleep = sleep)
	}
}

@(private)
drop_equipment :: proc(ws: ^World_State, actor: Form_ID) {
	if eq, ok := ws.equipment[actor]; ok {delete(eq.worn)}
	delete_key(&ws.equipment, actor)
}
