package ai

// Packages (PACK). An actor runs the first package it may run now. A package is a template's
// procedure tree with the instance's inputs; the engine walks the tree as data.

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "../conditions"
import "../formid"
import "../gamedb"
import "../nav"
import "../worldstate"

// select_package is the package an actor runs now, and the quest whose alias gave it: alias
// packages by quest priority, then its own list, then its default list; the first whose schedule
// and conditions pass. Scene packages are `scene-packages`.
select_package :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> (pack, quest: Form_ID) {
	Candidate :: struct {
		pack, quest: Form_ID,
		priority:    u8,
	}
	list := make([dynamic]Candidate, context.temp_allocator)
	holders, _ := ws.alias_holders[actor] // never range a missing map key
	for h in holders {
		q, id, _ := formid.alias_key(h)
		alias, _ := gamedb.quest_alias(db, q, id)
		qb, _ := gamedb.quest_baseline_of(db, q)
		for p in alias.packages {append(&list, Candidate{p, q, qb.priority})}
	}
	slice.stable_sort_by(list[:], proc(a, b: Candidate) -> bool {return a.priority > b.priority})
	own, defaults := gamedb.actor_packages(db, worldstate.ref_base(ws, db, actor), worldstate.actor_pick(ws, db, actor))
	for p in own {append(&list, Candidate{pack = p})}
	for p in defaults {append(&list, Candidate{pack = p})}
	for c in list {
		p := gamedb.package_of(db, c.pack) or_continue
		ctx := conditions.Context{db = db, ws = ws, subject = actor, quest = p.owner_quest if p.owner_quest != 0 else c.quest, quest_vars = w.quest_vars}
		if schedule_open(ws, p.schedule) && conditions.all(&ctx, p.conditions) {return c.pack, ctx.quest}
	}
	return 0, 0
}

// schedule_open is whether a package's schedule allows it now. Month and date are never set in vanilla and are not read.
schedule_open :: proc(ws: ^worldstate.World_State, s: gamedb.Package_Schedule) -> bool {
	today := worldstate.weekday(ws)
	if s.hour < 0 || s.duration == 0 {return day_matches(s.day_of_week, today)}
	_, _, _, hour := worldstate.game_date(ws)
	now := hour * 60
	start := f64(s.hour) * 60 + f64(max(s.minute, 0))
	end := start + f64(s.duration)
	if now >= start && now < end {return day_matches(s.day_of_week, today)}
	return now + 1440 < end && day_matches(s.day_of_week, (today + 6) % 7) // began yesterday, runs past midnight
}

// day_matches reads PSDT's day of week: -1 any, 0 Sundas .. 6 Loredas, then 7 weekdays, 8 weekends,
// 9 Morndas/Middas/Fredas, 10 Tirdas/Turdas.
@(private = "file")
day_matches :: proc(d: i8, day: i64) -> bool {
	switch d {
	case 0 ..= 6: return i64(d) == day
	case 7:       return day >= 1 && day <= 5
	case 8:       return day == 0 || day == 6
	case 9:       return day == 1 || day == 3 || day == 5
	case 10:      return day == 2 || day == 4
	}
	return true
}

Status :: enum u8 {
	Running,
	Done,
	Failed,
}

// Node_State is what one tree node remembers while its package runs.
Node_State :: struct {
	child:   i32, // Sequence: the child running; Random: the child picked; 0 = not yet
	done:    bool,
	started: bool,
	point:   [3]f32, // a procedure's chosen spot
	target:  Form_ID, // a procedure's chosen ref (Patrol: the next marker)
	timer:   f32, // seconds
}

// Proc_Context is what a procedure sees: its actor (the condition subject), the agent it drives
// and the package node it runs.
Proc_Context :: struct {
	cond:  conditions.Context,
	agent: ^Agent,
	mesh:   ^nav.Path_Mesh,
	routes: ^nav.Route_Index,
	feet:  [3]f32,
	dt:    f32,
	node:  int,
}

