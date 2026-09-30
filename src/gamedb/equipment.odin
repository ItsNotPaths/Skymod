package gamedb

// Where items go on an actor. The engine has its own named slots; Skyrim's data maps onto them: each
// biped bit (ARMO BOD2/BODT, slot 30 = bit 0) to a fixed set of slots, no two bits sharing one, so
// every plugin item keeps exactly the conflicts it has in Skyrim; each equip type (EQUP) to hands.

import "../formats/esm"

// (hole equip-slot-hook :tags mods :sev wish) a plugin item can only reach the slots its 32 biped bits map to; nothing lets a mod's item take a finer slot (LeftShoulder alone) or a slot of its own: a keyword such as EquipSlotCloak, or a script call. Deferred: armor stays keyed by biped bit number.
// Slots 44-60 have no Bethesda names. Their names follow the CK wiki Biped Object page, "Suggested
// Use of Additional Nodes", the modding community's standard (build/out/wsP/research/findings.md).

Slot :: enum u8 {
	Head,
	Hair,
	Torso,
	LeftGlove,
	RightGlove,
	LeftForearm,
	RightForearm,
	Neck,
	LeftRing,
	RightRing,
	LeftFoot,
	RightFoot,
	LeftCalf,
	RightCalf,
	Shield,
	Tail,
	LongHair,
	Circlet,
	Ears,
	Face,        // 44
	Scarf,       // 45
	ChestOuter,  // 46
	Back,        // 47
	Misc1,       // 48
	PelvisOuter, // 49
	DecapitatedHead, // 50
	Decapitation,    // 51
	PelvisUnder,     // 52
	LegOuter,        // 53
	LegUnder,        // 54
	FaceJewelry,     // 55
	ChestUnder,      // 56
	LeftShoulder,    // 57
	RightShoulder,
	ArmUnder,        // 58
	ArmOuter,        // 59
	Misc2,           // 60
	Effect,          // 61
	LeftHand,
	RightHand,
	Voice,
	Ammo,
}

Slots :: bit_set[Slot]

// BIPED_SLOTS maps biped slot 30 + i to the engine slots it fills.
BIPED_SLOTS := [32]Slots {
	{.Head}, {.Hair}, {.Torso}, {.LeftGlove, .RightGlove}, {.LeftForearm, .RightForearm}, {.Neck},
	{.LeftRing, .RightRing}, {.LeftFoot, .RightFoot}, {.LeftCalf, .RightCalf}, {.Shield}, {.Tail},
	{.LongHair}, {.Circlet}, {.Ears}, {.Face}, {.Scarf}, {.ChestOuter}, {.Back}, {.Misc1}, {.PelvisOuter},
	{.DecapitatedHead}, {.Decapitation}, {.PelvisUnder}, {.LegOuter}, {.LegUnder}, {.FaceJewelry},
	{.ChestUnder}, {.LeftShoulder, .RightShoulder}, {.ArmUnder}, {.ArmOuter}, {.Misc2}, {.Effect},
}

// biped_slots is the engine slots a biped mask fills.
biped_slots :: proc(mask: u32) -> Slots {
	s: Slots
	for i in 0 ..< u32(32) {
		if mask & (1 << i) != 0 {s += BIPED_SLOTS[i]}
	}
	return s
}

Equip_Slot :: struct {
	kind:        Equip_Kind,
	biped:       u32,     // biped mask, bit 0 = slot 30; 0 = not armor
	etyp:        Form_ID, // the EQUP it equips as; 0 = none authored
	weapon_type: u8,      // WEAP DNAM animation type: 0 hand to hand, 1 sword ... 8 staff, 9 crossbow
	enchantment: Form_ID, // EITM: the ENCH it carries; 0 = none
	damage:      f32,     // WEAP DATA u16, AMMO DATA f32
	projectile:  Form_ID, // AMMO: the PROJ it flies as
	gear:        esm.Gear, // crit_spell remapped
}

Equip_Kind :: enum u8 {
	Armor,
	Weapon,
	Spell,
	Scroll,
	Shout,
	Ammo,
	Light,
}

// The vanilla EQUP forms (Skyrim.esm) with no parents: every other equip type is built from these.
EQUP_RIGHT_HAND :: Form_ID(0x13F42)
EQUP_LEFT_HAND :: Form_ID(0x13F43)
EQUP_VOICE :: Form_ID(0x25BEE)
EQUP_POTION :: Form_ID(0x35698)

