package ai

// AI: every actor runs a package, unless it is warning, fighting or fleeing the player. A loaded actor walks its capsule with a mover.
// An unloaded actor that travels steps cell to cell; any other waits and is placed when its cell loads.

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:strings"
import "../combat"
import "../conditions"
import smath "../math"
import "../formid"
import "../gamedb"
import "../nav"
import "../worldstate"

Form_ID :: gamedb.Form_ID

EVAL_EVERY :: f32(1) // seconds between package selections

// OFFSCREEN_TURNS: actors outside the loaded cells step in turns, each once every this many ticks
// with that many ticks' time (10 Hz at 60), the way detection's viewers look.
OFFSCREEN_TURNS :: 6

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
	done:      bool, // the package tree finished
	found:     map[u8]Form_ID, // ObjectList input -> the ref a Find put there
	seat:      Seat, // the furniture marker it claimed
	posture:   Posture, // on `seat` unless Standing
	lead_at:   [3]f32, // where the leader it follows stood last tick
	combat:    combat.Fight, // toward its target (tick_combat); the package waits while it is not None
	confront:  Confront, // a guard after a wanted actor; the package waits while it walks up
	scene:     bool, // `pack` came from a scene's package action
	social_in: f32, // seconds to the next look around (social.odin)
	greeted:   bool, // said Hello to the player, who has not walked off since
	location:  Maybe(Form_ID), // the location it was last seen in
	cell:      Form_ID, // the cell it was last seen in, and the turn it came in (note_cell)
	came_in:   u64,
}

World :: struct {
	agents:     map[Form_ID]Agent,
	persistent: [dynamic]Form_ID, // the persistent actor placements, which live while unloaded
	turn:       u64, // counts tick_unloaded's ticks: whose turn it is (OFFSCREEN_TURNS)
	present:    [dynamic]Form_ID, // the loaded actors and the player this tick: whom combat and guards look at
	mesh:       nav.Path_Mesh,
	routes:     nav.Route_Index,
	quest_vars: conditions.Quest_Vars, // GetVMQuestVariable reads the script VM
	loaded:     map[Form_ID]bool, // the loaded cells, as of the last track_cells
	visitors:   map[Form_ID][dynamic]Form_ID, // cell -> actors placed elsewhere whose packages can send them there
	lua:        Lua_Hook,
	furniture:  Furniture_Hook,
	seats:      map[Seat]Form_ID, // marker -> the actor that claimed it; stale once that actor holds another
	seating:    map[Form_ID][dynamic]Form_ID, // cell -> the furniture and idle marker refs its records place (furniture.odin)
	escorts:    map[Form_ID]Escort_Ask, // escorted NPC -> the escort leading it (procedures.odin)
	chatter_in: f32, // seconds to the next idle line
	found:      map[[2]Form_ID]bool, // (finder, body): bodies already reported
}

