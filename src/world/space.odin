package world

// Space is one physics world's live cells as the sim holds them: where each ref stands, whether it
// is disabled or in flight, and the bodies and constraints that stand for it. The sim owns it; render
// draws from its own chunks (Scene) and the snapshot. Sim refs and render instances pair by form ID,
// each side with its own resident index.

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../physics"
import "../worldstate"

Space :: struct {
	phys:            ^physics.World, // nil = no physics here: no bodies are built
	collisions:      ^assetdb.Collision_Store,
	ws:              ^worldstate.World_State,
	dynamic_clutter: bool, // movable clutter gets dynamic bodies (else everything is static)
	cells:           map[Form_ID]Sim_Cell,
	resident:        map[Form_ID]Resident_Ref, // ref -> where it sits in `cells`; a self-healing cache
	persistent:      map[[2]i32][dynamic]gamedb.Ref, // the worldspace's persistent refs by grid cell (index_persistent)
	changes:         [dynamic]Ref_Event, // what the sim changed in live cells, for main to draw
	loaded:          [dynamic]Form_ID, // cells made live since the script phase last took them
	window:          Window, // which grid cells are live around the player (window.odin)
}

// Ref_Event is a change the sim made to a live cell, for main to apply to its render chunk.
Ref_Event :: union {
	Ref_Placed,
	Ref_Removed,
	Cell_Added,
	Cell_Rebuilt,
	Cell_Removed,
}

Ref_Placed :: struct {cell: Form_ID, ref: Ref_Placement} // moved, scaled, disabled, re-enabled or spawned
Ref_Removed :: struct {form: Form_ID}
Cell_Added :: struct {cell: Form_ID, refs: []Ref_Placement} // owned by the event
Cell_Rebuilt :: struct {cell: Form_ID, refs: []Ref_Placement} // owned by the event
Cell_Removed :: struct {cell: Form_ID}

// Ref_Placement is a ref as render needs it: where it stands and whether it shows.
Ref_Placement :: struct {
	form_id:    Form_ID,
	base:       Form_ID,
	model_path: string,
	pos, rot:   smath.Vec3,
	scale:      f32,
	world:      smath.Mat4,
	has_tp:     bool,
	tp_door:    Form_ID,
	disabled:   bool,
}

placement_of :: proc(r: Sim_Ref) -> Ref_Placement {
	return {r.form_id, r.base, r.model_path, r.pos, r.rot, r.scale, r.world, r.has_tp, r.tp_door, r.disabled}
}

ref_event_destroy :: proc(e: Ref_Event) {
	#partial switch v in e {
	case Cell_Added:   delete(v.refs)
	case Cell_Rebuilt: delete(v.refs)
	}
}

// Sim_Cell is one live cell: its refs, its actors and the bodies built for them (the terrain body too).
Sim_Cell :: struct {
	cell:        Form_ID,
	gx, gy:      i32,
	has_grid:    bool,
	refs:        [dynamic]Sim_Ref,
	actors:      [dynamic]Form_ID, // the actor refs placed here, disabled ones included (app/actors.odin gives them bodies)
	bodies:      [dynamic]physics.Body,
	constraints: [dynamic]physics.Constraint, // hinge joints linking articulated bodies
	phys_done:   bool, // every ref's bodies are built (skip in sync_physics)
}

// Sim_Ref is one placed ref as the sim holds it.
Sim_Ref :: struct {
	form_id:    Form_ID,
	base:       Form_ID,
	model_path: string, // borrowed from gamedb: the collision store's key
	pos:        smath.Vec3,
	rot:        smath.Vec3,
	scale:      f32,
	world:      smath.Mat4,
	has_tp:     bool,
	tp_door:    Form_ID,
	disabled:   bool, // overlay Disabled: no collision
	in_flight:  bool, // a projectile still flying: one non-colliding capsule, no NIF collision
	phys_built: bool,
	dyn_body:   physics.Body, // its one dynamic body (0 = none)
	dyn_active: bool, // last tick's body-active state: the settle edge writes a Moved delta
	// This ref's bodies are cell.bodies[body_first:][:body_count] and its hinges
	// cell.constraints[con_first:][:con_count], so one ref's collision comes out without the rest.
	body_first: int,
	body_count: int,
	con_first:  int,
	con_count:  int,
	dyn_bodies: []physics.Body, // an articulated ref's body per collision body (owned); nil otherwise
}

space_init :: proc(sp: ^Space, phys: ^physics.World, collisions: ^assetdb.Collision_Store, ws: ^worldstate.World_State, dynamic_clutter: bool) {
	sp^ = {phys = phys, collisions = collisions, ws = ws, dynamic_clutter = dynamic_clutter}
}

space_destroy :: proc(sp: ^Space) {
	space_clear(sp)
	delete(sp.cells)
	delete(sp.resident)
	free_persistent(sp)
	delete(sp.persistent)
	for e in sp.changes {ref_event_destroy(e)}
	delete(sp.changes)
	delete(sp.loaded)
	delete(sp.window.pending)
	sp^ = {}
}

// space_clear retires every live cell, and tells main.
space_clear :: proc(sp: ^Space) {
	cells := make([dynamic]Form_ID, 0, len(sp.cells), context.temp_allocator)
	for cell in sp.cells {append(&cells, cell)}
	for cell in cells {drop_cell(sp, cell)}
}

// drop_cell retires a live cell and tells main.
drop_cell :: proc(sp: ^Space, cell: Form_ID) {
	remove_cell(sp, cell)
	append(&sp.changes, Cell_Removed{cell})
}

