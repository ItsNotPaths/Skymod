package ai

// Out-of-combat AI: every actor runs a package. A loaded actor walks its capsule with a mover.
// An unloaded actor that travels steps cell to cell; any other waits and is placed when its cell loads.

import "core:math/linalg"
import "core:math/rand"
import "../conditions"
import smath "../math"
import "../gamedb"
import "../nav"
import "../worldstate"

Form_ID :: gamedb.Form_ID

EVAL_EVERY :: f32(1) // seconds between package selections

// (hole once-per-day :tags (ai save) :sev polish) nothing is saved, so a OncePerDay package (125) runs again after a load; decided: choices and paths re-roll on load, as in Skyrim.
// Agent is an actor's running package. None of it is saved.
Agent :: struct {
	pack:      Form_ID,
	quest:     Form_ID, // the quest whose alias gave the package; its conditions run on it
	started:   f64, // game hours
	start_pos: [3]f32, // NearPackageStart
	eval_in:   f32, // seconds to the next selection
	nodes:     [dynamic]Node_State, // one per tree node
	mover:     Mover,
	route:     []nav.Route_Step, // to a place outside the loaded cells
	route_to:  Form_ID, // the cell `route` leads to
}

World :: struct {
	agents:     map[Form_ID]Agent,
	mesh:       nav.Path_Mesh,
	routes:     nav.Route_Index,
	quest_vars: conditions.Quest_Vars, // GetVMQuestVariable reads the script VM
}

// tick_loaded runs one tick of a loaded actor's package and returns the velocity for its capsule.
tick_loaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, touching: bool, dt: f32) -> [2]f32 {
	if actor not_in w.agents {w.agents[actor] = {eval_in = rand.float32() * EVAL_EVERY}} // spread the selections over ticks
	a := &w.agents[actor]
	a.eval_in -= dt
	if a.eval_in <= 0 {
		a.eval_in += EVAL_EVERY
		if pack, quest := select_package(w, ws, db, actor); pack != a.pack {start_package(a, db, pack, quest, ws.clock.hours, feet)}
	}
	if a.pack != 0 {
		c := Proc_Context {
			cond  = {db = db, ws = ws, subject = actor, quest = a.quest, quest_vars = w.quest_vars},
			agent = a,
			mesh   = &w.mesh,
			routes = &w.routes,
			feet   = feet,
			dt    = dt,
		}
		run_tree(&c)
	}
	vel := mover_step(&a.mover, &w.mesh, feet, touching, dt)
	if a.mover.door != 0 {cross_load_door(ws, db, a, actor, a.mover.door)}
	return vel
}

@(private = "file")
start_package :: proc(a: ^Agent, db: ^gamedb.DB, pack, quest: Form_ID, now: f64, feet: [3]f32) {
	a.pack, a.quest, a.started, a.start_pos = pack, quest, now, feet
	resize(&a.nodes, len(gamedb.package_tree(db, pack)))
	for &n in a.nodes {n = {}}
	a.mover.goal = {}
}

// cross_load_door puts the actor at the door's teleport marker, in the destination door's cell.
// If that cell is not loaded, the actor leaves the loaded world there.
@(private = "file")
cross_load_door :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor, door: Form_ID) {
	d, ok := gamedb.ref_by_formid(db, door)
	dest, dok := gamedb.ref_by_formid(db, d.teleport.door)
	if !ok || !dok {return}
	to := d.teleport.pos
	worldstate.set_moved(ws, actor, gamedb.grid_cell(db, dest.cell_form_id, to), smath.trs(to, d.teleport.rot, 1), to)
	clear(&a.mover.path)
	a.mover.goal = {}
}

// (hole offscreen-travel :tags ai :sev gap) an unloaded actor never moves; decided: one whose package sends it elsewhere steps cell to cell along its coarse route, staying (distance across / speed) in each, and snaps to the next cell's exit; everyone else waits. Its cell and position are its Moved delta.
// tick_unloaded runs the actors in unloaded cells: package selection, and travel cell by cell.
tick_unloaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool) {
}

// place_on_load is where an actor stands when its cell loads: somewhere inside the place its
// package names, if it is not there already. The package starts there.
place_on_load :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32) -> (at: [3]f32, ok: bool) {
	pack, quest := select_package(w, ws, db, actor)
	if pack == 0 {return}
	if actor not_in w.agents {w.agents[actor] = {}}
	a := &w.agents[actor]
	start_package(a, db, pack, quest, ws.clock.hours, feet)
	c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = quest, quest_vars = w.quest_vars}, agent = a, mesh = &w.mesh, routes = &w.routes, feet = feet}
	for n, i in gamedb.package_tree(db, pack) {
		if n.branch != .Procedure {continue}
		c.node = i
		p := location(&c) or_continue
		p.radius = max(p.radius, TRAVEL_RADIUS)
		if reached(&c, p) || p.cell not_in w.mesh.cells {return}
		at = nav.random_point_near(&w.mesh, p.center, p.radius) or_return
		a.start_pos = at
		return at, true
	}
	return
}

destroy :: proc(w: ^World) {
	for _, &a in w.agents {
		delete(a.nodes)
		delete(a.mover.path)
		delete(a.route)
	}
	delete(w.agents)
	nav.destroy(&w.mesh)
	nav.route_index_destroy(&w.routes)
}
