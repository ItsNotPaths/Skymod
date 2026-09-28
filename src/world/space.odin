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
	cells := make([dynamic]Form_ID, 0, len(sp.cells), context.temp_allocator)
	for cell in sp.cells {append(&cells, cell)}
	for cell in cells {remove_cell(sp, cell)}
	delete(sp.cells)
	delete(sp.resident)
	sp^ = {}
}

// (hole cell-handoff) the sim's cells are copied from render chunks the streamer built on main; the sim must build its own cells from gamedb plus the overlay and pick which are live.
// add_cell makes a render chunk's freshly built cell live in the sim: its refs (placements and
// overlay flags copied, so call it after apply_overlay), its actors (taken from the chunk) and its
// terrain body. Object bodies follow in sync_physics.
add_cell :: proc(sp: ^Space, db: ^gamedb.DB, chunk: ^Chunk) {
	remove_cell(sp, chunk.cell_form_id)
	c := Sim_Cell {
		cell     = chunk.cell_form_id,
		gx       = chunk.gx,
		gy       = chunk.gy,
		has_grid = chunk.has_grid,
		actors   = chunk.actors,
	}
	chunk.actors = nil
	for inst in chunk.instances {append(&c.refs, ref_of(sp, inst))}
	build_terrain_body(sp, db, &c)
	sp.cells[c.cell] = c
	index_refs(sp, &sp.cells[c.cell])
}

// ref_of is the sim's copy of a render instance.
@(private)
ref_of :: proc(sp: ^Space, inst: Instance) -> Sim_Ref {
	return {
		form_id = inst.form_id,
		base = inst.base,
		model_path = inst.model_path,
		pos = inst.pos,
		rot = inst.rot,
		scale = inst.scale,
		world = inst.world,
		has_tp = inst.has_tp,
		tp_door = inst.tp_door,
		disabled = inst.disabled,
		in_flight = sp.ws != nil && worldstate.in_flight(sp.ws, inst.form_id),
	}
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

// rebuild_cell replaces a live cell's refs and actors with a render chunk's rebuilt ones; the
// terrain body stays and the object bodies rebuild in sync_physics.
rebuild_cell :: proc(sp: ^Space, chunk: ^Chunk) {
	c, ok := &sp.cells[chunk.cell_form_id]
	if !ok {return}
	for &r in c.refs {remove_ref_bodies(sp.phys, c, &r)}
	deindex_refs(sp, c)
	clear(&c.refs)
	for inst in chunk.instances {append(&c.refs, ref_of(sp, inst))}
	delete(c.actors)
	c.actors = chunk.actors
	chunk.actors = nil
	index_refs(sp, c)
	c.phys_done = false
}

// add_ref makes one render instance live in its cell (a spawned created ref).
add_ref :: proc(sp: ^Space, inst: Instance, cell: Form_ID) {
	c, ok := &sp.cells[cell]
	if !ok {return}
	append(&c.refs, ref_of(sp, inst))
	c.phys_done = false
	index_refs(sp, c)
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
}

// find_ref is the live sim ref for a form, and its cell. The resident index is a cache: a stale or
// missing entry falls back to a scan.
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
}

// place_ref moves a live ref (a Moved or Scaled delta); its bodies rebuild at the new placement.
place_ref :: proc(sp: ^Space, form: Form_ID, world: smath.Mat4, pos: smath.Vec3, scale: f32) {
	r, c, ok := find_ref(sp, form)
	if !ok {return}
	r.world, r.pos, r.scale = world, pos, scale
	remove_ref_bodies(sp.phys, c, r)
	r.phys_built, c.phys_done = false, false
}