// tick_loaded runs one tick of a loaded actor's package and returns the velocity for its capsule.
tick_loaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, touching: bool, dt: f32) -> [2]f32 {
	a := agent_of(w, ws, db, actor)
	if worldstate.is_dead(ws, db, actor) {return stop_dead(w, actor, a)}
	clear(&a.trip)
	a.planned = false
	scene_pack, _, action := worldstate.scene_package(ws, db, actor)
	a.eval_in -= dt
	if worldstate.take(&ws.ai.evaluate, actor) {a.eval_in = 0}
	if worldstate.take(&ws.ai.to_package, actor) && a.pack != 0 {
		jump_to_destination(w, ws, db, a, actor, feet)
		interrupt(w, actor)
	}
	if a.eval_in <= 0 || scene_pack != a.pack && (scene_pack != 0 || a.scene) { // a scene takes and gives back the actor at once
		a.eval_in = max(a.eval_in + EVAL_EVERY, 0)
		a.mover.pace = actor_pace(ws, db, actor)
		worldstate.wear_spare_armor(ws, db, actor)
		if pack, quest := select_package(w, ws, db, actor); pack != a.pack {start_package(a, db, pack, quest, ws.clock.hours, feet)}
		a.scene = scene_pack != 0
	}
	if a.combat.state != .None { // tick_combat ran first
		leave(a)
		combat_goal(ws, db, a, feet)
	} else if confront(w, ws, db, a, actor, feet, dt) {
		leave(a)
	} else if a.pack != 0 {
		c := Proc_Context {
			cond  = {db = db, ws = ws, subject = actor, quest = a.quest, pack = a.pack, quest_vars = w.quest_vars},
			agent = a,
			w     = w,
			feet  = feet,
			dt    = dt,
		}
		if run_tree(&c) != .Running {
			if !a.done {worldstate.set_package_done(ws, db, actor, a.pack)}
			a.done = true
			if action != nil && a.scene {action.done = true}
		}
	}
	alarm := a.combat.target if a.combat.state == .Combat else a.confront.target
	if alarm == 0 && (ws.talking == actor || ws.force_greet.speaker == actor) {alarm = ws.alarmed[actor]} // through the talk a confront opened
	worldstate.set_alarmed(ws, actor, alarm)
	arrest := a.confront.target
	if arrest == 0 && (ws.talking == actor || ws.force_greet.speaker == actor) {arrest = ws.arresting[actor]} // through the arrest talk
	worldstate.set_arresting(ws, actor, arrest)
	escorts_follow(w, ws, db, a, actor, feet, dt)
	follow_path_order(ws, db, a, actor, feet)
	keep_offset(ws, db, a, actor, feet)
	if worldstate.held_still(ws, actor) {a.mover.goal = {}}
	if g := a.mover.goal; g.active && g.cell != 0 && g.cell not_in w.mesh.cells {
		a.mover.goal = route_goal(w, ws, db, a, actor, feet, g)
	}
	vel := mover_step(&a.mover, &w.mesh, feet, touching, dt)
	note_location(ws, db, a, actor)
	ws.ai.packages[actor] = a.pack
	worldstate.set_in_set(&ws.ai.moving, actor, vel != {})
	worldstate.set_in_set(&ws.ai.sitting, actor, a.posture == .Sitting)
	worldstate.set_sleeping(ws, db, actor, a.posture == .Sleeping)
	if a.mover.door != 0 {cross_load_door(ws, db, a, actor, a.mover.door)}
	note_cell(w, ws, db, a, actor, "loaded")
	return vel
}

// BOUNCE_TICKS: an actor that changes cell twice in this many ticks is logged (note_cell).
BOUNCE_TICKS :: 120

// note_cell logs an actor that goes through a load door within BOUNCE_TICKS of its last cell change:
// in, then straight back out, is a loaded and an unloaded step that disagree on where it belongs.
@(private = "file")
note_cell :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, side: string) {
	cell := worldstate.ref_cell(ws, db, actor)
	if cell == a.cell {return}
	was, _ := gamedb.cell_by_formid(db, a.cell)
	now, _ := gamedb.cell_by_formid(db, cell)
	if a.cell != 0 && w.turn - a.came_in < BOUNCE_TICKS && (was.interior || now.interior) { // through a load door
		c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = a.quest, pack = a.pack, quest_vars = w.quest_vars}, agent = a, w = w, feet = worldstate.ref_pos(ws, db, actor)}
		p, ok := destination(&c)
		log.warnf(
			"ai: 0x%08X changed cell again after %d ticks (%s step): 0x%08X -> 0x%08X at %v; package 0x%08X, destination 0x%08X (found %v), goal cell 0x%08X door 0x%08X, trip %d/%d",
			actor, w.turn - a.came_in, side, a.cell, cell, c.feet, a.pack, p.cell, ok, a.mover.goal.cell, a.mover.goal.door, a.trip_at, len(a.trip),
		)
	}
	a.cell, a.came_in = cell, w.turn
}

// stop_dead leaves a dead actor where it fell: no package, goal, seat or fight. Its world state
// flags went when it died (worldstate.stop_doing).
@(private)
stop_dead :: proc(w: ^World, actor: Form_ID, a: ^Agent) -> [2]f32 {
	if a.pack != 0 {interrupt(w, actor)}
	a.pack, a.quest, a.scene, a.combat = 0, 0, false, {}
	return {}
}

// agent_of is an actor's agent, made on first use with its selections spread over ticks.
@(private)
agent_of :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> ^Agent {
	if actor not_in w.agents {w.agents[actor] = {eval_in = rand.float32() * EVAL_EVERY, mover = {pace = actor_pace(ws, db, actor)}}}
	return &w.agents[actor]
}