// run_tree runs one tick of the agent's package. The root done, the actor stands until another package is selected.
run_tree :: proc(c: ^Proc_Context) -> Status {
	tree := gamedb.package_tree(c.cond.db, c.agent.pack)
	if len(tree) == 0 {return .Done}
	return run_node(c, tree, 0)
}

// run_node runs one tick of a node. Children of node i start at i+1; each next one starts at the
// previous one's `end`. A failed child counts as done.
@(private = "file")
run_node :: proc(c: ^Proc_Context, tree: []gamedb.Package_Node, i: int) -> Status {
	st := &c.agent.nodes[i]
	if st.done {return .Done}
	n := tree[i]
	status := Status.Done
	switch n.branch {
	case .Procedure:
		c.node = i
		status = run_procedure(c, n.procedure)
	case .Sequence:
		k := int(st.child) if st.child > 0 else i + 1
		for ; k < int(n.end); k = int(tree[k].end) {
			if passes(c, tree[k]) && run_node(c, tree, k) == .Running {
				status = .Running
				break
			}
		}
		st.child = i32(k)
	case .Stacked:
		for k := i + 1; k < int(n.end); k = int(tree[k].end) {
			if passes(c, tree[k]) {
				status = run_node(c, tree, k)
				break
			}
		}
	case .Simultaneous: // done when any child finishes; a failed child (a Guard with no post) is ignored
		status = .Failed
		for k := i + 1; k < int(n.end); k = int(tree[k].end) {
			if !passes(c, tree[k]) {continue}
			switch run_node(c, tree, k) {
			case .Done:    status = .Done
			case .Running: if status == .Failed {status = .Running}
			case .Failed:
			}
		}
	case .Random:
		if st.child == 0 {
			kids := make([dynamic]int, context.temp_allocator)
			for k := i + 1; k < int(n.end); k = int(tree[k].end) {append(&kids, k)}
			if len(kids) > 0 {st.child = i32(rand.choice(kids[:]))}
		}
		if st.child > 0 {status = run_node(c, tree, int(st.child))}
	}
	if status != .Running {st.done = true}
	return status
}

@(private = "file")
passes :: proc(c: ^Proc_Context, n: gamedb.Package_Node) -> bool {
	return conditions.all(&c.cond, n.conditions)
}

// run_procedure runs one tick of a procedure leaf. The name is the PNAM string, so a mod can name its own.
run_procedure :: proc(c: ^Proc_Context, name: string) -> Status {
	switch name {
	case "Travel":                        return proc_travel(c)
	case "Sandbox":                       return proc_sandbox(c)
	case "Find", "Sit", "Sleep", "Eat", "Acquire": return proc_furniture(c, name)
	case "Patrol":                        return proc_patrol(c)
	case "UseIdleMarker":                 return proc_idle_marker(c)
	case "Wait", "HoldPosition":          return proc_wait(c)
	case "Guard":                         return proc_guard(c)
	case "Wander":                        return proc_wander(c)
	case "LockDoors", "UnlockDoors":      return proc_doors(c, name == "LockDoors")
	}
	return lua_procedure(c, name)
}

// (hole default-gait :tags ai :sev polish) a package without the preferred-speed flag walks; unsourced (the record stores Run there).
// gait is the package's preferred speed.
@(private)
gait :: proc(c: ^Proc_Context) -> Gait {
	p, _ := gamedb.package_of(c.cond.db, c.agent.pack)
	return p.speed if p.flags & gamedb.PACK_PREFERRED_SPEED != 0 else .Walk
}

// travel_radius is how near Travel goes: to the point itself, whatever the package radius (a guard
// post's is up to 1000, and it would stop at the edge), except to be anywhere in a cell.
@(private)
travel_radius :: proc(c: ^Proc_Context, p: Place) -> f32 {
	tree := gamedb.package_tree(c.cond.db, c.agent.pack)
	for idx in tree[c.node].inputs {
		in_ := gamedb.package_input(c.cond.db, c.agent.pack, idx) or_continue
		if l, is := in_.value.(gamedb.Package_Location); is && l.kind == .InCell {return p.radius}
	}
	return TRAVEL_RADIUS
}