// add_cell makes a cell live in the sim: its refs and actors built from gamedb and the overlay, and
// its terrain body. Object bodies follow in sync_physics.
add_cell :: proc(sp: ^Space, db: ^gamedb.DB, cell: Form_ID) -> ^Sim_Cell {
	remove_cell(sp, cell)
	c := build_cell(sp, db, cell)
	build_terrain_body(sp, db, &c)
	sp.cells[cell] = c
	live := &sp.cells[cell]
	index_refs(sp, live)
	append(&sp.loaded, cell)
	return live
}

// place_cell makes a cell live and tells main.
place_cell :: proc(sp: ^Space, db: ^gamedb.DB, cell: Form_ID) {
	append(&sp.changes, Cell_Added{cell, placements(add_cell(sp, db, cell))})
}

// placements is a live cell's refs as render draws them, owned by the caller.
placements :: proc(c: ^Sim_Cell) -> []Ref_Placement {
	refs := make([]Ref_Placement, len(c.refs))
	for r, i in c.refs {refs[i] = placement_of(r)}
	return refs
}

// remove_cell retires a live cell: its bodies and constraints come out of the physics world.
remove_cell :: proc(sp: ^Space, cell: Form_ID) {
	c, ok := &sp.cells[cell]
	if !ok {return}
	release_cell_physics(sp, c)
	deindex_refs(sp, c)
	delete(c.refs)
	delete(c.actors)
	delete_key(&sp.cells, cell)
}

// rebuild_cell rebuilds a live cell's refs and actors from gamedb and the current overlay; the
// terrain body stays and the object bodies rebuild in sync_physics.
rebuild_cell :: proc(sp: ^Space, db: ^gamedb.DB, cell: Form_ID) -> (^Sim_Cell, bool) {
	if sp == nil {return nil, false}
	c, ok := &sp.cells[cell]
	if !ok {return nil, false}
	for &r in c.refs {remove_ref_bodies(sp.phys, c, &r)}
	deindex_refs(sp, c)
	fresh := build_cell(sp, db, cell)
	delete(c.refs)
	delete(c.actors)
	c.refs, c.actors = fresh.refs, fresh.actors
	index_refs(sp, c)
	c.phys_done = false
	append(&sp.changes, Cell_Rebuilt{cell, placements(c)})
	return c, true
}

// spawn_ref makes a ref a script created live in its cell, when the cell is live and holds it not yet.
spawn_ref :: proc(sp: ^Space, db: ^gamedb.DB, fid: Form_ID) -> (ref: Sim_Ref, cell: Form_ID, ok: bool) {
	if sp == nil || sp.ws == nil {return}
	cr := worldstate.get_created(sp.ws, fid) or_return
	c := (&sp.cells[cr.cell]) or_return
	if _, _, held := find_ref(sp, fid); held {return}
	ref = created_ref(sp, db, fid) or_return
	append(&c.refs, ref)
	c.phys_done = false
	index_refs(sp, c)
	append(&sp.changes, Ref_Placed{cr.cell, placement_of(ref)})
	return ref, cr.cell, true
}

// remove_ref takes one ref and its bodies out of the sim (a deleted ref).
remove_ref :: proc(sp: ^Space, form: Form_ID) {
	r, c, ok := find_ref(sp, form)
	if !ok {return}
	remove_ref_bodies(sp.phys, c, r)
	for x, i in c.refs {
		if x.form_id == form {
			unordered_remove(&c.refs, i)
			break
		}
	}
	delete_key(&sp.resident, form)
	index_refs(sp, c)
	append(&sp.changes, Ref_Removed{form})
}

// find_ref is the live sim ref for a form, and its cell; none in a nil space. The resident index is
// a cache: a stale or missing entry falls back to a scan.
find_ref :: proc(sp: ^Space, form: Form_ID) -> (r: ^Sim_Ref, cell: ^Sim_Cell, ok: bool) {
	if sp == nil || form == 0 {return}
	if loc, hit := sp.resident[form]; hit {
		if c, cok := &sp.cells[loc.cell]; cok && loc.idx >= 0 && loc.idx < len(c.refs) && c.refs[loc.idx].form_id == form {
			return &c.refs[loc.idx], c, true
		}
	}
	for id, &c in sp.cells {
		for &x, i in c.refs {
			if x.form_id == form {
				sp.resident[form] = {cell = id, idx = i}
				return &x, &c, true
			}
		}
	}
	return
}

@(private)
index_refs :: proc(sp: ^Space, c: ^Sim_Cell) {
	for r, i in c.refs {
		if r.form_id != 0 {sp.resident[r.form_id] = {cell = c.cell, idx = i}}
	}
}

@(private)
deindex_refs :: proc(sp: ^Space, c: ^Sim_Cell) {
	for r in c.refs {
		if r.form_id != 0 {delete_key(&sp.resident, r.form_id)}
	}
}

// set_ref_disabled applies a Disabled change to a live ref: it loses its bodies, or rebuilds them.
set_ref_disabled :: proc(sp: ^Space, form: Form_ID, disabled: bool) {
	r, c, ok := find_ref(sp, form)
	if !ok || r.disabled == disabled {return}
	r.disabled = disabled
	if disabled {
		remove_ref_bodies(sp.phys, c, r)
	} else {
		r.phys_built, c.phys_done = false, false
	}
	append(&sp.changes, Ref_Placed{c.cell, placement_of(r^)})
}

// place_ref moves a live ref (a Moved or Scaled delta); its bodies rebuild at the new placement.
place_ref :: proc(sp: ^Space, form: Form_ID, world: smath.Mat4, pos: smath.Vec3, scale: f32) {
	r, c, ok := find_ref(sp, form)
	if !ok {return}
	r.world, r.pos, r.scale = world, pos, scale
	remove_ref_bodies(sp.phys, c, r)
	r.phys_built, c.phys_done = false, false
	append(&sp.changes, Ref_Placed{c.cell, placement_of(r^)})
}
