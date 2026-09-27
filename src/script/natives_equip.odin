package script

// What actors wear and hold (worldstate.Equipment; CK wiki pages in build/out/wsP/formulas/equip_*).
// Papyrus numbers hands and casting sources 0 left, 1 right, 2 voice.

import "../gamedb"
import "../worldstate"

register_equip :: proc(reg: ^Registry) {
	register(reg, "Actor", "EquipItem", n_equip_item)
	register(reg, "Actor", "UnequipItem", n_unequip_item)
	register(reg, "Actor", "IsEquipped", n_is_equipped)
	register(reg, "Actor", "UnequipAll", n_unequip_all)
	register(reg, "Actor", "UnequipItemSlot", n_unequip_item_slot)
	register(reg, "Actor", "GetEquippedArmorInSlot", n_get_equipped_armor_in_slot)
	register(reg, "Actor", "EquipSpell", n_equip_spell)
	register(reg, "Actor", "UnequipSpell", n_unequip_spell)
	register(reg, "Actor", "GetEquippedSpell", n_get_equipped_spell)
	register(reg, "Actor", "EquipShout", n_equip_shout)
	register(reg, "Actor", "UnequipShout", n_unequip_shout)
	register(reg, "Actor", "GetEquippedShout", n_get_equipped_shout)
	register(reg, "Actor", "GetEquippedItemType", n_get_equipped_item_type)
	register(reg, "Actor", "GetEquippedWeapon", n_get_equipped_weapon)
	register(reg, "Actor", "GetEquippedShield", n_get_equipped_shield)
	register(reg, "Actor", "SetOutfit", n_set_outfit)
	register(reg, "ActorBase", "SetOutfit", n_base_set_outfit)
}

// Actor.SetOutfit(akOutfit, abSleepOutfit=false): the actor changes into it now if it wears that kind.
n_set_outfit :: proc(c: ^Call, args: []Value) -> Value {
	if outfit := arg_form(args, 0); outfit != 0 {worldstate.set_outfit(c.ws, c.db, c.self, outfit, arg_bool(args, 1, false))}
	return nil
}

// ActorBase.SetOutfit(akOutfit, abSleepOutfit=false): the base's default outfit; actors already
// dressed keep theirs until they reset.
n_base_set_outfit :: proc(c: ^Call, args: []Value) -> Value {
	if outfit := arg_form(args, 0); outfit != 0 {(&c.ws.sleep_outfits if arg_bool(args, 1, false) else &c.ws.outfits)[c.self] = outfit}
	return nil
}

// EquipItem(akItem, abPreventRemoval=false, abSilent=false): an actor without the item is given one.
// A leveled list does not work (CK wiki). A potion or food is drunk.
n_equip_item :: proc(c: ^Call, args: []Value) -> Value {
	base, _ := item_of(c, arg_form(args, 0))
	if _, leveled := gamedb.leveled_list_of(c.db, base); leveled || base == 0 {return nil}
	if worldstate.inv_count(c.ws, c.db, c.self, base) == 0 {move_items(c, {base = base, to = c.self, count = 1})}
	if drink(c, c.self, base) {return nil}
	worldstate.equip(c.ws, c.db, c.self, base, keep = arg_bool(args, 1, false))
	return nil
}

n_unequip_item :: proc(c: ^Call, args: []Value) -> Value {
	base, _ := item_of(c, arg_form(args, 0))
	worldstate.unequip(c.ws, c.db, c.self, base)
	return nil
}

// IsEquipped(akItem): a form list asks for any of its members.
n_is_equipped :: proc(c: ^Call, args: []Value) -> Value {
	item := arg_form(args, 0)
	authored, is_list := gamedb.form_list_of(c.db, item)
	if !is_list {return worldstate.is_equipped(c.ws, c.db, c.self, item)}
	for f in authored {if worldstate.is_equipped(c.ws, c.db, c.self, f) {return true}}
	for f in worldstate.list_added(c.ws, item) {if worldstate.is_equipped(c.ws, c.db, c.self, f) {return true}}
	return false
}

