package ai

// Procedures that act toward another ref: follow, escort, flee, watch, activate, greet the player,
// and the ones a mod writes in Lua.

import "core:math/linalg"
import "../actorstate"
import "../combat"
import "../formid"
import "../gamedb"
import "../sighthost"
import "../worldstate"

FOLLOW_SPRINT :: f32(300) // fFollowStartSprintDistance: a follower this far behind runs

// (hole follow-sight :tags ai :sev polish) a follower ignores "Need LOS?" and GoToLeadersGoal: it always walks straight at the leader.
// proc_follow keeps within MinRadius of the target until the package ends (Follow) or the actor
// reaches EndLocation (FollowTo, whose slots start one later). A dead target fails it (CK).
proc_follow :: proc(c: ^Proc_Context, shift: int) -> Status {
	ws, db := c.cond.ws, c.cond.db
	target := input_target(c, 0)
	if target == 0 || worldstate.is_dead(ws, db, target) {return .Failed}
	if shift > 0 {
		if end, ok := location(c); ok && reached(c, end) {
			c.agent.mover.goal = {}
			return .Done
		}
	}
	near := max(input_value(c, 1 + shift, f32) or_else 0, ARRIVED)
	far := max(input_value(c, 2 + shift, f32) or_else 0, near)
	follow_goal(ws, db, c.agent, c.cond.subject, target, c.feet, near, far, FOLLOW_SPRINT, c.dt)
	return .Running
}

// follow_goal steers an actor after a leader: it stands within `near` and keeps the leader's pace,
// sneaking while it sneaks; past `far` it jogs, and past `sprint` it runs.
@(private)
follow_goal :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor, leader: Form_ID, feet: [3]f32, near, far, sprint, dt: f32) {
	at := worldstate.ref_pos(ws, db, leader)
	moved := linalg.length(at.xy - a.lead_at.xy) if a.lead_at != {} else 0
	a.lead_at = at
	d := linalg.length(at.xy - feet.xy)
	g := Gait.Run if moved > gait_speed(a.mover.pace, .Walk) * 1.5 * dt else .Walk // the leader runs
	if d > sprint {
		g = .Run
	} else if d > far && g == .Walk {
		g = .Jog
	}
	if actorstate.current(&ws.states, leader) == actorstate.SNEAK {actorstate.request(&ws.states, actor, actorstate.SNEAK)} else {actorstate.leave(&ws.states, actor, actorstate.SNEAK)}
	a.mover.goal = {active = true, point = at, radius = near, gait = g, cell = worldstate.ref_grid_cell(ws, db, leader)}
}

// (hole escort-count :tags ai :sev polish) Escort leads one actor: NumberToEscort and object lists of escorted actors are not read.
// proc_escort leads the escorted actor to the destination, stopping while it lags farther than
// EscortWaitDist; done at the destination. An escorted NPC follows it (escorts_follow).
proc_escort :: proc(c: ^Proc_Context) -> Status {
	ws, db := c.cond.ws, c.cond.db
	who := input_target(c, 0)
	dest, ok := location(c)
	if !ok {return .Failed}
	dest.radius = travel_radius(c, dest)
	if reached(c, dest) {
		delete_key(&c.w.escorts, who)
		c.agent.mover.goal = {}
		return .Done
	}
	if who != 0 && who != ws.player {
		near := max(input_value(c, 4, f32) or_else 0, ARRIVED)
		c.w.escorts[who] = {c.cond.subject, near, max(input_value(c, 5, f32) or_else 0, near), input_value(c, 8, f32) or_else FOLLOW_SPRINT, ws.clock.played}
	}
	if who != 0 && !worldstate.is_dead(ws, db, who) {
		wait := input_value(c, 3, f32) or_else 0
		if wait > 0 && linalg.length(worldstate.ref_pos(ws, db, who).xy - c.feet.xy) > wait {
			c.agent.mover.goal = {}
			return .Running
		}
	}
	c.agent.mover.goal = {active = true, point = dest.center, radius = dest.radius, gait = gait(c), cell = dest.cell}
	return .Running
}

ESCORT_STALE :: 1 // seconds after its escort last asked, an escorted actor goes back to its package

// Escort_Ask is an escort leading an NPC: the NPC follows within the escort's follower radii.
Escort_Ask :: struct {
	leader:            Form_ID,
	near, far, sprint: f32,
	at:                f64, // clock.played when the escort last asked
}

