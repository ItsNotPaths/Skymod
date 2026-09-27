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
	own, defaults := gamedb.actor_packages(db, worldstate.ref_base(ws, db, actor))
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
	timer:   f32, // seconds
}

// Proc_Context is what a procedure sees: its actor (the condition subject), the agent it drives
// and the package node it runs.
Proc_Context :: struct {
	cond:  conditions.Context,
	agent: ^Agent,
	mesh:  ^nav.Path_Mesh,
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
	case .Simultaneous: // done when its first child is
		first := true
		for k := i + 1; k < int(n.end); k = int(tree[k].end) {
			if !passes(c, tree[k]) {continue}
			s := run_node(c, tree, k)
			if first {status, first = s, false}
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
	case "Wander":                        return proc_wander(c)
	case "LockDoors", "UnlockDoors":      return proc_doors(c, name == "LockDoors")
	}
	return lua_procedure(c, name)
}

// (hole default-gait :tags ai :sev polish) a package without the preferred-speed flag walks; unsourced (the record stores Run there).
// gait is the package's preferred speed.
@(private = "file")
gait :: proc(c: ^Proc_Context) -> Gait {
	p, _ := gamedb.package_of(c.cond.db, c.agent.pack)
	return p.speed if p.flags & gamedb.PACK_PREFERRED_SPEED != 0 else .Walk
}

// (hole package-radius-min :tags ai :sev polish) a radius of 0 (2,800 packages) becomes TRAVEL_RADIUS or SANDBOX_RADIUS; unsourced.
TRAVEL_RADIUS :: f32(64)
SANDBOX_RADIUS :: f32(256)

// location is the place a procedure's location input names: a centre and a radius. Object and
// package-location kinds are not resolved.
@(private)
location :: proc(c: ^Proc_Context) -> (center: [3]f32, radius: f32, ok: bool) {
	db, ws, actor := c.cond.db, c.cond.ws, c.cond.subject
	tree := gamedb.package_tree(db, c.agent.pack)
	loc: gamedb.Package_Location
	found := false
	for idx in tree[c.node].inputs {
		in_ := gamedb.package_input(db, c.agent.pack, idx) or_continue
		if l, is := in_.value.(gamedb.Package_Location); is {loc, found = l, true; break}
	}
	if !found {return}
	radius = f32(loc.radius)
	#partial switch loc.kind {
	case .NearRef:
		center = worldstate.ref_pos(ws, db, loc.form)
	case .NearLinkedRef:
		ref := gamedb.linked_ref(db, actor, loc.form) or_return
		center = worldstate.ref_pos(ws, db, ref)
	case .NearEditorLoc:
		r := gamedb.ref_by_formid(db, actor) or_return
		center = r.pos
	case .NearPackageStart:
		center = c.agent.start_pos
	case .NearSelf:
		center = c.feet
	case .AliasRef:
		ref := worldstate.alias_ref(ws, c.cond.quest, loc.value)
		if ref == 0 {return}
		center = worldstate.ref_pos(ws, db, ref)
	case .InCell:
		lo, hi := [3]f32{max(f32), max(f32), max(f32)}, [3]f32{min(f32), min(f32), min(f32)}
		for m in gamedb.navmeshes_in(db, loc.form) {
			for v in m.verts {lo, hi = linalg.min(lo, v), linalg.max(hi, v)}
		}
		if lo.x > hi.x {return}
		center, radius = (lo + hi) / 2, linalg.length(hi.xy - lo.xy) / 2
	case:
		return
	}
	return center, radius, true
}

// (hole lua-procedures :tags (ai script) :sev gap) a procedure the engine does not know fails; decided: a mod can define one in Lua by its PNAM name. Also the other vanilla leaves (Follow, Escort, ForceGreet, Guard, KeepAnEyeOn, UseWeapon, ...) land here until their own holes build them.
lua_procedure :: proc(c: ^Proc_Context, name: string) -> Status {
	return .Failed
}

// proc_travel walks to the package location and ends there. A moving target (the player) is re-aimed each tick.
proc_travel :: proc(c: ^Proc_Context) -> Status {
	center, radius, ok := location(c)
	if !ok {return .Failed}
	radius = max(radius, TRAVEL_RADIUS)
	if linalg.length(c.feet.xy - center.xy) <= radius {
		c.agent.mover.goal = {}
		return .Done
	}
	c.agent.mover.goal = {active = true, point = center, radius = radius, gait = gait(c)}
	return .Running
}

// (hole proc-sandbox :tags ai :sev blocker) Sandbox does nothing: wanted wander inside the radius, and sit, eat, sleep or use idle markers as the package flags allow.
proc_sandbox :: proc(c: ^Proc_Context) -> Status {
	st := &c.agent.nodes[c.node]
	center, radius, ok := location(c)
	if !ok {center = c.feet}
	radius = max(radius, SANDBOX_RADIUS)
	if !st.started || (arrived(c, st.point) && st.timer <= 0) {
		st.point = nav.random_point_near(c.mesh, center, radius) or_else center
		st.timer = rand.float32_range(SANDBOX_IDLE[0], SANDBOX_IDLE[1])
		st.started = true
	}
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

// (hole proc-furniture :tags ai :sev gap) Find, Sit, Sleep, Eat and Acquire do nothing: wanted find a free bed, chair or food by object type (Chairs 550, Food 505, Beds 417), walk to its marker, face its heading and hold it.
proc_furniture :: proc(c: ^Proc_Context, name: string) -> Status {
	return .Done
}

// (hole proc-patrol :tags ai :sev gap ) Patrol does nothing: wanted walk the linked-ref chain of patrol markers, waiting at each.
proc_patrol :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-idle-marker :tags ai :sev gap ) UseIdleMarker does nothing: wanted walk to the IDLM ref and play its idle (the idle itself is animation).
proc_idle_marker :: proc(c: ^Proc_Context) -> Status {
	return .Done
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