// actor_pace is how fast an actor walks and runs: its race's movement types times its SpeedMult.
@(private)
actor_pace :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> [2]f32 {
	walk, run, ok := gamedb.gait_speeds(db, worldstate.actor_traits(ws, db, actor).race)
	pace := [2]f32{walk, run} if ok else DEFAULT_PACE
	return pace * worldstate.av_current(ws, db, actor, "SpeedMult") / 100
}

@(private)
start_package :: proc(a: ^Agent, db: ^gamedb.DB, pack, quest: Form_ID, now: f64, feet: [3]f32) {
	a.pack, a.quest, a.started, a.start_pos = pack, quest, now, feet
	clear(&a.trip)
	a.planned, a.done = false, false
	clear(&a.found)
	leave(a)
	resize(&a.nodes, len(gamedb.package_tree(db, pack)))
	for &n in a.nodes {n = {}}
	a.mover.goal = {}
}

DOOR_RADIUS :: f32(96) // a door stands in its wall, off the navmesh

// route_goal is the step toward a goal outside the loaded cells: the next cell of the coarse route
// to it, or the load door out. The route is made again when the goal changes cell or the actor
// leaves the route. Without a route the actor stands: a goal in another space would walk it into a wall.
@(private = "file")
route_goal :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32, final: Goal) -> Goal {
	here := worldstate.ref_grid_cell(ws, db, actor)
	at := -1
	for s, i in a.route {if s.cell == here {at = i}}
	if a.route_to != final.cell || at < 0 {
		delete(a.route)
		a.route, _ = nav.coarse_route(&w.routes, db, here, feet, final.cell, final.point)
		a.route_to = final.cell
		at = 0
	}
	if len(a.route) == 0 {return {}}
	if at >= len(a.route) - 1 {return final}
	s := a.route[at]
	return {active = true, point = s.exit, radius = DOOR_RADIUS if s.door != 0 else ARRIVED, gait = final.gait, door = s.door}
}

// note_location queues a location change for the script tick when the actor's location differs from
// the last one seen. The first sight only records it.
@(private = "file")
note_location :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID) {
	now := worldstate.ref_location(ws, db, actor)
	if old, seen := a.location.?; seen && old != now {append(&ws.ai.moves, worldstate.Location_Move{actor, old, now})}
	a.location = now
}

// follow_path_order walks a script's PathTo in place of the package, and drops it on arrival.
@(private = "file")
follow_path_order :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32) {
	o, ok := ws.ai.paths[actor]
	if !ok {return}
	at := worldstate.ref_pos(ws, db, o.to)
	if o.to == 0 || linalg.length(at.xy - feet.xy) <= ARRIVED {
		delete_key(&ws.ai.paths, actor)
		a.mover.goal = {}
		return
	}
	g: Gait = .Run if o.speed >= 0.75 else .Jog if o.speed >= 0.5 else .Walk
	a.mover.goal = {active = true, point = at, radius = ARRIVED, gait = g, cell = worldstate.ref_grid_cell(ws, db, o.to)}
}

OFFSET_REACHED :: f32(16) // nearer than this an offset holder stands

// keep_offset walks the actor to the place its KeepOffsetFromActor asks for, in the target's frame.
@(private = "file")
keep_offset :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32) {
	o, ok := ws.ai.offsets[actor]
	if !ok {return}
	at := worldstate.ref_pos(ws, db, o.target)
	h := worldstate.ref_rot(ws, db, o.target).z + o.angle
	right, ahead := [2]f32{math.cos(h), -math.sin(h)}, [2]f32{math.sin(h), math.cos(h)} // heading 0 faces +Y, turning clockwise
	spot := at + {right.x * o.offset.x + ahead.x * o.offset.y, right.y * o.offset.x + ahead.y * o.offset.y, o.offset.z}
	d := linalg.length(spot.xy - feet.xy)
	a.mover.goal = {active = true, point = spot, radius = max(o.follow, OFFSET_REACHED), gait = .Run if d > o.catch_up else .Walk, cell = worldstate.ref_grid_cell(ws, db, o.target)}
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
	w.turn += 1
	step := dt * OFFSCREEN_TURNS
	for id in w.persistent {
		if (u64(id) + w.turn) % OFFSCREEN_TURNS == 0 {step_unloaded(w, ws, db, loaded, id, step)}
	}
	for id, cr in ws.created {
		if (u64(id) + w.turn) % OFFSCREEN_TURNS == 0 && gamedb.is_actor(db, cr.base) {step_unloaded(w, ws, db, loaded, id, step)}
	}
}

