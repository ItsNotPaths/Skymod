package ai

// Procedures that act toward another ref: follow, escort, flee, watch, activate, greet the player,
// and the ones a mod writes in Lua.

import "core:math/linalg"
import "../formid"
import "../gamedb"
import "../sight"
import "../worldstate"

FOLLOW_SPRINT :: f32(300) // fFollowStartSprintDistance: a follower this far behind runs

// (hole follow-pace :tags ai :sev polish) a follower walks until it falls past MaxRadius, then runs: it does not match the target's pace, sneak when it sneaks, or honour GoToLeadersGoal and NeedLOS.
// proc_follow keeps within MinRadius of the target until the package ends (Follow) or the actor
// reaches EndLocation (FollowTo, whose slots start one later). A dead target fails it (CK).
proc_follow :: proc(c: ^Proc_Context, shift: int) -> Status {
	ws, db := c.cond.ws, c.cond.db
	target := input_target(c, 0)
	if target == 0 || worldstate.is_dead(ws, target) {return .Failed}
	if shift > 0 {
		if end, ok := location(c); ok && reached(c, end) {
			c.agent.mover.goal = {}
			return .Done
		}
	}
	near := max(input_value(c, 1 + shift, f32) or_else 0, ARRIVED)
	far := max(input_value(c, 2 + shift, f32) or_else 0, near)
	at := worldstate.ref_pos(ws, db, target)
	d := linalg.length(at.xy - c.feet.xy)
	g := Gait.Walk
	if d > far {g = .Run if d > FOLLOW_SPRINT else .Jog}
	c.agent.mover.goal = {active = true, point = at, radius = near, gait = g, cell = worldstate.ref_grid_cell(ws, db, target)}
	return .Running
}

// (hole escort-followers :tags ai :sev gap) Escort does not put a Follow package on an escorted NPC, so only the player follows; NumberToEscort, object lists and RunIfBehindDist are unread.
// proc_escort leads the escorted actor to the destination, stopping while it lags farther than
// EscortWaitDist; done at the destination.
proc_escort :: proc(c: ^Proc_Context) -> Status {
	ws, db := c.cond.ws, c.cond.db
	dest, ok := location(c)
	if !ok {return .Failed}
	dest.radius = travel_radius(c, dest)
	if reached(c, dest) {
		c.agent.mover.goal = {}
		return .Done
	}
	if who := input_target(c, 0); who != 0 && !worldstate.is_dead(ws, who) {
		wait := input_value(c, 3, f32) or_else 0
		if wait > 0 && linalg.length(worldstate.ref_pos(ws, db, who).xy - c.feet.xy) > wait {
			c.agent.mover.goal = {}
			return .Running
		}
	}
	c.agent.mover.goal = {active = true, point = dest.center, radius = dest.radius, gait = gait(c), cell = dest.cell}
	return .Running
}

// proc_flee runs from the FleeFrom target until FleeDist away (UseDynamicGoalInstead), else to
// FleeTo within GoalRadius. Object lists of threats are not read, and flee lines are combat-barks.
proc_flee :: proc(c: ^Proc_Context) -> Status {
	ws, db := c.cond.ws, c.cond.db
	if !(input_value(c, 2, bool) or_else false) {
		to, ok := location(c)
		if !ok {return .Failed}
		to.radius = max(input_value(c, 3, f32) or_else 0, ARRIVED)
		if reached(c, to) {
			c.agent.mover.goal = {}
			return .Done
		}
		c.agent.mover.goal = {active = true, point = to.center, radius = to.radius, gait = .Run, cell = to.cell}
		return .Running
	}
	threat := input_target(c, 0)
	if threat == 0 || worldstate.is_dead(ws, threat) {return .Done}
	from := worldstate.ref_pos(ws, db, threat)
	away := c.feet.xy - from.xy
	d := linalg.length(away)
	dist := input_value(c, 5, f32) or_else 0
	if d >= dist {
		c.agent.mover.goal = {}
		return .Done
	}
	dir := away / d if d > 0.001 else [2]f32{1, 0}
	to := from + {dir.x, dir.y, 0} * (dist + ARRIVED)
	c.agent.mover.goal = {active = true, point = {to.x, to.y, c.feet.z}, radius = ARRIVED, gait = .Run}
	return .Running
}

// proc_keep_an_eye_on is a mental procedure beside a physical one: while the target is inside the
// ObservationArea and out of sight (360 degree rays), the actor pursues it until it sees it again
// or the target enters EndPursuitArea (CK). It never ends.
proc_keep_an_eye_on :: proc(c: ^Proc_Context) -> Status {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	target := input_target(c, 0)
	if target == 0 {return .Running}
	at := worldstate.ref_pos(ws, db, target)
	watch, wok := input_place(c, 1)
	end, eok := input_place(c, 2)
	if !wok || !inside(c, target, at, watch) || eok && inside(c, target, at, end) || sight.has_los(ws, db, actor, target) {return .Running}
	c.agent.mover.goal = {active = true, point = at, radius = ARRIVED, gait = .Jog, cell = worldstate.ref_grid_cell(ws, db, target)}
	return .Running
}

ACTIVATE_REACH :: f32(128)

