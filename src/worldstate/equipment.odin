package worldstate

// What an actor wears and holds (sources: build/out/wsP/formulas/equip_*). Every item fills a set of
// engine slots (gamedb.slots_of), held items included; putting one on takes off whatever shares a
// slot. It starts as the actor's outfit, whose gear is part of its starting contents (inv_start); a
// reset puts the outfit back.

import "../gamedb"

// (hole gear-stats :tags (combat player) :sev gap :needs (combat-damage)) armor rating (ARMO DNAM) and weapon damage (WEAP DATA) are not read; worn gear only brings its constant-effect enchantment (script.sync_constant_effects).
// (hole npc-auto-equip :tags ai :sev gap) an NPC never picks better gear from its inventory or puts its outfit back on (UESP Followers). Decided: it re-picks when its inventory changes (or every 1 s if that is cheaper); the pick is AI package logic.

Worn :: struct {
	item:  Form_ID,
	slots: gamedb.Slots,
	kept:   bool, // EquipItem's abPreventRemoval: another EquipItem cannot take it off
	outfit: bool, // put on from the actor's outfit; SetOutfit takes it away
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

@(private)
put_on :: proc(ws: ^World_State, db: ^gamedb.DB, eq: ^Equipment, actor, item: Form_ID, hand: Maybe(gamedb.Slot), keep, announce: bool, outfit := false) -> bool {
	slots, either := gamedb.slots_of(db, item)
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
	append(&eq.worn, Worn{item, slots, keep, outfit})
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

// outfit_items is the gear list of an actor's outfit: one a script set on the actor or its NPC_,
// else its records'.
outfit_items :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> []Form_ID {
	record := record_of(ws, actor)
	base := record
	if r, ok := gamedb.ref_by_formid(db, record); ok {base = r.base}
	for key in ([2]Form_ID{actor, base}) {
		if o, ok := ws.outfits[key]; ok {return db.outfits[o]}
	}
	return gamedb.outfit_of(db, record, actor_pick(ws, db, actor))
}

// (hole sleep-outfits :tags (ai player) :sev gap :needs (ai-agent)) SetOutfit(abSleepOutfit = true) is ignored: nothing sleeps, so no actor changes into its sleep outfit (NPC_ SOFT is not read).
// set_outfit dresses `actor` in `outfit`: the old outfit's gear is taken off and out of its
// inventory, the new gear, rolled at the player's level, goes in and on. It stays through resets.
set_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor, outfit: Form_ID) {
	eq := equipment(ws, db, actor)
	for i := 0; i < len(eq.worn); {
		w := eq.worn[i]
		if !w.outfit {i += 1; continue}
		ordered_remove(&eq.worn, i)
		append(&ws.equip_changes, Equip_Change{actor, w.item, false})
		inv_add(ws, actor, w.item, -1)
		move_items(ws, {base = w.item, from = actor, count = 1})
	}
	ws.outfits[actor] = outfit
	gear := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	items, _ := db.outfits[outfit] // not `for x in m[k]`: a missing key hangs (odin-map-index-iteration)
	for item in items {roll(ws, db, item, player_level(ws, db), 1, &gear)}
	for e in gear {
		inv_add(ws, actor, e.item, e.count)
		move_items(ws, {base = e.item, to = actor, count = e.count})
		put_on(ws, db, eq, actor, e.item, nil, false, true, outfit = true)
	}
}

@(private)
drop_equipment :: proc(ws: ^World_State, actor: Form_ID) {
	if eq, ok := ws.equipment[actor]; ok {delete(eq.worn)}
	delete_key(&ws.equipment, actor)
}