n_unequip_all :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.unequip_all(c.ws, c.db, c.self)
	return nil
}

n_unequip_item_slot :: proc(c: ^Call, args: []Value) -> Value {
	if armor := armor_in_slot(c, arg_i32(args, 0, 0)); armor != 0 {worldstate.unequip(c.ws, c.db, c.self, armor)}
	return nil
}

n_get_equipped_armor_in_slot :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(armor_in_slot(c, arg_i32(args, 0, 0)))
}

// armor_in_slot is the worn item filling biped slot `slot` (30 = head), through the engine slots it
// maps to.
@(private)
armor_in_slot :: proc(c: ^Call, slot: i32) -> Form_ID {
	if slot < 30 || slot > 61 {return 0}
	for s in gamedb.BIPED_SLOTS[slot - 30] {
		if item := worldstate.in_slot(c.ws, c.db, c.self, s); item != 0 {return item}
	}
	return 0
}

// EquipSpell(akSpell, aiSource): the spell's own equip slot wins over aiSource; an either-hand spell
// goes where aiSource says.
n_equip_spell :: proc(c: ^Call, args: []Value) -> Value {
	h, ok := hand_arg(args, 1)
	if !ok {return nil}
	worldstate.equip(c.ws, c.db, c.self, arg_form(args, 0), h)
	return nil
}

n_unequip_spell :: proc(c: ^Call, args: []Value) -> Value {
	spell := arg_form(args, 0)
	if h, ok := hand_arg(args, 1); ok && held(c, h) == spell {worldstate.unequip(c.ws, c.db, c.self, spell)}
	return nil
}

// GetEquippedSpell(aiSource): 3 (instant) holds nothing here.
n_get_equipped_spell :: proc(c: ^Call, args: []Value) -> Value {
	h, ok := hand_arg(args, 0)
	if !ok {return nil}
	return form_or_none(held_kind(c, h, .Spell))
}

n_equip_shout :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.equip(c.ws, c.db, c.self, arg_form(args, 0), .Voice)
	return nil
}

n_unequip_shout :: proc(c: ^Call, args: []Value) -> Value {
	if shout := arg_form(args, 0); held(c, .Voice) == shout {worldstate.unequip(c.ws, c.db, c.self, shout)}
	return nil
}

n_get_equipped_shout :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(held_kind(c, .Voice, .Shout))
}

n_get_equipped_item_type :: proc(c: ^Call, args: []Value) -> Value {
	h, ok := hand_arg(args, 0)
	if !ok || h == .Voice {return i32(0)}
	return worldstate.equipped_item_type(c.ws, c.db, c.self, h)
}

n_get_equipped_weapon :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(held_kind(c, .LeftHand if arg_bool(args, 0, false) else .RightHand, .Weapon))
}

n_get_equipped_shield :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(worldstate.in_slot(c.ws, c.db, c.self, .Shield))
}

// hand_arg reads a Papyrus hand or casting source: 0 left, 1 right, 2 voice.
@(private)
hand_arg :: proc(args: []Value, i: int) -> (gamedb.Slot, bool) {
	switch arg_i32(args, i, 0) {
	case 0: return .LeftHand, true
	case 1: return .RightHand, true
	case 2: return .Voice, true
	}
	return {}, false
}

@(private)
held :: proc(c: ^Call, h: gamedb.Slot) -> Form_ID {
	return worldstate.in_slot(c.ws, c.db, c.self, h)
}

// held_kind is what hand `h` holds when it is of `kind`.
@(private)
held_kind :: proc(c: ^Call, h: gamedb.Slot, kind: gamedb.Equip_Kind) -> Form_ID {
	item := held(c, h)
	if s, ok := gamedb.equip_slot_of(c.db, item); ok && s.kind == kind {return item}
	return 0
}