// proc_activate walks to the target and activates it, as the player's Activate key does (OnActivate
// with this actor, then the default action); done after NumberToActivate activations, 1 by default.
proc_activate :: proc(c: ^Proc_Context) -> Status {
	ws, db := c.cond.ws, c.cond.db
	st := &c.agent.nodes[c.node]
	target := input_target(c, 0)
	if target == 0 {return .Failed}
	at := worldstate.ref_pos(ws, db, target)
	if linalg.length(at.xy - c.feet.xy) > ACTIVATE_REACH {
		c.agent.mover.goal = {active = true, point = at, radius = ACTIVATE_REACH, gait = gait(c), cell = worldstate.ref_grid_cell(ws, db, target)}
		return .Running
	}
	c.agent.mover.goal = {}
	append(&ws.activations, worldstate.Activation{target = target, by = c.cond.subject})
	st.child += 1
	return .Done if st.child >= max(input_value(c, 1, i32) or_else 1, 1) else .Running
}

// (hole force-greet-detected :tags (ai dialogue) :sev gap :needs detection-store) ForceGreet ignores "Player must be detected?" and "Forcegreet if player on horseback?": it greets an unseen player, and there are no horses.
// proc_force_greet asks the app for a conversation once the player is inside the node's location
// (ForceGreetLoc; the tree's Travel has walked the actor up already), and is done when it opens.
proc_force_greet :: proc(c: ^Proc_Context) -> Status {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	st := &c.agent.nodes[c.node]
	c.agent.mover.goal = {}
	if st.started {return .Running if ws.force_greet.speaker == actor else .Done}
	if ws.talking != 0 || ws.force_greet.speaker != 0 {return .Running}
	if p, ok := location(c); ok && !inside(c, formid.PLAYER, worldstate.ref_pos(ws, db, formid.PLAYER), p) {return .Running}
	topic, _ := input_value(c, 0, gamedb.Package_Topic)
	ws.force_greet = {actor, topic.topic}
	st.started = true
	return .Running
}


// proc_say says a line of the topic to the target, standing; done when the line ends.
proc_say :: proc(c: ^Proc_Context) -> Status {
	ws, actor := c.cond.ws, c.cond.subject
	st := &c.agent.nodes[c.node]
	c.agent.mover.goal = {}
	if st.started {return .Running if worldstate.speaking(ws, actor) else .Done}
	topic, _ := input_value(c, 0, gamedb.Package_Topic)
	append(&ws.barks, worldstate.Bark{speaker = actor, to = input_target(c, 1), topic = topic.topic, subtype = topic.subtype})
	st.started = true
	return .Running
}

// proc_dialogue_activate walks to the target (within Talk From) and starts a conversation: with
// the player as a ForceGreet does, with an NPC through the Actor Dialogue story event.
proc_dialogue_activate :: proc(c: ^Proc_Context) -> Status {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	target := input_target(c, 0)
	if target == 0 || worldstate.is_dead(ws, target) {return .Failed}
	at := worldstate.ref_pos(ws, db, target)
	from, _ := input_place(c, 1)
	reach := max(from.radius, ARRIVED)
	if linalg.length(at.xy - c.feet.xy) > reach {
		c.agent.mover.goal = {active = true, point = at, radius = reach, gait = gait(c), cell = worldstate.ref_grid_cell(ws, db, target)}
		return .Running
	}
	c.agent.mover.goal = {}
	if target == formid.PLAYER {
		if ws.talking != 0 || ws.force_greet.speaker != 0 {return .Running}
		ws.force_greet = {actor, 0}
	} else {
		worldstate.queue_story_event(ws, {type = worldstate.STORY_DIALOGUE, ref1 = actor, ref2 = target, location1 = worldstate.ref_location(ws, db, actor)})
	}
	return .Done
}

// Lua_Hook runs a procedure a mod wrote in Lua (script/lua procedures.odin); the app wires it to the VM.
Lua_Hook :: struct {
	user: rawptr,
	run:  proc(user: rawptr, name: string, actor: Form_ID, dt: f32, inputs: []Lua_Input, goal: ^Goal) -> Status,
}

// Lua_Input is a procedure input as Lua gets it: a location is its centre, a target its ref.
Lua_Input :: union {
	bool,
	i32,
	f32,
	Form_ID,
	[3]f32,
}

// lua_procedure runs a procedure the engine does not know: a mod's, found by its PNAM name. Without one it fails.
lua_procedure :: proc(c: ^Proc_Context, name: string) -> Status {
	if c.w.lua.run == nil {return .Failed}
	db := c.cond.db
	tree := gamedb.package_tree(db, c.agent.pack)
	inputs := make([dynamic]Lua_Input, context.temp_allocator)
	for idx, k in tree[c.node].inputs {
		in_, _ := gamedb.package_input(db, c.agent.pack, idx)
		switch v in in_.value {
		case bool:                    append(&inputs, v)
		case i32:                     append(&inputs, v)
		case f32:                     append(&inputs, v)
		case gamedb.Package_Target:   append(&inputs, input_target(c, k))
		case gamedb.Package_Topic:    append(&inputs, v.topic)
		case gamedb.Package_Location:
			p, ok := place_of(c, v)
			append(&inputs, Lua_Input(p.center) if ok else nil)
		case:                         append(&inputs, nil)
		}
	}
	goal: Goal
	status := c.w.lua.run(c.w.lua.user, name, c.cond.subject, c.dt, inputs[:], &goal)
	c.agent.mover.goal = goal
	return status
}
