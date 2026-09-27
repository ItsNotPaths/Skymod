package gamedb

// Navmeshes (NAVM) by cell, and the navmesh index (NAVI) by navmesh.

import "../formats/esm"

Nav_Info :: esm.Nav_Info

Navmesh :: struct {
	form:  Form_ID,
	cell:  Form_ID,
	using geo: esm.Navmesh,
}

// navmeshes_in is every navmesh in a cell.
navmeshes_in :: proc(db: ^DB, cell: Form_ID) -> []Navmesh {
	return db.navmeshes[cell][:] if cell in db.navmeshes else nil
}

// navmesh_of is a navmesh by its form.
navmesh_of :: proc(db: ^DB, form: Form_ID) -> (m: Navmesh, ok: bool) {
	cell := db.navmesh_cell[form] or_return
	for n in db.navmeshes[cell] or_else nil {
		if n.form == form {return n, true}
	}
	return
}

// nav_index_entry is a navmesh's index entry, merged over every plugin's NAVI. Its `cell` is
// resolved for exterior entries too.
nav_index_entry :: proc(db: ^DB, navmesh: Form_ID) -> (n: Nav_Info, ok: bool) {
	n = db.nav_index[navmesh] or_return
	if n.world != 0 {n.cell, _ = cell_at(db, n.world, i32(n.grid.x), i32(n.grid.y))}
	return n, true
}

@(private)
index_navmesh :: proc(db: ^DB, rec: esm.Record, cell: Form_ID, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, moved := db.navmesh_cell[rec.form_id]; moved {
		list := &db.navmeshes[old]
		for m, i in list {
			if m.form == rec.form_id {
				esm.destroy_navmesh(m.geo, db.allocator)
				unordered_remove(list, i)
				break
			}
		}
		delete_key(&db.navmesh_cell, rec.form_id)
	}
	if rec.flags & REFR_DELETED != 0 {return}
	geo, decoded := esm.navmesh(fl, db.allocator)
	if !decoded {return}
	for &e in geo.edge_links {e.navmesh = esm.remap_form(fm, u32(e.navmesh))}
	for &d in geo.door_links {d.door = esm.remap_form(fm, u32(d.door))}
	if cell not_in db.navmeshes {db.navmeshes[cell] = {}}
	append(&db.navmeshes[cell], Navmesh{rec.form_id, cell, geo})
	db.navmesh_cell[rec.form_id] = cell
}

// index_nav_index merges one plugin's NAVI: each entry replaces that navmesh's, the rest stay.
@(private)
index_nav_index :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	infos, deleted := esm.navmesh_infos(fl, db.allocator)
	defer delete(infos, db.allocator)
	defer delete(deleted, db.allocator)
	for id in deleted {nav_index_drop(db, esm.remap_form(fm, u32(id)))}
	for n in infos {
		n := n
		n.navmesh = esm.remap_form(fm, u32(n.navmesh))
		for &id in n.edge_links {id = esm.remap_form(fm, u32(id))}
		for &id in n.door_links {id = esm.remap_form(fm, u32(id))}
		if n.world != 0 {n.world = esm.remap_form(fm, u32(n.world))}
		if n.cell != 0 {n.cell = esm.remap_form(fm, u32(n.cell))}
		nav_index_drop(db, n.navmesh)
		db.nav_index[n.navmesh] = n
	}
}

@(private = "file")
nav_index_drop :: proc(db: ^DB, navmesh: Form_ID) {
	if old, ok := db.nav_index[navmesh]; ok {
		esm.destroy_nav_info(old, db.allocator)
		delete_key(&db.nav_index, navmesh)
	}
}

@(private)
free_nav_indexes :: proc(db: ^DB) {
	for _, list in db.navmeshes {
		for m in list {esm.destroy_navmesh(m.geo, db.allocator)}
		delete(list)
	}
	delete(db.navmeshes)
	delete(db.navmesh_cell)
	for _, n in db.nav_index {esm.destroy_nav_info(n, db.allocator)}
	delete(db.nav_index)
}