// Equip_Type is an EQUP: the slots it stands for, all of them (BothHands) or any one (EitherHand).
Equip_Type :: struct {
	parents: []Form_ID, // owned
	use_all: bool,
}

@(private)
equip_kind :: proc(s: string) -> (Equip_Kind, bool) {
	switch s {
	case "ARMO": return .Armor, true
	case "WEAP": return .Weapon, true
	case "SPEL": return .Spell, true
	case "SCRL": return .Scroll, true
	case "SHOU": return .Shout, true
	case "AMMO": return .Ammo, true
	case "LIGH": return .Light, true
	}
	return {}, false
}

// index_equip records where an equippable form goes. A LIGH only counts when it can be carried (a
// torch).
@(private)
index_equip :: proc(db: ^DB, rec: esm.Record, kind: Equip_Kind, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if kind == .Light && !esm.light_carried(fl) {
		delete_key(&db.equip_slots, rec.form_id)
		return
	}
	slot := Equip_Slot{kind = kind}
	slot.biped, _ = esm.biped_slots(fl)
	if e, has := esm.subrecord_formid(fl, "ETYP"); has {slot.etyp = esm.remap_form(fm, e)}
	if f, has := esm.find_field(fl, "DNAM"); has && kind == .Weapon && len(f.data) >= 1 {slot.weapon_type = f.data[0]}
	if e, has := esm.subrecord_formid(fl, "EITM"); has {slot.enchantment = esm.remap_form(fm, e)}
	damage, projectile := esm.item_damage(rec.type, fl)
	slot.damage, slot.projectile = damage, esm.remap_form(fm, projectile)
	slot.gear = esm.gear(rec.type, fl)
	slot.gear.crit_spell = esm.remap_form(fm, u32(slot.gear.crit_spell))
	db.equip_slots[rec.form_id] = slot
}

@(private)
index_equip_type :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	raw, use_all := esm.equip_type(fl, context.allocator)
	defer delete(raw)
	parents := make([]Form_ID, len(raw), db.allocator)
	for p, i in raw {parents[i] = esm.remap_form(fm, p)}
	if old, seen := db.equip_types[rec.form_id]; seen {delete(old.parents, db.allocator)}
	db.equip_types[rec.form_id] = {parents, use_all}
}

// equip_slot_of is what the records say about a base item's equipping; ok=false for a form that
// equips nowhere.
equip_slot_of :: proc(db: ^DB, item: Form_ID) -> (Equip_Slot, bool) {
	s, ok := db.equip_slots[item]
	return s, ok
}

// slots_of is the engine slots an item fills: all of them, or one of them when `either` (an
// either-hand item). Empty when it equips nowhere (a potion).
slots_of :: proc(db: ^DB, item: Form_ID) -> (slots: Slots, either: bool) {
	s, ok := db.equip_slots[item]
	if !ok {return}
	slots = biped_slots(s.biped)
	switch {
	case s.etyp != 0:
		hands, one := etyp_slots(db, s.etyp)
		return slots + hands, one
	case s.kind == .Shout:
		return {.Voice}, false
	case s.kind == .Ammo:
		return {.Ammo}, false
	case s.kind == .Light:
		return {.LeftHand}, false
	case s.kind != .Armor:
		return {.LeftHand, .RightHand}, true // a weapon or spell with no equip type
	}
	return
}

// etyp_slots resolves an equip type through its parents to the hand slots it fills.
@(private)
etyp_slots :: proc(db: ^DB, etyp: Form_ID, depth := 0) -> (slots: Slots, either: bool) {
	switch etyp {
	case EQUP_RIGHT_HAND: return {.RightHand}, false
	case EQUP_LEFT_HAND:  return {.LeftHand}, false
	case EQUP_VOICE:      return {.Voice}, false
	case EQUP_POTION:     return {}, false
	}
	t, ok := db.equip_types[etyp]
	if !ok || depth > 4 {return}
	for p in t.parents {
		s, _ := etyp_slots(db, p, depth + 1)
		slots += s
	}
	return slots, !t.use_all && card(slots) > 1
}

// outfit_of is the gear an actor starts wearing: its DOFT outfit's items (SOFT when `sleep`),
// following ref → base and the inventory template (`pick` standing in for a leveled one). Entries
// may be leveled lists.
outfit_of :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0, sleep := false) -> []Form_ID {
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	if base not_in db.actors {return nil}
	a := template_part(db, base, esm.ACBS_TEMPLATE_INVENTORY, pick)
	return db.outfits[a.sleep_outfit if sleep else a.outfit]
}
