package ai

// Out-of-combat AI: every actor runs a package. A loaded actor walks its capsule with a mover.
// An unloaded actor that travels steps cell to cell; any other waits and is placed when its cell loads.

import "../gamedb"
import "../nav"
import "../worldstate"

Form_ID :: gamedb.Form_ID

// (hole once-per-day :tags (ai save) :sev polish :needs package-select) nothing is saved, so a OncePerDay package (125) runs again after a load; decided: choices and paths re-roll on load, as in Skyrim.
// Agent is an actor's running package. None of it is saved.
Agent :: struct {
	pack:    Form_ID,
	started: f64, // game hours
	mover:   Mover,
	route:   []nav.Route_Step, // while unloaded and travelling
}

World :: struct {
	agents: map[Form_ID]Agent,
	mesh:   nav.Path_Mesh,
}

// tick_loaded runs one tick of a loaded actor's package and returns the velocity for its capsule.
tick_loaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, touching: bool, dt: f32) -> [2]f32 {
	if actor not_in w.agents {w.agents[actor] = {}}
	a := &w.agents[actor]
	if pack := select_package(ws, db, actor); pack != a.pack {a.pack, a.started = pack, ws.clock.hours}
	c := Proc_Context{ws, db, actor, a, feet, 0}
	run_tree(&c)
	vel := mover_step(&a.mover, &w.mesh, feet, touching, dt)
	if a.mover.door != 0 {cross_load_door(ws, db, actor, a.mover.door)}
	return vel
}

// (hole actor-load-doors :tags ai :sev gap ) an NPC that walks into a load door stays on this side: wanted move it to the door's teleport marker, into the other cell.
cross_load_door :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor, door: Form_ID) {
}

// (hole offscreen-travel :tags ai :sev gap :needs (coarse-route package-select)) an unloaded actor never moves; decided: one whose package sends it elsewhere steps cell to cell along its coarse route, staying (distance across / speed) in each, and snaps to the next cell's exit; everyone else waits. Its cell and position are its Moved delta.
// tick_unloaded runs the actors in unloaded cells: package selection, and travel cell by cell.
tick_unloaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool) {
}

// (hole load-placement :tags ai :sev gap :needs package-tree) an actor loads where it was last put; decided: when its cell loads it is placed where its package puts it (in bed at 2:00, at the stall at noon, along its route's line through the cell).
// place_on_load is where an actor stands when its cell loads.
place_on_load :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> (feet: [3]f32, ok: bool) {
	return
}

destroy :: proc(w: ^World) {
	for _, &a in w.agents {
		delete(a.mover.path)
		delete(a.route)
	}
	delete(w.agents)
	nav.destroy(&w.mesh)
}