@(private = "file")
step_unloaded :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool, actor: Form_ID, dt: f32) {
	if actor in loaded || worldstate.is_dead(ws, db, actor) || !worldstate.ref_enabled(ws, db, actor) {return}
	a := agent_of(w, ws, db, actor)
	feet := worldstate.ref_pos(ws, db, actor)
	a.eval_in -= dt
	if a.eval_in <= 0 {
		a.eval_in += EVAL_EVERY
		a.mover.pace = actor_pace(ws, db, actor)
		if pack, quest := select_package(w, ws, db, actor); pack != a.pack {start_package(a, db, pack, quest, ws.clock.hours, feet)}
	}
	if worldstate.take(&ws.ai.to_package, actor) && a.pack != 0 {
		jump_to_destination(w, ws, db, a, actor, feet)
		clear(&a.trip)
	}
	if o, ok := ws.ai.paths[actor]; ok { // unloaded, a PathTo arrives at once
		to := worldstate.ref_pos(ws, db, o.to)
		worldstate.set_moved(ws, actor, worldstate.ref_grid_cell(ws, db, o.to), smath.trs(to, {}, 1), to)
		delete_key(&ws.ai.paths, actor)
		return
	}
	if a.pack != 0 && !a.planned {plan_trip(w, ws, db, a, actor, feet)}
	walk_trip(ws, db, a, actor, feet, dt)
	note_location(ws, db, a, actor)
	note_cell(w, ws, db, a, actor, "unloaded")
	if _, _, action := worldstate.scene_package(ws, db, actor); action != nil && action.pack == a.pack && a.trip_at >= len(a.trip) {action.done = true}
}

// plan_trip lays the walk to the package's destination, once per package.
@(private = "file")
plan_trip :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32) {
	a.planned = true
	c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = a.quest, pack = a.pack, quest_vars = w.quest_vars}, agent = a, w = w, feet = feet}
	p, ok := destination(&c)
	if !ok || reached(&c, p) {return}
	points, found := nav.trip(&w.routes, db, worldstate.ref_grid_cell(ws, db, actor), feet, p.cell, p.center, context.temp_allocator)
	if !found {return}
	append(&a.trip, ..points)
	a.trip_at = 1
	a.speed = gait_speed(a.mover.pace, gait(&c))
}

// skip_time walks every agent through the hours a wait or sleep skipped: each selects its package
// again and covers as much of the trip to it as that time allows, loaded or not.
skip_time :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB) {
	hours := ws.ai.skipped
	ws.ai.skipped = 0
	if hours <= 0 {return}
	seconds := f32(hours * 3600) / max(worldstate.global_value(ws, db, formid.TIMESCALE), 1)
	for actor, &a in w.agents {
		if worldstate.is_dead(ws, db, actor) || !worldstate.ref_enabled(ws, db, actor) {continue}
		feet := worldstate.ref_pos(ws, db, actor)
		if pack, quest := select_package(w, ws, db, actor); pack != a.pack {start_package(&a, db, pack, quest, ws.clock.hours, feet)}
		clear(&a.trip)
		plan_trip(w, ws, db, &a, actor, feet)
		if len(a.trip) == 0 {continue}
		walk_trip(ws, db, &a, actor, feet, seconds)
		interrupt(w, actor)
	}
}

// walk_trip moves an actor `dt` seconds along its trip and writes where it got to.
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

// destination is where an actor's package wants it: the first procedure location that resolves, or
// a Patrol's first marker.
// (hole offscreen-player-places :tags ai :sev polish) unsourced: whether vanilla ever moves an unloaded actor toward the player; its package places at the player (ForceGreet zones, NearRef player 5000) are skipped, which is what stops every forcegreeter in Skyrim walking to the player during a long wait.
@(private)
destination :: proc(c: ^Proc_Context) -> (p: Place, ok: bool) {
	for n, i in gamedb.package_tree(c.cond.db, c.agent.pack) {
		if n.branch != .Procedure {continue}
		c.node = i
		if n.procedure == "Patrol" {
			p = patrol_place(c) or_continue
			return p, true
		}
		p = location(c) or_continue
		if p.ref == c.cond.ws.player {continue} // a ForceGreet's trigger zone, or a walk up to the player once near: no trip across the world
		p.radius = travel_radius(c, p)
		return p, true
	}
	return
}