// (hole package-radius-min :tags ai :sev polish) a radius of 0 (2,800 packages) becomes TRAVEL_RADIUS or SANDBOX_RADIUS; unsourced.
TRAVEL_RADIUS :: f32(64)
SANDBOX_RADIUS :: f32(256)

// Place is where a location input points: a centre, a radius and the (grid) cell it is in.
Place :: struct {
	center: [3]f32,
	radius: f32,
	cell:   Form_ID,
}

// location is the place a procedure's location input names. Object and package-location kinds
// are not resolved.
@(private)
location :: proc(c: ^Proc_Context) -> (p: Place, ok: bool) {
	db, ws, actor := c.cond.db, c.cond.ws, c.cond.subject
	tree := gamedb.package_tree(db, c.agent.pack)
	loc: gamedb.Package_Location
	found := false
	for idx in tree[c.node].inputs {
		in_ := gamedb.package_input(db, c.agent.pack, idx) or_continue
		if l, is := in_.value.(gamedb.Package_Location); is {loc, found = l, true; break}
	}
	if !found {return}
	p.radius = f32(loc.radius)
	ref: Form_ID
	#partial switch loc.kind {
	case .NearRef:
		ref = loc.form
	case .NearLinkedRef:
		ref = gamedb.linked_ref(db, actor, loc.form) or_return
	case .AliasRef:
		ref = worldstate.alias_ref(ws, c.cond.quest, loc.value)
	case .NearEditorLoc:
		r := gamedb.ref_by_formid(db, actor) or_return
		p.center, p.cell = r.pos, gamedb.grid_cell(db, r.cell_form_id, r.pos)
	case .NearPackageStart:
		p.center, p.cell = c.agent.start_pos, worldstate.ref_grid_cell(ws, db, actor)
	case .NearSelf:
		p.center, p.cell = c.feet, worldstate.ref_grid_cell(ws, db, actor)
	case .InCell:
		lo, hi := [3]f32{max(f32), max(f32), max(f32)}, [3]f32{min(f32), min(f32), min(f32)}
		for m in gamedb.navmeshes_in(db, loc.form) {
			for v in m.verts {lo, hi = linalg.min(lo, v), linalg.max(hi, v)}
		}
		if lo.x > hi.x {return}
		p.center, p.radius, p.cell = (lo + hi) / 2, linalg.length(hi.xy - lo.xy) / 2, loc.form
	case:
		return
	}
	if ref != 0 {p.center, p.cell = worldstate.ref_pos(ws, db, ref), worldstate.ref_grid_cell(ws, db, ref)}
	return p, p.cell != 0 || ref != 0
}

// reached is whether the actor stands inside a place: same interior or worldspace, within its radius.
@(private)
reached :: proc(c: ^Proc_Context, p: Place) -> bool {
	db := c.cond.db
	here := worldstate.ref_grid_cell(c.cond.ws, db, c.cond.subject)
	return space(db, here) == space(db, p.cell) && linalg.length(c.feet.xy - p.center.xy) <= p.radius
}

@(private = "file")
space :: proc(db: ^gamedb.DB, cell: Form_ID) -> Form_ID {
	cl, _ := gamedb.cell_by_formid(db, cell)
	return cell if cl.interior else cl.world_form_id
}

// (hole lua-procedures :tags (ai script) :sev gap) a procedure the engine does not know fails; decided: a mod can define one in Lua by its PNAM name. Also the other vanilla leaves (Follow, Escort, ForceGreet, Guard, KeepAnEyeOn, UseWeapon, ...) land here until their own holes build them.
lua_procedure :: proc(c: ^Proc_Context, name: string) -> Status {
	return .Failed
}

