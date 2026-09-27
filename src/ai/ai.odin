package ai

// Out-of-combat AI: every actor runs a package. A loaded actor walks its capsule with a mover.
// An unloaded actor that travels steps cell to cell; any other waits and is placed when its cell loads.

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:strings"
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
	trip:      [dynamic]nav.Trip_Point, // the walk while unloaded
	trip_at:   int, // the next point
	speed:     f32,
	planned:   bool, // the trip was planned for this package (it may have found none)
}

World :: struct {
	agents:     map[Form_ID]Agent,
	persistent: [dynamic]Form_ID, // the persistent actor placements, which live while unloaded
	mesh:       nav.Path_Mesh,
	routes:     nav.Route_Index,
	quest_vars: conditions.Quest_Vars, // GetVMQuestVariable reads the script VM
}

// tick_loaded runs one tick of a loaded actor's package and returns the velocity for its capsule.
tick_loaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, touching: bool, dt: f32) -> [2]f32 {
	if actor not_in w.agents {w.agents[actor] = {eval_in = rand.float32() * EVAL_EVERY}} // spread the selections over ticks
	a := &w.agents[actor]
	clear(&a.trip)
	a.planned = false
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
	clear(&a.trip)
	a.planned = false
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

// tick_unloaded runs the persistent and created actors outside the loaded cells: package
// selection, and the walk to where the package sends them, over the navmeshes, at package speed.
// Anyone else waits and is placed when its cell loads.
tick_unloaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool, dt: f32) {
	if len(w.persistent) == 0 {
		for id in db.persistent_refs {
			if r, ok := gamedb.ref_by_formid(db, id); ok && gamedb.is_actor(db, r.base) {append(&w.persistent, id)}
		}
	}
	for id in w.persistent {step_unloaded(w, ws, db, loaded, id, dt)}
	for id, cr in ws.created {
		if gamedb.is_actor(db, cr.base) {step_unloaded(w, ws, db, loaded, id, dt)}
	}
}

@(private = "file")
step_unloaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool, actor: Form_ID, dt: f32) {
	if actor in loaded || worldstate.is_dead(ws, actor) || !worldstate.ref_enabled(ws, db, actor) {return}
	if actor not_in w.agents {w.agents[actor] = {eval_in = rand.float32() * EVAL_EVERY}}
	a := &w.agents[actor]
	feet := worldstate.ref_pos(ws, db, actor)
	a.eval_in -= dt
	if a.eval_in <= 0 {
		a.eval_in += EVAL_EVERY
		if pack, quest := select_package(w, ws, db, actor); pack != a.pack {start_package(a, db, pack, quest, ws.clock.hours, feet)}
	}
	if a.pack != 0 && !a.planned {plan_trip(w, ws, db, a, actor, feet)}
	walk_trip(ws, db, a, actor, feet, dt)
}

// plan_trip lays the walk to the package's destination, once per package.
@(private = "file")
plan_trip :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32) {
	a.planned = true
	c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = a.quest, quest_vars = w.quest_vars}, agent = a, mesh = &w.mesh, routes = &w.routes, feet = feet}
	p, ok := destination(&c)
	if !ok || reached(&c, p) {return}
	points, found := nav.trip(&w.routes, db, worldstate.ref_grid_cell(ws, db, actor), feet, p.cell, p.center, context.temp_allocator)
	if !found {return}
	append(&a.trip, ..points)
	a.trip_at = 1
	a.speed = gait_speed(gait(&c))
}

// (hole trip-time-skip :tags (ai world) :sev gap) a wait or sleep skips hours but no traveller walks through them: unloaded trips advance by the tick only, and loaded actors do not jump ahead either.
// walk_trip moves an unloaded actor along its trip for one tick and writes where it got to.
@(private = "file")
walk_trip :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32, dt: f32) {
	if a.trip_at >= len(a.trip) {return}
	pos, left := feet, a.speed * dt
	for a.trip_at < len(a.trip) {
		next := a.trip[a.trip_at]
		if next.jump {
			pos = next.pos
			a.trip_at += 1
			continue
		}
		d := linalg.distance(pos, next.pos)
		if d > left {
			pos += (next.pos - pos) * (left / d)
			break
		}
		left -= d
		pos = next.pos
		a.trip_at += 1
	}
	to := a.trip[min(a.trip_at, len(a.trip) - 1)]
	cell := to.cell
	if c, _ := gamedb.cell_by_formid(db, cell); !c.interior {cell = gamedb.cell_under(db, c.world_form_id, pos)}
	heading := math.PI / 2 - math.atan2(to.pos.y - pos.y, to.pos.x - pos.x)
	worldstate.set_moved(ws, actor, cell, smath.trs(pos, {0, 0, heading}, 1), pos)
}

// destination is where an actor's package wants it: the first procedure location that resolves.
@(private = "file")
destination :: proc(c: ^Proc_Context) -> (p: Place, ok: bool) {
	for n, i in gamedb.package_tree(c.cond.db, c.agent.pack) {
		if n.branch != .Procedure {continue}
		c.node = i
		p = location(c) or_continue
		p.radius = max(p.radius, TRAVEL_RADIUS)
		return p, true
	}
	return
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
	p := destination(&c) or_return
	if reached(&c, p) || p.cell not_in w.mesh.cells {return}
	at = nav.random_point_near(&w.mesh, p.center, p.radius) or_return
	a.start_pos = at
	return at, true
}

destroy :: proc(w: ^World) {
	for _, &a in w.agents {
		delete(a.nodes)
		delete(a.mover.path)
		delete(a.route)
		delete(a.trip)
	}
	delete(w.agents)
	delete(w.persistent)
	nav.destroy(&w.mesh)
	nav.route_index_destroy(&w.routes)
}

// describe is an actor's AI state as console text: its package, each tree node, its mover and trip.
describe :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, allocator := context.temp_allocator) -> string {
	name := proc(db: ^gamedb.DB, f: Form_ID) -> string {
		for k, v in db.form_by_edid {if v == f {return k}}
		return fmt.tprintf("0x%X", u64(f))
	}
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "at %v in 0x%X", worldstate.ref_pos(ws, db, actor), u64(worldstate.ref_cell(ws, db, actor)))
	a, ok := w.agents[actor]
	if !ok {
		fmt.sbprint(&b, "no agent (never selected a package)")
		return strings.to_string(b)
	}
	fmt.sbprintfln(&b, "package %s, quest %s, since %.2fh", name(db, a.pack) if a.pack != 0 else "none", name(db, a.quest) if a.quest != 0 else "-", a.started)
	for n, i in gamedb.package_tree(db, a.pack) {
		st := a.nodes[i] if i < len(a.nodes) else {}
		fmt.sbprintfln(&b, "  node %d %v %s done %v child %d timer %.1f point %v", i, n.branch, n.procedure, st.done, st.child, st.timer, st.point)
	}
	m := a.mover
	fmt.sbprintfln(&b, "mover goal %v at %v r %.0f door 0x%X; path %d; arrived %v stuck %v", m.goal.active, m.goal.point, m.goal.radius, u64(m.goal.door), len(m.path), m.arrived, m.stuck)
	fmt.sbprintf(&b, "trip %d/%d, route %d steps to 0x%X", a.trip_at, len(a.trip), len(a.route), u64(a.route_to))
	return strings.to_string(b)
}
