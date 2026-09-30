package gamedb

import "../formats/esm"

@(private)
index_projectile :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	p, pok := esm.projectile(fl)
	if !pok {return}
	p.explosion = esm.remap_form(fm, u32(p.explosion))
	db.projectiles[rec.form_id] = p
}

projectile_of :: proc(db: ^DB, form: Form_ID) -> (esm.Projectile, bool) {
	return db.projectiles[form]
}

@(private)
index_hazard :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	h, hok := esm.hazard(fl)
	if !hok {return}
	h.spell = esm.remap_form(fm, u32(h.spell))
	db.hazards[rec.form_id] = h
}

hazard_of :: proc(db: ^DB, form: Form_ID) -> (esm.Hazard, bool) {
	return db.hazards[form]
}

// index_placed_hazard indexes a PHZD, a hazard placed in a cell, as a ref and lists it in
// placed_hazards.
@(private)
index_placed_hazard :: proc(db: ^DB, rec: esm.Record, ctx: esm.Walk_Context) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	p := esm.decode_refr(fl)
	if rec.form_id not_in db.ref_by_id {append(&db.placed_hazards, rec.form_id)}
	ep, _ := esm.refr_enable_parent(fl)
	db.ref_by_id[rec.form_id] = Ref {
		form_id      = rec.form_id,
		cell_form_id = ctx.cell_form_id,
		base         = esm.remap_form(ctx.fm, p.base),
		pos          = p.pos,
		rot          = p.rot,
		scale        = p.scale,
		disabled     = rec.flags & (REFR_INITIALLY_DISABLED | REFR_DELETED) != 0,
		deleted      = rec.flags & REFR_DELETED != 0,
		persistent   = !ctx.temporary,
		enable_parent   = esm.remap_form(ctx.fm, ep.parent),
		enable_opposite = ep.opposite,
	}
}

@(private)
index_shout :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	words := esm.shout_words(fl)
	for &w in words {w.word, w.spell = esm.remap_form(fm, u32(w.word)), esm.remap_form(fm, u32(w.spell))}
	db.shouts[rec.form_id] = words
}
