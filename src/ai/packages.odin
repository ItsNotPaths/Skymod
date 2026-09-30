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

// Override is the override lists an actor picks its package from: in a fight, only its combat
// lists; watching one, its spectator lists before its own.
Override :: enum u8 {
	None,
	Combat,
	Spectator,
}

// override_now is the override lists the agent picks from now.
override_now :: proc(a: Agent) -> Override {
	if a.combat.state != .None {return .Combat}
	return .Spectator if a.spectating > 0 else .None
}

// select_package is the package an actor runs now, and the quest whose alias gave it: a scene's
// package action, else alias packages by quest priority, then its own list, then its default list;
// the first whose schedule and conditions pass. Under an override the lists of that kind come
// first, alias ones by quest priority; in a fight nothing else does.
select_package :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> (pack, quest: Form_ID) {
	over := override_now(w.agents[actor] or_else {})
	if over != .Combat {
		if p, q, _ := worldstate.scene_package(ws, db, actor); p != 0 {return p, q}
	}
	Candidate :: struct {
		pack, quest: Form_ID,
		priority:    u8,
	}
	base, pick := worldstate.ref_base(ws, db, actor), worldstate.actor_pick(ws, db, actor)
	list := make([dynamic]Candidate, context.temp_allocator)
	add_aliases :: proc(list: ^[dynamic]Candidate, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, over: Override) {
		from := len(list)
		for h in worldstate.aliases_of(ws, actor) {
			q, id, _ := formid.alias_key(h)
			alias, _ := gamedb.quest_alias(db, q, id)
			qb, _ := gamedb.quest_baseline_of(db, q)
			packs := alias.packages if over == .None else override_list(db, alias.overrides, over)
			for p in packs {append(list, Candidate{p, q, qb.priority})}
		}
		slice.stable_sort_by(list[from:], proc(a, b: Candidate) -> bool {return a.priority > b.priority})
	}
	if over != .None {
		add_aliases(&list, ws, db, actor, over)
		for p in override_list(db, gamedb.actor_overrides(db, base, pick), over) {append(&list, Candidate{pack = p})}
	}
	if over != .Combat {
		add_aliases(&list, ws, db, actor, .None)
		own, defaults := gamedb.actor_packages(db, base, pick)
		for p in own {append(&list, Candidate{pack = p})}
		for p in defaults {append(&list, Candidate{pack = p})}
	}
	for c in list {
		p := gamedb.package_of(db, c.pack) or_continue
		ctx := conditions.Context{db = db, ws = ws, subject = actor, quest = p.owner_quest if p.owner_quest != 0 else c.quest, pack = c.pack, quest_vars = w.quest_vars}
		if schedule_open(ws, p.schedule) && !worldstate.done_today(ws, actor, c.pack) && conditions.all(&ctx, p.conditions) {return c.pack, ctx.quest}
	}
	return 0, 0
}

