package worldstate

// What an actor wears and holds (sources: build/out/wsP/formulas/equip_*). It starts as the actor's
// outfit, whose gear is part of its starting contents (inv_start); a reset puts the outfit back.

import "core:slice"
import "../gamedb"

// (hole equip-effects :tags (magic combat player) :sev gap :needs (effect-archetypes)) worn gear changes nothing: armor rating, weapon damage and enchantments (EITM) are not read.
// (hole npc-auto-equip :tags (ai player) :sev gap) an NPC never picks better gear from its inventory or puts its outfit back on (UESP Followers); it wears its outfit until a script changes it.
// (hole either-hand-placement :tags player :sev polish) an either-hand item goes right, else left when right is taken, else replaces right: unsourced. The player's left-hand one-handers need a hand choice from the UI.
// (hole potion-equip :tags (magic player) :sev gap) EquipItem on a potion or food should drink it; it does nothing.

// Hand is a Papyrus hand or casting source: 0 left, 1 right, 2 voice.
Hand :: enum u8 {
	Left,
	Right,
	Voice,
}

Equipment :: struct {
	armor: [dynamic]Form_ID, // worn armor, shields included; no two share a biped slot
	hands: [Hand]Form_ID,    // weapon, spell, scroll, torch or shield; a both-hands item fills Left and Right
	ammo:  Form_ID,
	kept:  [dynamic]Form_ID, // EquipItem's abPreventRemoval: another EquipItem cannot take these off
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

// equip puts `item` on `actor` by its slot, taking off what shares it (those go off first). `hand`
// picks a hand for an either-hand item. False when the item equips nowhere or a kept item is in the
// way.
equip :: proc(ws: ^World_State, db: ^gamedb.DB, actor, item: Form_ID, hand: Maybe(Hand) = nil, keep := false) -> bool {
	return put_on(ws, db, equipment(ws, db, actor), actor, item, hand, keep, announce = true)
}

// unequip takes `item` off `actor`; false when it was not worn.
unequip :: proc(ws: ^World_State, db: ^gamedb.DB, actor, item: Form_ID) -> bool {
	eq := equipment(ws, db, actor)
	if !worn(eq^, item) {return false}
	take_off(eq, item)
	append(&ws.equip_changes, Equip_Change{actor, item, false})
	return true
}

unequip_all :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) {
	for item in worn_items(equipment(ws, db, actor)^) {unequip(ws, db, actor, item)}
}

is_equipped :: proc(ws: ^World_State, db: ^gamedb.DB, actor, item: Form_ID) -> bool {
	return worn(equipment(ws, db, actor)^, item)
}

// worn_items lists everything worn or held, each once.
worn_items :: proc(eq: Equipment) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for a in eq.armor {append(&out, a)}
	for h in eq.hands {
		if h != 0 && !slice.contains(out[:], h) {append(&out, h)}
	}
	if eq.ammo != 0 {append(&out, eq.ammo)}
	return out[:]
}

@(private)
worn :: proc(eq: Equipment, item: Form_ID) -> bool {
	return item != 0 && slice.contains(worn_items(eq), item)
}

@(private)
put_on :: proc(ws: ^World_State, db: ^gamedb.DB, eq: ^Equipment, actor, item: Form_ID, hand: Maybe(Hand), keep, announce: bool) -> bool {
	slot, ok := gamedb.equip_slot_of(db, item)
	if !ok || slot.etyp == gamedb.EQUP_POTION {return false}
	hands, held := hands_for(eq^, slot, hand)
	off := make([dynamic]Form_ID, context.temp_allocator)
	switch {
	case slot.kind == .Ammo:
		if eq.ammo != 0 {append(&off, eq.ammo)}
	case slot.biped != 0:
		for a in eq.armor {
			if s, _ := gamedb.equip_slot_of(db, a); s.biped & slot.biped != 0 {append(&off, a)}
		}
		if held {append_hand(eq^, .Left, &off)}
	case held:
		for h in hands {append_hand(eq^, h, &off)}
	case:
		return false
	}
	for o in off {
		if o != item && slice.contains(eq.kept[:], o) {return false}
	}
	for o in off {
		take_off(eq, o)
		if announce {append(&ws.equip_changes, Equip_Change{actor, o, false})}
	}
	switch {
	case slot.kind == .Ammo:
		eq.ammo = item
	case slot.biped != 0:
		append(&eq.armor, item)
		if held {eq.hands[.Left] = item}
	case:
		for h in hands {eq.hands[h] = item}
	}
	if keep {append(&eq.kept, item)}
	if announce {append(&ws.equip_changes, Equip_Change{actor, item, true})}
	return true
}

// hands_for is the hands an item takes by its equip type: a shield takes the left hand beside its
// biped slot, a torch the left, a shout the voice.
@(private)
hands_for :: proc(eq: Equipment, slot: gamedb.Equip_Slot, hand: Maybe(Hand)) -> (hands: []Hand, ok: bool) {
	@(static, rodata) LEFT := [1]Hand{.Left}
	@(static, rodata) RIGHT := [1]Hand{.Right}
	@(static, rodata) VOICE := [1]Hand{.Voice}
	@(static, rodata) BOTH := [2]Hand{.Left, .Right}
	switch {
	case slot.etyp == gamedb.EQUP_SHIELD, slot.kind == .Light, slot.etyp == gamedb.EQUP_LEFT_HAND:
		return LEFT[:], true
	case slot.etyp == gamedb.EQUP_VOICE, slot.kind == .Shout:
		return VOICE[:], true
	case slot.etyp == gamedb.EQUP_BOTH_HANDS:
		return BOTH[:], true
	case slot.etyp == gamedb.EQUP_RIGHT_HAND:
		return RIGHT[:], true
	case slot.biped != 0, slot.kind == .Ammo:
		return nil, false
	}
	h, chosen := hand.?
	if !chosen {h = .Left if eq.hands[.Right] != 0 && eq.hands[.Left] == 0 else .Right}
	return LEFT[:] if h == .Left else RIGHT[:], true
}

@(private)
append_hand :: proc(eq: Equipment, h: Hand, off: ^[dynamic]Form_ID) {
	if x := eq.hands[h]; x != 0 && !slice.contains(off[:], x) {append(off, x)}
}

@(private)
take_off :: proc(eq: ^Equipment, item: Form_ID) {
	remove_id(&eq.armor, item)
	remove_id(&eq.kept, item)
	for &h in eq.hands {
		if h == item {h = 0}
	}
	if eq.ammo == item {eq.ammo = 0}
}

// wear_outfit puts the first read's outfit gear on, without events.
@(private)
wear_outfit :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, gear: []gamedb.Content_Entry) {
	if actor not_in ws.equipment {ws.equipment[actor] = {}}
	eq := &ws.equipment[actor]
	for e in gear {put_on(ws, db, eq, actor, e.item, nil, false, false)}
}

@(private)
drop_equipment :: proc(ws: ^World_State, actor: Form_ID) {
	if eq, ok := ws.equipment[actor]; ok {
		delete(eq.armor)
		delete(eq.kept)
	}
	delete_key(&ws.equipment, actor)
}