// escorts_follow steers an escorted NPC after its escort, over its own package.
@(private)
escorts_follow :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, actor: Form_ID, feet: [3]f32, dt: f32) {
	e, ok := w.escorts[actor]
	if !ok {return}
	if ws.clock.played - e.at > ESCORT_STALE {
		delete_key(&w.escorts, actor)
		return
	}
	follow_goal(ws, db, a, actor, e.leader, feet, e.near, e.far, e.sprint, dt)
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
	if threat == 0 || worldstate.is_dead(ws, db, threat) {return .Done}
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
	if !wok || !inside(c, target, at, watch) || eok && inside(c, target, at, end) || sighthost.has_los(ws, db, actor, target) {return .Running}
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

// proc_force_greet asks the app for a conversation once the player is inside the node's location
// (ForceGreetLoc; the tree's Travel has walked the actor up already), and is done when it opens.
proc_force_greet :: proc(c: ^Proc_Context) -> Status {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	st := &c.agent.nodes[c.node]
	c.agent.mover.goal = {}
	if st.started {return .Running if ws.force_greet.speaker == actor else .Done}
	if ws.talking != 0 || ws.force_greet.speaker != 0 {return .Running}
	if p, ok := location(c); ok && !inside(c, ws.player, worldstate.ref_pos(ws, db, ws.player), p) {return .Running}
	topic, _ := input_value(c, 0, gamedb.Package_Topic)
	ws.force_greet = {speaker = actor, topic = topic.topic}
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
	if target == 0 || worldstate.is_dead(ws, db, target) {return .Failed}
	at := worldstate.ref_pos(ws, db, target)
	from, _ := input_place(c, 1)
	reach := max(from.radius, ARRIVED)
	if linalg.length(at.xy - c.feet.xy) > reach {
		c.agent.mover.goal = {active = true, point = at, radius = reach, gait = gait(c), cell = worldstate.ref_grid_cell(ws, db, target)}
		return .Running
	}
	c.agent.mover.goal = {}
	if target == ws.player {
		if ws.talking != 0 || ws.force_greet.speaker != 0 {return .Running}
		ws.force_greet = {speaker = actor}
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

// proc_use_weapon attacks its Target (input 2) with what is in the actor's right hand: it closes to
// fCombatDistance and swings, or fires from where it stands with a bow or crossbow, once each Min
// Pause (input 9). Done after End After This Many Barrages (input 11) unless Never End (input 4);
// Do No Damage (input 7) only stands and aims. Barrage sizes are not read: one attack a barrage.
proc_use_weapon :: proc(c: ^Proc_Context) -> Status {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	st := &c.agent.nodes[c.node]
	target := input_target(c, 2)
	if target == 0 || worldstate.is_dead(ws, db, target) {return .Done}
	weapon := worldstate.in_slot(ws, db, actor, .RightHand)
	slot, _ := gamedb.equip_slot_of(db, weapon)
	ranged := slot.weapon_type == combat.BOW || slot.weapon_type == combat.CROSSBOW
	at := worldstate.ref_pos(ws, db, target)
	reach := gamedb.setting_float(db, "fCombatDistance", 141)
	if !ranged && linalg.length(at.xy - c.feet.xy) > reach {
		c.agent.mover.goal = {active = true, point = at, radius = reach, gait = .Run}
		return .Running
	}
	c.agent.mover.goal = {}
	st.timer -= c.dt
	if st.timer > 0 || (input_value(c, 7, bool) or_else false) {return .Running}
	st.timer = max(input_value(c, 9, f32) or_else 0, combat.SWING_EVERY)
	if ranged {
		if ammo := worldstate.in_slot(ws, db, actor, .Ammo); ammo != 0 {worldstate.request_fire(ws, actor, weapon, ammo)}
	} else {
		worldstate.request_swing(ws, actor, {})
	}
	st.child += 1
	if input_value(c, 4, bool) or_else false {return .Running}
	return .Done if st.child >= max(input_value(c, 11, i32) or_else 1, 1) else .Running
}

// proc_use_magic casts its Spell (input 1) at its Target (input 2), again after CooldownTimeMin
// (input 6), NumToCastMax times (input 9; once when unset).
proc_use_magic :: proc(c: ^Proc_Context) -> Status {
	ws, db, actor := c.cond.ws, c.cond.db, c.cond.subject
	st := &c.agent.nodes[c.node]
	spell_in, _ := input_value(c, 1, gamedb.Package_Target) // a spell is an object input
	spell := spell_in.form
	target := input_target(c, 2)
	if spell == 0 {return .Failed}
	st.timer -= c.dt
	if st.timer > 0 {return .Running}
	append(&ws.ai.casts, worldstate.Cast_Order{actor, spell, target if target != 0 else actor})
	st.timer = max(input_value(c, 6, f32) or_else 0, combat.SWING_EVERY)
	st.child += 1
	return .Done if st.child >= max(input_value(c, 9, i32) or_else 1, 1) else .Running
}