@(private = "file")
override_list :: proc(db: ^gamedb.DB, o: gamedb.Override_Packages, over: Override) -> []Form_ID {
	list, _ := gamedb.form_list_of(db, o.combat if over == .Combat else o.spectator)
	return list
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
	w:     ^World,
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
	case .Random: // one child whose conditions pass, like every other branch reads them
		if st.child == 0 {
			kids := make([dynamic]int, context.temp_allocator)
			for k := i + 1; k < int(n.end); k = int(tree[k].end) {
				if passes(c, tree[k]) {append(&kids, k)}
			}
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
	case "Find":                          return proc_find(c)
	case "Sit":                           return proc_seat(c, .Sit)
	case "Sleep":                         return proc_seat(c, .Lay)
	// (hole proc-acquire :tags ai :sev gap) Acquire takes nothing and Eat does nothing: an actor eats fake food, and Find never names food (ALCH food flag not decoded). Picking a world item up lives in script (natives_inventory take/move_items, stacks via the VM), out of the AI's reach. Eating itself is animation.
	case "Eat", "Acquire":                return .Done
	case "Patrol":                        return proc_patrol(c)
	case "UseIdleMarker":                 return proc_idle_marker(c)
	case "Wait":                          return proc_wait(c)
	case "HoldPosition":                  return proc_hold_position(c)
	case "Guard":                         return proc_guard(c)
	case "Wander":                        return proc_wander(c)
	case "LockDoors", "UnlockDoors":      return proc_doors(c, name == "LockDoors")
	case "ForceGreet":                    return proc_force_greet(c)
	case "Follow":                        return proc_follow(c, 0)
	case "FollowTo":                      return proc_follow(c, 1)
	case "Escort":                        return proc_escort(c)
	case "Flee":                          return proc_flee(c)
	case "KeepAnEyeOn":                   return proc_keep_an_eye_on(c)
	case "Activate":                      return proc_activate(c)
	case "Say":                           return proc_say(c)
	case "DialogueActivate":              return proc_dialogue_activate(c)
	case "UseWeapon":                     return proc_use_weapon(c)
	case "UseMagic":                      return proc_use_magic(c)
	// (hole proc-shout :tags (ai combat magic) :sev gap :needs (shouts)) Shout fails: no shout has its words' spells to cast (dragons, Paarthurnax's lessons).
	case "Shout":                         return .Failed
	// (hole flight :tags (animation combat unclaimed) :sev gap) Hover, Orbit and FlightGrab fail: no dragon flies.
	case "Hover", "Orbit", "FlightGrab":  return .Failed
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
	ref:    Form_ID, // the ref it is near, 0 for a fixed place
}

// location is the place a procedure's first location input names.
@(private)
location :: proc(c: ^Proc_Context) -> (p: Place, ok: bool) {
	tree := gamedb.package_tree(c.cond.db, c.agent.pack)
	for idx in tree[c.node].inputs {
		in_ := gamedb.package_input(c.cond.db, c.agent.pack, idx) or_continue
		if l, is := in_.value.(gamedb.Package_Location); is {return place_of(c, l)}
	}
	return
}

// input_place is the place the node's k-th input names.
@(private)
input_place :: proc(c: ^Proc_Context, k: int) -> (p: Place, ok: bool) {
	loc := input_value(c, k, gamedb.Package_Location) or_return
	return place_of(c, loc)
}

// place_of is the place a location input names. Object and package-location kinds are not resolved.
@(private)
place_of :: proc(c: ^Proc_Context, loc: gamedb.Package_Location) -> (p: Place, ok: bool) {
	db, ws, actor := c.cond.db, c.cond.ws, c.cond.subject
	p.radius = f32(loc.radius)
	ref: Form_ID
	#partial switch loc.kind {
	case .NearRef:
		ref = worldstate.resolve(ws, loc.form)
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
	if ref != 0 {p.center, p.cell, p.ref = worldstate.ref_pos(ws, db, ref), worldstate.ref_grid_cell(ws, db, ref), ref}
	return p, p.cell != 0 || ref != 0
}

// reached is whether the actor stands inside a place.
@(private)
reached :: proc(c: ^Proc_Context, p: Place) -> bool {
	return inside(c, c.cond.subject, c.feet, p)
}

// inside is whether a ref at `pos` is inside a place: same interior or worldspace, within its radius.
@(private)
inside :: proc(c: ^Proc_Context, ref: Form_ID, pos: [3]f32, p: Place) -> bool {
	db := c.cond.db
	here := worldstate.ref_grid_cell(c.cond.ws, db, ref)
	return space(db, here) == space(db, p.cell) && linalg.length(pos.xy - p.center.xy) <= p.radius
}

@(private)
space :: proc(db: ^gamedb.DB, cell: Form_ID) -> Form_ID {
	cl, _ := gamedb.cell_by_formid(db, cell)
	return cell if cl.interior else cl.world_form_id
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

// (hole sandbox-choices :tags ai :sev polish) unsourced: a sandbox takes a free chair or idle marker half the time (20-60 s) and a random spot otherwise (5-15 s); it never takes a bed, and Energy, Allow Eating, Allow Conversation, Allow Wandering and the minimum wander distance are not read.
// proc_sandbox moves between spots, chairs and idle markers in the package location, as its
// Allow inputs let it. It stands aside while a Sit or Sleep beside it holds a seat.
proc_sandbox :: proc(c: ^Proc_Context) -> Status {
	st := &c.agent.nodes[c.node]
	a := c.agent
	p, ok := location(c)
	center, radius := p.center if ok else c.feet, max(p.radius, SANDBOX_RADIUS)
	if ok && p.cell not_in c.w.mesh.cells { // walk there first; spots are picked on the loaded navmesh
		a.mover.goal = {active = true, point = center, radius = radius, gait = .Walk, cell = p.cell}
		return .Running
	}
	if a.seat.furniture != 0 && a.seat.furniture != st.target {return .Running}
	if !st.started || st.timer <= 0 {
		st.started = true
		sandbox_pick(c, center, radius)
	}
	if st.target != 0 {
		if settle(c) {st.timer -= c.dt}
		if a.mover.stuck {st.timer = 0}
		return .Running
	}
	if a.mover.stuck {st.timer = 0}
	if arrived(c, st.point) || a.mover.stuck {st.timer -= c.dt}
	a.mover.goal = {active = true, point = st.point, radius = ARRIVED, gait = .Walk}
	return .Running
}

SANDBOX_IDLE :: [2]f32{5, 15} // seconds at a spot before the next
SANDBOX_STAY :: [2]f32{20, 60} // seconds on a chair or at an idle marker

// sandbox_pick chooses the sandbox's next activity: a free chair or idle marker in the location
// that its inputs allow, or a random spot.
@(private = "file")
sandbox_pick :: proc(c: ^Proc_Context, center: [3]f32, radius: f32) {
	ws, db := c.cond.ws, c.cond.db
	st := &c.agent.nodes[c.node]
	if st.target != 0 {leave(c.agent)}
	st.target = 0
	allowed := proc(c: ^Proc_Context, k: int) -> bool {return input_value(c, k, bool) or_else true}
	options := make([dynamic]Seat, context.temp_allocator)
	for cell in c.w.loaded {
		for r in seating_in(c.w, db, cell) {
			if linalg.length(worldstate.ref_pos(ws, db, r).xy - center.xy) > radius || !worldstate.ref_enabled(ws, db, r) {continue}
			base := worldstate.ref_base(ws, db, r)
			if marker, sandbox := gamedb.is_idle_marker(db, base); marker {
				if sandbox && allowed(c, 4) && !taken(c, {r, 0}) {append(&options, Seat{r, 0})}
				continue
			}
			if !allowed(c, 5) || gamedb.is_bench(db, base) && !allowed(c, 9) {continue}
			if i, free := free_marker(c, r, .Sit); free {append(&options, Seat{r, i})}
		}
	}
	if len(options) > 0 && rand.float32() < 0.5 && claim(c, rand.choice(options[:])) {
		st.target = c.agent.seat.furniture
		st.timer = rand.float32_range(SANDBOX_STAY[0], SANDBOX_STAY[1])
		return
	}
	st.point = nav.random_point_near(&c.w.mesh, center, radius) or_else center
	st.timer = rand.float32_range(SANDBOX_IDLE[0], SANDBOX_IDLE[1])
}

ARRIVED :: f32(48)

@(private = "file")
arrived :: proc(c: ^Proc_Context, p: [3]f32) -> bool {
	return linalg.length(c.feet.xy - p.xy) <= ARRIVED
}

// (hole patrol-marker-topic :tags (ai dialogue) :sev polish) a patrol marker's topic (PDTO, on 2 markers: RorikPatrolCommentTopic and a RUMO subtype) is not said on arrival.
// proc_patrol walks the linked-ref chain of markers from the PathStart input, starting at the
// nearest one when asked, and waits at each for its patrol idle time; a repeatable patrol starts
// over at the end of the chain.
proc_patrol :: proc(c: ^Proc_Context) -> Status {
	PATROL_RADIUS :: f32(128)
	db, ws := c.cond.db, c.cond.ws
	st := &c.agent.nodes[c.node]
	repeat := input_value(c, 2, bool) or_else true
	if !st.started {
		st.started = true
		st.target = input_target(c, 0)
		if input_value(c, 3, bool) or_else false {st.target = nearest_marker(ws, db, st.target, c.feet)}
		st.timer = gamedb.patrol_idle(db, st.target)
	}
	if st.target == 0 {return .Failed}
	at := worldstate.ref_pos(ws, db, st.target)
	radius := max(input_value(c, 1, f32) or_else PATROL_RADIUS, ARRIVED)
	if linalg.length(c.feet.xy - at.xy) <= radius {
		st.timer -= c.dt
		if st.timer > 0 {
			c.agent.mover.goal = {}
			return .Running
		}
		next, _ := gamedb.linked_ref(db, st.target)
		if next == 0 && repeat {next = input_target(c, 0)}
		if next == 0 {
			c.agent.mover.goal = {}
			return .Done
		}
		st.target = next
		st.timer = gamedb.patrol_idle(db, next)
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
	return {worldstate.ref_pos(ws, db, start), TRAVEL_RADIUS, worldstate.ref_grid_cell(ws, db, start), start}, true
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
@(private)
input_value :: proc(c: ^Proc_Context, k: int, $T: typeid) -> (v: T, ok: bool) {
	tree := gamedb.package_tree(c.cond.db, c.agent.pack)
	ins := tree[c.node].inputs
	if k >= len(ins) {return}
	in_ := gamedb.package_input(c.cond.db, c.agent.pack, ins[k]) or_return
	return in_.value.(T)
}

// input_target is the ref the node's k-th input names: a SpecificRef, the actor's linked ref, an alias's ref, or itself.
@(private)
input_target :: proc(c: ^Proc_Context, k: int) -> Form_ID {
	t, ok := input_value(c, k, gamedb.Package_Target)
	if !ok {return 0}
	return worldstate.package_target_ref(c.cond.ws, c.cond.db, t, c.cond.subject, c.cond.quest)
}

// proc_guard watches an area, never moving the actor (its siblings do; it does not pursue). An actor
// it is suspicious of comes inside ImmediateAttackRadius of RestrictedArea: it attacks. Inside
// WarnOnlyRadius, where it sees it: trespass lines every fAITrespassWarningTimer, then after
// iGuardWarnings it attacks. The area's owners and the guard's allies and friends are let be (CK:
// Guard (Procedure), build/out/wsK/wiki). Inputs: RestrictedArea, SuspiciousOf, WarnOnlyRadius,
// ImmediateAttackRadius.
// (hole guard-draws-weapon :tags (ai animation unclaimed) :sev polish :needs (actor-states)) a Guard does not draw its weapon while it warns: no actor has a drawn state.
proc_guard :: proc(c: ^Proc_Context) -> Status {
	ws, db, guard := c.cond.ws, c.cond.db, c.cond.subject
	area, ok := input_place(c, 0)
	if !ok {return .Running}
	suspect, _ := input_value(c, 1, gamedb.Package_Target)
	warn, attack := input_value(c, 2, f32) or_else 0, input_value(c, 3, f32) or_else 0
	area_owner := worldstate.owner(ws, db, area.ref if area.ref != 0 else area.cell)
	for other in c.w.present {
		if other == guard || worldstate.is_dead(ws, db, other) || !suspicious(c, suspect, other) {continue}
		if area_owner != 0 && worldstate.owns(ws, db, other, area_owner) || worldstate.faction_relation(ws, db, guard, other) >= .Ally {continue}
		d := max(linalg.length(worldstate.ref_pos(ws, db, other).xy - area.center.xy) - area.radius, 0) // from the area's edge
		if d <= attack || d <= warn && worldstate.detected(ws, guard, other) && worldstate.warn_step(ws, db, guard, other, c.dt) {
			c.agent.combat = {state = .Combat, target = other}
		}
	}
	return .Running
}

// suspicious: `other` is whom a Guard's SuspiciousOf names: that ref, or a member of that faction,
// or an actor of that base.
@(private = "file")
suspicious :: proc(c: ^Proc_Context, t: gamedb.Package_Target, other: Form_ID) -> bool {
	ws, db := c.cond.ws, c.cond.db
	if t.kind == .ObjectID {
		if _, is_faction := worldstate.faction(ws, db, t.form); is_faction {return worldstate.in_faction(ws, db, other, t.form)}
		return worldstate.ref_base(ws, db, other) == t.form
	}
	ref := worldstate.package_target_ref(ws, db, t, c.cond.subject, c.cond.quest)
	return ref != 0 && ref == other
}

// proc_wait stands until the package or its parent ends.
proc_wait :: proc(c: ^Proc_Context) -> Status {
	c.agent.mover.goal = {}
	return .Running
}

// proc_hold_position waits; in a fight it fights from inside its place, never chasing out of it.
proc_hold_position :: proc(c: ^Proc_Context) -> Status {
	if c.agent.combat.state == .None {return proc_wait(c)}
	p, ok := location(c)
	if !ok {return .Running}
	g := &c.agent.mover.goal
	off := g.point.xy - p.center.xy
	if radius := max(p.radius, TRAVEL_RADIUS); g.active && linalg.length(off) > radius {
		g.point.xy = p.center.xy + linalg.normalize(off) * radius
		g.radius = ARRIVED
	}
	return .Running
}

// (hole wander-legs :tags ai :sev polish) unsourced: Wander walks one leg to a random spot in the location and ends (its 5 uses sit in a Sequence before a Sit, which must run); "Wander Preferred Path Only?" is not read.
// proc_wander walks to a random spot in the package location and ends there.
proc_wander :: proc(c: ^Proc_Context) -> Status {
	st := &c.agent.nodes[c.node]
	if !st.started {
		st.started = true
		p, ok := location(c)
		center := p.center if ok else c.feet
		st.point = nav.random_point_near(&c.w.mesh, center, max(p.radius, SANDBOX_RADIUS)) or_else center
	}
	if arrived(c, st.point) || c.agent.mover.stuck {
		c.agent.mover.goal = {}
		return .Done
	}
	c.agent.mover.goal = {active = true, point = st.point, radius = ARRIVED, gait = .Walk}
	return .Running
}

// (hole door-lock-scope :tags ai :sev polish) unsourced: LockDoors and UnlockDoors change only the load doors of an interior package location and their far sides, and nothing warns the player before a lock.
// proc_doors locks or unlocks the ways into an interior package location: its load doors and the doors they lead to.
proc_doors :: proc(c: ^Proc_Context, lock: bool) -> Status {
	ws, db := c.cond.ws, c.cond.db
	p, ok := location(c)
	cl, _ := gamedb.cell_by_formid(db, p.cell)
	if !ok || !cl.interior {return .Done}
	for r in gamedb.refs_of(db, p.cell) {
		if !gamedb.is_door(db, r.base) || r.teleport.door == 0 {continue}
		worldstate.set_locked(ws, r.form_id, p.cell, lock)
		worldstate.set_locked(ws, r.teleport.door, worldstate.ref_cell(ws, db, r.teleport.door), lock)
	}
	return .Done
}
