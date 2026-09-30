package world

// The sim's cell builder: a cell's refs as baseline ⊕ overlay, built once here and handed to render
// as placements (populate). Pure data: no IO, no GPU, no physics.

import "core:math"
import "../gamedb"
import smath "../math"
import "../models"
import "../worldstate"

// build_cell is a cell's refs: the ESM baseline and the grid's persistent refs, minus deleted ones,
// plus the refs scripts created there, each with its disabled/moved/scaled delta applied.
build_cell :: proc(sp: ^Space, db: ^gamedb.DB, cell: Form_ID) -> Sim_Cell {
	c := Sim_Cell{cell = cell}
	if gc, ok := gamedb.cell_by_formid(db, cell); ok {c.gx, c.gy, c.has_grid = gc.gx, gc.gy, gc.has_grid}
	add_refs(sp, db, &c, gamedb.refs_of(db, cell))
	add_refs(sp, db, &c, gamedb.actors_of(db, cell))
	if bucket, ok := sp.persistent[{c.gx, c.gy}]; c.has_grid && ok {add_refs(sp, db, &c, bucket[:])}
	add_created(sp, db, &c)
	return c
}

// add_refs appends a cell's placed refs: actors to its actor list, refs with a world model to its
// refs. A disabled ref is kept (it can be re-enabled); a deleted one is never built.
@(private)
add_refs :: proc(sp: ^Space, db: ^gamedb.DB, c: ^Sim_Cell, refs: []gamedb.Ref) {
	for r in refs {
		if gamedb.is_actor(db, r.base) {
			append(&c.actors, r.form_id)
			continue
		}
		if !ref_built(sp.ws, db, r) || r.base == XMARKER || r.base == XMARKER_HEADING || deleted(sp.ws, r.form_id) {continue}
		modl, ok := world_model(db, r.base)
		if !ok {continue}
		ref := Sim_Ref {
			form_id    = r.form_id,
			base       = r.base,
			model_id   = models.intern(modl),
			pos        = r.pos,
			rot        = r.rot,
			scale      = r.scale,
			world      = smath.trs(r.pos, r.rot, r.scale),
			has_tp     = r.has_tp,
			tp_door    = r.teleport.door,
		}
		apply_delta(sp.ws, &ref)
		append(&c.refs, ref)
	}
}

// add_created appends the refs scripts created in the cell that it does not hold yet.
@(private)
add_created :: proc(sp: ^Space, db: ^gamedb.DB, c: ^Sim_Cell) {
	if sp.ws == nil {return}
	outer: for fid in worldstate.created_in(sp.ws, c.cell) {
		for r in c.refs {
			if r.form_id == fid {continue outer}
		}
		if ref, ok := created_ref(sp, db, fid); ok {append(&c.refs, ref)}
	}
}

// created_ref is a ref a script created, as the sim holds it; false when its base has no world model.
created_ref :: proc(sp: ^Space, db: ^gamedb.DB, fid: Form_ID) -> (ref: Sim_Ref, ok: bool) {
	cr := worldstate.get_created(sp.ws, fid) or_return
	modl := world_model(db, cr.base) or_return
	ref = {
		form_id    = fid,
		base       = cr.base,
		model_id   = models.intern(modl),
		pos        = cr.pos,
		rot        = cr.rot,
		scale      = cr.scale,
		world      = smath.trs(cr.pos, cr.rot, cr.scale),
		in_flight  = worldstate.in_flight(sp.ws, fid),
	}
	apply_delta(sp.ws, &ref)
	return ref, true
}

// world_model is a base's model when it has one that is drawn in the world.
@(private)
world_model :: proc(db: ^gamedb.DB, base: Form_ID) -> (string, bool) {
	modl, ok := gamedb.model_of(db, base)
	if !ok || modl == "" || is_marker_path(modl) || is_nonworld_path(modl) {return "", false}
	return modl, true
}

// ref_built is whether a ref is built at all: a disabled or held ref is, so it can show again; a
// ref gated off by its enable parent is not.
ref_built :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, r: gamedb.Ref) -> bool {
	if ws == nil {return !gamedb.ref_effective_disabled(db, r)}
	if d, ok := worldstate.get(ws, r.form_id); ok && (.Disabled in d.live || .Held in d.live) {return true}
	return worldstate.ref_enabled(ws, db, r.form_id)
}

@(private)
deleted :: proc(ws: ^worldstate.World_State, form: Form_ID) -> bool {
	if ws == nil {return false}
	d, ok := worldstate.get(ws, form)
	return ok && .Deleted in d.live
}

// apply_delta patches a ref with its overlay delta: a disabled ref ignores Moved/Scaled; a Moved
// ref takes its settled transform; a scale-only delta recomputes the placement.
@(private)
apply_delta :: proc(ws: ^worldstate.World_State, r: ^Sim_Ref) {
	if ws == nil {return}
	d, ok := worldstate.get(ws, r.form_id)
	if !ok {return}
	if worldstate.hidden(d) {
		r.disabled = true
		return
	}
	if .Moved in d.live {
		r.world, r.pos = d.world, d.pos
	}
	if .Scaled in d.live {
		r.scale = d.scale
		if .Moved not_in d.live {r.world = smath.trs(r.pos, r.rot, d.scale)} // Moved bakes scale into its matrix
	}
}

// index_persistent buckets a worldspace's persistent refs (load doors, bridges, gates, quest
// set-dressing) by the grid cell each stands in, so every build of that cell includes them. The ESM
// groups them in one persistent cell at scattered coordinates.
index_persistent :: proc(sp: ^Space, db: ^gamedb.DB, world_fid: Form_ID) -> int {
	free_persistent(sp)
	pcid, ok := gamedb.world_persistent_cell(db, world_fid)
	if !ok {return 0}
	n := 0
	for refs in ([2][]gamedb.Ref{gamedb.refs_of(db, pcid), gamedb.actors_of(db, pcid)}) {
		for r in refs {
			key := [2]i32{i32(math.floor(r.pos.x / CELL_SIZE)), i32(math.floor(r.pos.y / CELL_SIZE))}
			// Read the header, append, write back: inserting a new key may rehash the map.
			bucket := sp.persistent[key]
			append(&bucket, r)
			sp.persistent[key] = bucket
			n += 1
		}
	}
	return n
}

@(private)
free_persistent :: proc(sp: ^Space) {
	for _, &bucket in sp.persistent {delete(bucket)}
	clear(&sp.persistent)
}

// gated_by is whether a ref of the cell hangs below `parent` in an enable chain.
gated_by :: proc(sp: ^Space, db: ^gamedb.DB, c: ^Sim_Cell, parent: Form_ID) -> bool {
	for r in gamedb.refs_of(db, c.cell) {
		if gamedb.enable_chain_has(db, r, parent) {return true}
	}
	bucket, ok := sp.persistent[{c.gx, c.gy}]
	if !c.has_grid || !ok {return false}
	for r in bucket {
		if gamedb.enable_chain_has(db, r, parent) {return true}
	}
	return false
}
