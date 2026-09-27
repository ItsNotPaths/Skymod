package ai

// Furniture and idle markers: Find fills an ObjectList input with a chair, bed or other furniture
// near the package location and keeps looking; Sit and Sleep walk to a free marker on it and end
// seated; UseIdleMarker walks to its marker and stays. An actor holds its seat until its package
// changes; the app pins its capsule there.

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "../formats/nif"
import "../gamedb"
import smath "../math"
import "../worldstate"

// Furniture_Hook reads a FURN base's markers from its model; the app wires it to the asset cache.
Furniture_Hook :: struct {
	user:    rawptr,
	markers: proc(user: rawptr, base: Form_ID) -> []nif.Furniture_Marker,
}

// Posture is how an actor holds its seat.
// (hole actor-states :tags (animation ai unclaimed) :sev blocker) Posture is AI-only; it folds into the one actor-state model.
Posture :: enum u8 {
	Standing,
	Sitting,
	Sleeping,
	Idling, // at an idle marker
}

// Seat is one marker of a furniture ref, or an idle marker ref (marker 0).
Seat :: struct {
	furniture: Form_ID,
	marker:    int,
}

// PTDA object types Find matches.
OBJECT_FURNITURE :: 10
OBJECT_BEDS :: 26
OBJECT_CHAIRS :: 27

FIND_EVERY :: f32(2) // seconds between searches
SEAT_REACH :: f32(96) // this near its marker, an actor sits down
SEAT_NEAR :: f32(256) // this near, an actor that can get no nearer (a cart seat off the navmesh) sits down

// proc_find never ends: the procedure beside it does.
proc_find :: proc(c: ^Proc_Context) -> Status {
	st := &c.agent.nodes[c.node]
	if !st.started {
		st.started = true
		st.timer = rand.float32() * FIND_EVERY // spread the searches over ticks
	}
	st.timer -= c.dt
	if st.timer <= 0 {
		st.timer = FIND_EVERY
		find(c)
	}
	return .Running
}

// find writes the ref the criteria input names, or the nearest usable match in the package
// location, to the output ObjectList. A claimed seat is kept.
@(private = "file")
find :: proc(c: ^Proc_Context) {
	slot, has_slot := input_slot(c, 2)
	p, has_place := input_place(c, 0)
	t, has_target := input_value(c, 1, gamedb.Package_Target)
	if !has_slot || !has_place || !has_target {return}
	if held := c.agent.found[slot]; held != 0 && held == c.agent.seat.furniture {return}
	if t.kind != .ObjectID && t.kind != .ObjectType {
		c.agent.found[slot] = input_target(c, 1)
		return
	}
	ws, db := c.cond.ws, c.cond.db
	best, best_d := Form_ID(0), max(f32)
	for cell in c.w.loaded {
		for r in seating_in(c.w, db, cell) {
			if t.kind == .ObjectID && worldstate.ref_base(ws, db, r) != t.form {continue}
			d := linalg.length(worldstate.ref_pos(ws, db, r).xy - p.center.xy)
			if d <= p.radius && d < best_d && usable(c, r, t) {best, best_d = r, d}
		}
	}
	if best != 0 {c.agent.found[slot] = best}
}

// seating_in is the furniture and idle marker refs a cell's records place, listed on first use.
@(private)
seating_in :: proc(w: ^World, db: ^gamedb.DB, cell: Form_ID) -> []Form_ID {
	if list, ok := w.seating[cell]; ok {return list[:]}
	list := make([dynamic]Form_ID)
	for r in gamedb.refs_of(db, cell) {
		if marker, _ := gamedb.is_idle_marker(db, r.base); marker || gamedb.is_furniture(db, r.base) {append(&list, r.form_id)}
	}
	w.seating[cell] = list
	return list[:]
}

// usable is whether the actor may use a furniture ref now: enabled, with a free marker of the
// criteria's kind, and, for a bed, its own or no one's.
@(private = "file")
usable :: proc(c: ^Proc_Context, ref: Form_ID, t: gamedb.Package_Target) -> bool {
	ws, db := c.cond.ws, c.cond.db
	if !gamedb.is_furniture(db, worldstate.ref_base(ws, db, ref)) {return false}
	kind: Maybe(nif.Marker_Kind)
	if t.kind == .ObjectType {
		switch t.value {
		case OBJECT_FURNITURE:
		case OBJECT_BEDS:   kind = .Lay
		case OBJECT_CHAIRS: kind = .Sit
		case:               return false
		}
	}
	if !worldstate.ref_enabled(ws, db, ref) {return false}
	if _, free := free_marker(c, ref, kind); !free {return false}
	return kind != .Lay || may_sleep_in(c, ref)
}

// may_sleep_in is whether a bed is the actor's own or no one's.
@(private = "file")
may_sleep_in :: proc(c: ^Proc_Context, bed: Form_ID) -> bool {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	owner := worldstate.owner(ws, db, bed)
	return owner == 0 || owner == actor || owner == worldstate.ref_base(ws, db, actor) || worldstate.in_faction(ws, db, actor, owner)
}