// proc_travel walks to the package location and ends there. A moving target (the player) is
// re-aimed each tick.
proc_travel :: proc(c: ^Proc_Context) -> Status {
	p, ok := location(c)
	if !ok {return .Failed}
	p.radius = travel_radius(c, p)
	if reached(c, p) {
		c.agent.mover.goal = {}
		return .Done
	}
	c.agent.mover.goal = {active = true, point = p.center, radius = p.radius, gait = gait(c), cell = p.cell}
	return .Running
}

// (hole proc-sandbox :tags ai :sev gap :needs proc-furniture) Sandbox only wanders: it never sits, eats, sleeps or uses an idle marker (IDLM is not decoded), whatever the package flags allow.
proc_sandbox :: proc(c: ^Proc_Context) -> Status {
	st := &c.agent.nodes[c.node]
	p, ok := location(c)
	center, radius := p.center if ok else c.feet, max(p.radius, SANDBOX_RADIUS)
	if ok && p.cell not_in c.mesh.cells { // walk there first; spots are picked on the loaded navmesh
		c.agent.mover.goal = {active = true, point = center, radius = radius, gait = .Walk, cell = p.cell}
		return .Running
	}
	if !st.started || (arrived(c, st.point) && st.timer <= 0) {
		st.point = nav.random_point_near(c.mesh, center, radius) or_else center
		st.timer = rand.float32_range(SANDBOX_IDLE[0], SANDBOX_IDLE[1])
		st.started = true
	}
	if c.agent.mover.stuck {st.timer = 0}
	if arrived(c, st.point) || c.agent.mover.stuck {st.timer -= c.dt}
	c.agent.mover.goal = {active = true, point = st.point, radius = ARRIVED, gait = .Walk}
	return .Running
}

SANDBOX_IDLE :: [2]f32{5, 15} // seconds at a spot before the next
ARRIVED :: f32(48)

@(private = "file")
arrived :: proc(c: ^Proc_Context, p: [3]f32) -> bool {
	return linalg.length(c.feet.xy - p.xy) <= ARRIVED
}

// (hole proc-furniture :tags ai :sev gap) Find, Sit, Sleep, Eat and Acquire never finish: wanted find a free bed, chair or food by object type (Chairs 550, Food 505, Beds 417), walk to its marker, face its heading and hold it.
// proc_furniture keeps looking, so a Simultaneous beside it (Travel, Sandbox) does the moving.
proc_furniture :: proc(c: ^Proc_Context, name: string) -> Status {
	return .Running
}

SEAT_RADIUS :: f32(256) // placed this near its furniture ref, an actor is already on the seat

// seat is the furniture ref the actor's package sits or sleeps it in, when it is placed there.
seat :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32) -> (furniture, pack: Form_ID) {
	quest: Form_ID
	pack, quest = select_package(w, ws, db, actor)
	if pack == 0 {return}
	a := Agent{pack = pack}
	c := Proc_Context{cond = {db = db, ws = ws, subject = actor, quest = quest, quest_vars = w.quest_vars}, agent = &a, feet = feet}
	for n, i in gamedb.package_tree(db, pack) {
		if n.branch != .Procedure || (n.procedure != "Sit" && n.procedure != "Sleep") {continue}
		c.node = i
		for k in 0 ..< len(n.inputs) {
			ref := input_target(&c, k)
			if ref != 0 && linalg.length(worldstate.ref_pos(ws, db, ref).xy - feet.xy) <= SEAT_RADIUS {return ref, pack}
		}
	}
	return 0, pack
}

