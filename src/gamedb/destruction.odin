package gamedb

// Destructible objects: a base's DEST health and the stages damage takes it through (worldstate
// keeps each ref's damage).

import "core:strings"
import "../formats/esm"

Destructible :: struct {
	health: i32,
	stages: []esm.Destruction_Stage, // owned, models too; explosion and debris remapped
}

@(private)
index_destructible :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, seen := db.destructibles[rec.form_id]; seen {
		destroy_destructible(db, old)
		delete_key(&db.destructibles, rec.form_id)
	}
	health, stages, has := esm.destruction(fl, db.allocator)
	if !has {return}
	for &s in stages {
		s.explosion, s.debris = esm.remap_form(fm, u32(s.explosion)), esm.remap_form(fm, u32(s.debris))
		s.model = strings.clone(s.model, db.allocator)
	}
	db.destructibles[rec.form_id] = {health, stages}
}

@(private)
destroy_destructible :: proc(db: ^DB, d: Destructible) {
	for s in d.stages {delete(s.model, db.allocator)}
	delete(d.stages, db.allocator)
}

destructible_of :: proc(db: ^DB, base: Form_ID) -> (Destructible, bool) {
	return db.destructibles[base]
}