Placement :: enum u8 {
	Stay, // where it stands
	Here, // at `at`, in the loaded cells
	Away, // moved into a cell that is not loaded; no capsule now
}

// place_on_load is where an actor goes when its cell loads: nothing, if it is where its package
// wants it or partway through an unloaded trip; the dry spot nearest the package's place when that
// is loaded; else straight into the place's cell, as if it had already walked there.
place_on_load :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32) -> (at: [3]f32, placed: Placement) {
	if a, ok := w.agents[actor]; ok && a.trip_at < len(a.trip) {return}
	pack, quest := select_package(w, ws, db, actor)
	if pack == 0 {return}
	a := agent_of(w, ws, db, actor)
	start_package(a, db, pack, quest, ws.clock.hours, feet)
	return jump_to_destination(w, ws, db, a, actor, feet)
}

// jump_to_destination puts the actor where its package wants it at once: the dry spot nearest the
// place when that is loaded, else straight into the place's cell.
@(private = "file")
jump_to_destination :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32) -> (at: [3]f32, placed: Placement) {
	c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = a.quest, pack = a.pack, quest_vars = w.quest_vars}, agent = a, w = w, feet = feet}
	p, ok := destination(&c)
	if !ok || reached(&c, p) {return}
	spot, found := [3]f32{}, false
	if p.cell in w.mesh.cells {
		spots := nav.dry_points_near(&w.mesh, p.center, max(p.radius, SANDBOX_RADIUS)) // a place's centre can sit off the mesh
		if len(spots) > 0 {spot, found, placed = spots[0], true, .Here}
	} else {
		spot, found = nav.dry_point_in_cell(db, p.cell, p.center)
		placed = .Away
	}
	if !found {return {}, .Stay}
	worldstate.set_moved(ws, actor, p.cell, smath.trs(spot, {}, 1), spot)
	a.start_pos = spot
	return spot, placed
}

destroy :: proc(w: ^World) {
	for _, &a in w.agents {
		delete(a.nodes)
		delete(a.mover.path)
		delete(a.route)
		delete(a.trip)
		delete(a.found)
	}
	delete(w.agents)
	delete(w.persistent)
	delete(w.present)
	delete(w.loaded)
	for _, list in w.visitors {delete(list)}
	delete(w.visitors)
	delete(w.found)
	delete(w.seats)
	delete(w.escorts)
	for _, list in w.seating {delete(list)}
	delete(w.seating)
	nav.destroy(&w.mesh)
	nav.route_index_destroy(&w.routes)
}

// interrupt restarts an actor's package from where it stands (a script or a dev grab moved it).
interrupt :: proc(w: ^World, actor: Form_ID) {
	a, ok := &w.agents[actor]
	if !ok {return}
	for &n in a.nodes {n = {}}
	a.mover.goal = {}
	clear(&a.mover.path)
	clear(&a.trip)
	a.planned = false
	leave(a)
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
	fmt.sbprintfln(&b, "package %s, quest %s, since %.2fh, scene %v, combat %v", name(db, a.pack) if a.pack != 0 else "none", name(db, a.quest) if a.quest != 0 else "-", a.started, a.scene, a.combat.state)
	for n, i in gamedb.package_tree(db, a.pack) {
		st := a.nodes[i] if i < len(a.nodes) else {}
		fmt.sbprintfln(&b, "  node %d %v %s done %v child %d timer %.1f point %v", i, n.branch, n.procedure, st.done, st.child, st.timer, st.point)
	}
	m := a.mover
	fmt.sbprintfln(&b, "mover goal %v at %v r %.0f door 0x%X; path %d; arrived %v stuck %v", m.goal.active, m.goal.point, m.goal.radius, u64(m.goal.door), len(m.path), m.arrived, m.stuck)
	fmt.sbprintf(&b, "trip %d/%d, route %d steps to 0x%X", a.trip_at, len(a.trip), len(a.route), u64(a.route_to))
	return strings.to_string(b)
}
