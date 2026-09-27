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
