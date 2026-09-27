package gamedb

// Records behind the query natives (Workstream L): ownership, activate parents,
// ingredient effects and Papyrus load-order form ids.

import "../formats/esm"
import "../formid"

// index_ref_ties records a placement's XOWN owner and XAPR activate parents; an override without
// them drops the earlier plugin's.
@(private)
index_ref_ties :: proc(db: ^DB, id: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	index_owner(db, id, fl, fm)
	if old, ok := db.activate_parents[id]; ok {
		delete(old, db.allocator)
		delete_key(&db.activate_parents, id)
	}
	raw := esm.activate_parents(fl, context.allocator)
	if raw == nil {return}
	defer delete(raw, context.allocator)
	parents := make([]Form_ID, len(raw), db.allocator)
	for p, i in raw {parents[i] = esm.remap_form(fm, p)}
	db.activate_parents[id] = parents
}

// index_owner records a ref's or a cell's XOWN owner, an NPC_ or a FACT.
@(private)
index_owner :: proc(db: ^DB, id: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	if o, ok := esm.subrecord_formid(fl, "XOWN"); ok {
		db.owners[id] = esm.remap_form(fm, o)
	} else {
		delete_key(&db.owners, id)
	}
}

// index_ingredient keeps an INGR's effects apart from the potions: eating one applies only its first.
@(private)
index_ingredient :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, existed := db.ingredients[rec.form_id]; existed {free_effects(db, old)}
	db.ingredients[rec.form_id] = index_effects(db, fl, fm)
}

@(private)
free_query_indexes :: proc(db: ^DB) {
	delete(db.owners)
	for _, p in db.activate_parents {delete(p, db.allocator)}
	delete(db.activate_parents)
	for _, e in db.ingredients {free_effects(db, e)}
	delete(db.ingredients)
	delete(db.load_slots)
}

// owner_of is a ref's or a cell's authored owner; 0 when none.
owner_of :: proc(db: ^DB, form: Form_ID) -> Form_ID {
	return db.owners[form]
}

// is_activate_child: `child` names `parent` among its activate parents.
is_activate_child :: proc(db: ^DB, parent, child: Form_ID) -> bool {
	for p in db.activate_parents[child] or_else nil {
		if p == parent {return true}
	}
	return false
}

ingredient_effects :: proc(db: ^DB, ingredient: Form_ID) -> []Magic_Effect_Ref {
	return db.ingredients[ingredient]
}

// PAPYRUS_CREATED is the load-order byte Papyrus gives runtime-created forms.
PAPYRUS_CREATED :: u32(0xFF)

// form_by_load_id is Game.GetForm: a Papyrus form id's high byte is a load-order index. 0 when no
// plugin has that index. Whether the form exists is not checked.
form_by_load_id :: proc(db: ^DB, id: u32) -> Form_ID {
	index, local := id >> 24, Form_ID(id & 0xFF_FFFF)
	if index == PAPYRUS_CREATED {return formid.CREATED_FORM_BASE | local}
	if int(index) >= len(db.load_slots) {return 0}
	return Form_ID(db.load_slots[index]) << 32 | local
}

// load_id is Form.GetFormID: form_by_load_id's inverse. 0 for a form no plugin loads.
load_id :: proc(db: ^DB, form: Form_ID) -> u32 {
	slot, local := u32(form >> 32), u32(form & 0xFF_FFFF)
	if slot == formid.CREATED_SLOT {return PAPYRUS_CREATED << 24 | local}
	for s, i in db.load_slots {
		if s == slot && i < int(PAPYRUS_CREATED) {return u32(i) << 24 | local}
	}
	return 0
}

// is_hostile: a spell, enchantment, potion or ingredient has an effect flagged Hostile.
is_hostile :: proc(db: ^DB, item: Form_ID) -> bool {
	effects := effect_items_of(db, item)
	if effects == nil {effects = ingredient_effects(db, item)}
	for e in effects {
		m, _ := magic_effect_of(db, e.effect)
		if m.info.flags & esm.MGEF_HOSTILE != 0 {return true}
	}
	return false
}
