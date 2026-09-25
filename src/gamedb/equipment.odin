package gamedb

// Where items go on an actor: armor by its biped slot mask, weapons, spells and scrolls by their
// equip type (EQUP: RightHand, LeftHand, EitherHand, BothHands, Shield, Voice, Potion).

import "../formats/esm"

Equip_Slot :: struct {
	biped: u32,     // ARMO slot mask, bit 0 = slot 30; 0 = not armor
	etyp:  Form_ID, // the EQUP it equips as; 0 = none authored
}

// Equip_Type is an EQUP: the slots it stands for, all of them (BothHands) or any one (EitherHand).
Equip_Type :: struct {
	parents: []Form_ID, // owned
	use_all: bool,
}

@(private)
carries_equip :: proc(s: string) -> bool {
	switch s {
	case "ARMO", "WEAP", "SPEL", "SCRL", "SHOU", "AMMO", "LIGH":
		return true
	}
	return false
}

@(private)
index_equip :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	slot: Equip_Slot
	slot.biped, _ = esm.biped_slots(fl)
	if e, has := esm.subrecord_formid(fl, "ETYP"); has {slot.etyp = esm.remap_form(fm, e)}
	if slot == {} {
		delete_key(&db.equip_slots, rec.form_id)
		return
	}
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
