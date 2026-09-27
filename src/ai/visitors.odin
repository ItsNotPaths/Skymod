package ai

// Visitors: actors whose packages can send them to a cell other than their own (the Whiterun gate
// guards stand in Tamriel but are placed in WhiterunWorld). When such a cell loads, the ones whose
// package wants them there now are moved in, wherever their own cell is and whether it is loaded or not.

import "../gamedb"
import smath "../math"
import "../nav"
import "../worldstate"

// track_cells notes the loaded cells and pulls in the visitors of any that just loaded.
track_cells :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, cells: []Form_ID) {
	if w.visitors == nil {index_visitors(w, ws, db)}
	fresh := make([dynamic]Form_ID, context.temp_allocator)
	for c in cells {
		if c not_in w.loaded {append(&fresh, c)}
	}
	clear(&w.loaded)
	for c in cells {w.loaded[c] = true}
	for c in fresh {
		for actor in w.visitors[c] or_else nil {pull_visitor(w, ws, db, actor)}
	}
}

// pull_visitor moves an actor from outside the loaded cells to its package's place, if that is loaded.
@(private = "file")
pull_visitor :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) {
	if worldstate.is_dead(ws, actor) || !worldstate.ref_enabled(ws, db, actor) {return}
	if worldstate.ref_grid_cell(ws, db, actor) in w.loaded {return}
	if a, ok := w.agents[actor]; ok && a.trip_at < len(a.trip) {return} // walking there already
	pack, quest := select_package(w, ws, db, actor)
	if pack == 0 {return}
	if actor not_in w.agents {w.agents[actor] = {}}
	a := &w.agents[actor]
	feet := worldstate.ref_pos(ws, db, actor)
	start_package(a, db, pack, quest, ws.clock.hours, feet)
	c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = quest, quest_vars = w.quest_vars}, agent = a, mesh = &w.mesh, routes = &w.routes, feet = feet}
	p, ok := destination(&c)
	if !ok || p.cell not_in w.loaded {return}
	spots := nav.dry_points_near(&w.mesh, p.center, max(p.radius, SANDBOX_RADIUS))
	if len(spots) == 0 {return}
	worldstate.set_moved(ws, actor, p.cell, smath.trs(spots[0], {}, 1), spots[0])
	a.start_pos = spots[0]
}

// index_visitors maps each cell to the actors placed elsewhere whose packages name a place in it:
// a location (near a ref, a linked ref, in a cell) or a Patrol's start marker. Built once.
@(private = "file")
index_visitors :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB) {
	w.visitors = make(map[Form_ID][dynamic]Form_ID)
	seen := make(map[Form_ID]bool, context.temp_allocator)
	for _, refs in db.actor_refs {
		for r in refs {
			home := gamedb.grid_cell(db, r.cell_form_id, r.pos)
			own, defaults := gamedb.actor_packages(db, worldstate.ref_base(ws, db, r.form_id), worldstate.actor_pick(ws, db, r.form_id))
			clear(&seen)
			for list in ([2][]Form_ID{own, defaults}) {
				for pack in list {
					for cell in package_cells(db, pack, r.form_id) {
						if cell == 0 || cell == home || cell in seen {continue}
						seen[cell] = true
						if cell not_in w.visitors {w.visitors[cell] = {}}
						append(&w.visitors[cell], r.form_id)
					}
				}
			}
		}
	}
}

// package_cells are the cells a package's inputs name for an actor, from the records alone.
@(private = "file")
package_cells :: proc(db: ^gamedb.DB, pack, actor: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	ref_cell :: proc(db: ^gamedb.DB, ref: Form_ID) -> Form_ID {
		r, ok := gamedb.ref_by_formid(db, ref)
		return gamedb.grid_cell(db, r.cell_form_id, r.pos) if ok else 0
	}
	for n in gamedb.package_tree(db, pack) {
		for idx in n.inputs {
			in_ := gamedb.package_input(db, pack, idx) or_continue
			#partial switch v in in_.value {
			case gamedb.Package_Location:
				#partial switch v.kind {
				case .NearRef:       append(&out, ref_cell(db, v.form))
				case .NearLinkedRef: if l, ok := gamedb.linked_ref(db, actor, v.form); ok {append(&out, ref_cell(db, l))}
				case .InCell:        append(&out, v.form)
				}
			case gamedb.Package_Target:
				#partial switch v.kind {
				case .SpecificRef: append(&out, ref_cell(db, v.form))
				case .LinkedRef:   if l, ok := gamedb.linked_ref(db, actor, v.form); ok {append(&out, ref_cell(db, l))}
				}
			}
		}
	}
	return out[:]
}