// (hole patrol-marker-idle :tags ai :sev gap) a patrol never pauses at a marker: the marker's patrol data (REFR XPRD idle time, idle, topic) is not decoded.
// proc_patrol walks the linked-ref chain of markers from the PathStart input, starting at the
// nearest one when asked; a repeatable patrol starts over at the end of the chain.
proc_patrol :: proc(c: ^Proc_Context) -> Status {
	PATROL_RADIUS :: f32(128)
	db, ws := c.cond.db, c.cond.ws
	st := &c.agent.nodes[c.node]
	repeat := input_value(c, 2, bool) or_else true
	if !st.started {
		st.started = true
		st.target = input_target(c, 0)
		if input_value(c, 3, bool) or_else false {st.target = nearest_marker(ws, db, st.target, c.feet)}
	}
	if st.target == 0 {return .Failed}
	at := worldstate.ref_pos(ws, db, st.target)
	radius := max(input_value(c, 1, f32) or_else PATROL_RADIUS, ARRIVED)
	if linalg.length(c.feet.xy - at.xy) <= radius {
		next, _ := gamedb.linked_ref(db, st.target)
		if next == 0 && repeat {next = input_target(c, 0)}
		if next == 0 {
			c.agent.mover.goal = {}
			return .Done
		}
		st.target = next
		at = worldstate.ref_pos(ws, db, next)
	}
	c.agent.mover.goal = {active = true, point = at, radius = radius, gait = gait(c), cell = worldstate.ref_grid_cell(ws, db, st.target)}
	return .Running
}

// patrol_place is where a Patrol starts: its PathStart marker, or the nearest of the chain.
@(private)
patrol_place :: proc(c: ^Proc_Context) -> (p: Place, ok: bool) {
	ws, db := c.cond.ws, c.cond.db
	start := input_target(c, 0)
	if input_value(c, 3, bool) or_else false {start = nearest_marker(ws, db, start, c.feet)}
	if start == 0 {return}
	return {worldstate.ref_pos(ws, db, start), TRAVEL_RADIUS, worldstate.ref_grid_cell(ws, db, start)}, true
}

// nearest_marker is the marker of the chain from `start` nearest p.
@(private = "file")
nearest_marker :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, start: Form_ID, p: [3]f32) -> Form_ID {
	best, best_d := start, max(f32)
	for m, n := start, 0; m != 0 && n < 256; n += 1 {
		if d := linalg.length(worldstate.ref_pos(ws, db, m).xy - p.xy); d < best_d {best, best_d = m, d}
		m, _ = gamedb.linked_ref(db, m)
		if m == start {break}
	}
	return best
}

// input_value is the node's k-th input (its PKC2 slot), when it holds a T.
@(private = "file")
input_value :: proc(c: ^Proc_Context, k: int, $T: typeid) -> (v: T, ok: bool) {
	tree := gamedb.package_tree(c.cond.db, c.agent.pack)
	ins := tree[c.node].inputs
	if k >= len(ins) {return}
	in_ := gamedb.package_input(c.cond.db, c.agent.pack, ins[k]) or_return
	return in_.value.(T)
}

// input_target is the ref the node's k-th input names (SpecificRef, or the actor's linked ref).
@(private = "file")
input_target :: proc(c: ^Proc_Context, k: int) -> Form_ID {
	t, ok := input_value(c, k, gamedb.Package_Target)
	if !ok {return 0}
	#partial switch t.kind {
	case .SpecificRef: return t.form
	case .LinkedRef:
		ref, _ := gamedb.linked_ref(c.cond.db, c.cond.subject, t.form)
		return ref
	case .Self: return c.cond.subject
	}
	return 0
}

// (hole proc-idle-marker :tags ai :sev gap ) UseIdleMarker does nothing: wanted walk to the IDLM ref and play its idle (the idle itself is animation).
proc_idle_marker :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-guard :tags (ai combat) :sev gap) Guard only walks to its post and stands: no watching the area, no warning or attacking trespassers.
// proc_guard walks to the package location and holds it.
proc_guard :: proc(c: ^Proc_Context) -> Status {
	if proc_travel(c) == .Failed {return .Failed}
	return .Running
}

// proc_wait stands until the package or its parent ends.
proc_wait :: proc(c: ^Proc_Context) -> Status {
	c.agent.mover.goal = {}
	return .Running
}

// (hole proc-wander :tags ai :sev polish ) Wander does nothing (5 uses, all in Sit trees).
proc_wander :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-doors :tags ai :sev polish) LockDoors and UnlockDoors do nothing: wanted lock or unlock the doors of the package location's cell.
proc_doors :: proc(c: ^Proc_Context, lock: bool) -> Status {
	return .Done
}