// free_marker is the first marker of a ref, of the kind when given, that no other actor holds.
@(private)
free_marker :: proc(c: ^Proc_Context, ref: Form_ID, kind: Maybe(nif.Marker_Kind)) -> (int, bool) {
	for m, i in markers_of(c.w, c.cond.ws, c.cond.db, ref) {
		if k, ok := kind.?; ok && m.kind != k {continue}
		if !taken(c, {ref, i}) {return i, true}
	}
	return 0, false
}

// taken is whether another actor holds a seat.
@(private)
taken :: proc(c: ^Proc_Context, s: Seat) -> bool {
	holder := c.w.seats[s]
	return holder != 0 && holder != c.cond.subject && c.w.agents[holder].seat == s
}

// claim takes a seat for the actor, unless another holds it.
@(private)
claim :: proc(c: ^Proc_Context, s: Seat) -> bool {
	if taken(c, s) {return false}
	if c.agent.seat != s {c.agent.seat, c.agent.posture = s, .Standing}
	c.w.seats[s] = c.cond.subject
	return true
}

// leave gives up the actor's seat.
@(private)
leave :: proc(a: ^Agent) {
	a.seat, a.posture = {}, .Standing
}

// settle walks to the claimed seat and takes it. True once on it.
@(private)
settle :: proc(c: ^Proc_Context) -> bool {
	a := c.agent
	pos, _ := seat_pose(c.w, c.cond.ws, c.cond.db, a.seat)
	d := linalg.length(c.feet.xy - pos.xy)
	if a.posture != .Standing || d <= SEAT_REACH || a.mover.stuck && d <= SEAT_NEAR {
		a.posture = posture_on(c.w, c.cond.ws, c.cond.db, a.seat)
		a.mover.goal = {}
		return true
	}
	a.mover.goal = {active = true, point = pos, radius = SEAT_REACH, gait = gait(c), cell = worldstate.ref_grid_cell(c.cond.ws, c.cond.db, a.seat.furniture)}
	return false
}

// proc_seat walks to a free marker of the furniture its input names (a Find's ObjectList, or a
// ref) and ends seated on it. It waits while the Find beside it has found nothing.
proc_seat :: proc(c: ^Proc_Context, kind: nif.Marker_Kind) -> Status {
	a := c.agent
	ref := input_target(c, 0)
	if slot, ok := input_slot(c, 0); ok {ref = a.found[slot]}
	if ref == 0 {return .Running}
	if a.seat.furniture != ref {
		marker, free := free_marker(c, ref, kind)
		if !free {marker, free = free_marker(c, ref, nil)}
		if !free || !claim(c, {ref, marker}) {return .Running}
	}
	return .Done if settle(c) else .Running
}

// proc_idle_marker walks to its idle marker and stays there; it waits while another actor holds it.
proc_idle_marker :: proc(c: ^Proc_Context) -> Status {
	ref := input_target(c, 0)
	if ref == 0 {return .Failed}
	if claim(c, {ref, 0}) {
		settle(c)
	} else {
		c.agent.mover.goal = {}
	}
	return .Running
}

// posture_on is how an actor holds a seat: an idle marker stands, a Lay marker sleeps.
@(private = "file")
posture_on :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, s: Seat) -> Posture {
	markers := markers_of(w, ws, db, s.furniture)
	if s.marker >= len(markers) {return .Idling}
	return .Sleeping if markers[s.marker].kind == .Lay else .Sitting
}

// seat_pose is where a seat puts an actor's feet in the world, and the way it faces.
@(private = "file")
seat_pose :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, s: Seat) -> (pos: [3]f32, heading: f32) {
	markers := markers_of(w, ws, db, s.furniture)
	rot := worldstate.ref_rot(ws, db, s.furniture)
	if s.marker >= len(markers) {return worldstate.ref_pos(ws, db, s.furniture), rot.z}
	m := markers[s.marker]
	world := smath.trs(worldstate.ref_pos(ws, db, s.furniture), rot, worldstate.ref_scale(ws, db, s.furniture))
	p := world * [4]f32{m.offset.x, m.offset.y, m.offset.z, 1}
	return p.xyz, math.mod(rot.z + m.heading, math.TAU)
}

// seated is the pose an actor on its seat holds; the app pins its capsule there.
seated :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> (pos: [3]f32, heading: f32, ok: bool) {
	a, has := &w.agents[actor]
	if !has || a.posture == .Standing {return}
	pos, heading = seat_pose(w, ws, db, a.seat)
	return pos, heading, true
}

@(private)
markers_of :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, ref: Form_ID) -> []nif.Furniture_Marker {
	base := worldstate.ref_base(ws, db, ref)
	if w.furniture.markers == nil || !gamedb.is_furniture(db, base) {return nil}
	return w.furniture.markers(w.furniture.user, base)
}

// input_slot is the input index of the node's k-th input when it is an ObjectList: the slot a Find writes.
@(private = "file")
input_slot :: proc(c: ^Proc_Context, k: int) -> (slot: u8, ok: bool) {
	ins := gamedb.package_tree(c.cond.db, c.agent.pack)[c.node].inputs
	if k >= len(ins) {return}
	in_ := gamedb.package_input(c.cond.db, c.agent.pack, ins[k]) or_return
	return ins[k], in_.kind == .ObjectList
}
