package gamedb

// Where items go on an actor: armor by its biped slot mask, weapons, spells and scrolls by their
// equip type (EQUP: RightHand, LeftHand, EitherHand, BothHands, Shield, Voice, Potion).

import "../formats/esm"

Equip_Slot :: struct {
	kind:        Equip_Kind,
	biped:       u32,     // ARMO slot mask, bit 0 = slot 30; 0 = not armor
	etyp:        Form_ID, // the EQUP it equips as; 0 = none authored
	weapon_type: u8,      // WEAP DNAM animation type: 0 hand to hand, 1 sword ... 8 staff, 9 crossbow
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

// The vanilla EQUP forms (Skyrim.esm) the slot rules name.
EQUP_RIGHT_HAND :: Form_ID(0x13F42)
EQUP_LEFT_HAND :: Form_ID(0x13F43)
EQUP_EITHER_HAND :: Form_ID(0x13F44)
EQUP_BOTH_HANDS :: Form_ID(0x13F45)
EQUP_SHIELD :: Form_ID(0x141E8)
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

// equip_slot_of is where a base item equips; ok=false for a form that equips nowhere authored.
equip_slot_of :: proc(db: ^DB, item: Form_ID) -> (Equip_Slot, bool) {
	s, ok := db.equip_slots[item]
	return s, ok
}

// outfit_of is the gear an actor starts wearing: its DOFT outfit's items, following ref → base and the
// inventory template (`pick` standing in for a leveled one). Entries may be leveled lists.
outfit_of :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> []Form_ID {
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	a, ok := db.actors[base]
	if !ok {return nil}
	return db.outfits[template_part(db, a, esm.ACBS_TEMPLATE_INVENTORY, pick).outfit]
}
