package ai

import "core:math/linalg"
import "../formid"
import "../gamedb"
import "../worldstate"

// Confront is a guard going after a wanted actor it detected.
Confront :: struct {
	target: Form_ID,
	wait:   f32, // seconds until it confronts anyone again
}

// (hole confront-timing :tags (ai combat) :sev polish) unsourced: how near a guard comes before it speaks and how soon it confronts again; both are guesses.
CONFRONT_REACH :: f32(150) // how near the guard gets before it speaks (guess)
CONFRONT_AGAIN :: f32(30) // seconds before a guard confronts again after asking (guess)

// confront walks a guard to the nearest actor it detects and knows a bounty on, unless it is
// hostile (then combat has it). In reach, the target's controller answers: the player's opens the
// guard's forcegreet (PFGT: DialogueCrimeGuards pays, jails or resists), an NPC's pays if it
// carries the gold, else goes to jail. True while the guard is busy with it.
@(private)
confront :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, guard: Form_ID, feet: [3]f32, dt: f32) -> bool {
	c := &a.confront
	c.wait = max(c.wait - dt, 0)
	if c.wait > 0 || len(ws.wanted) == 0 && len(ws.known_bounties) == 0 {return false}
	if !worldstate.in_faction(ws, db, guard, formid.IS_GUARD_FACTION) {return false}
	if !wanted_by(ws, db, guard, c.target) {
		c.target = 0
		best := max(f32)
		for other in w.present {
			d := linalg.length(worldstate.ref_pos(ws, db, other).xy - feet.xy)
			if d < best && wanted_by(ws, db, guard, other) {c.target, best = other, d}
		}
		if c.target == 0 {return false}
	}
	to := worldstate.ref_pos(ws, db, c.target)
	if linalg.length(to.xy - feet.xy) > CONFRONT_REACH {
		a.mover.goal = {active = true, point = to, radius = CONFRONT_REACH, gait = .Run}
		return true
	}
	a.mover.goal = {}
	worldstate.queue_story_event(ws, {type = worldstate.STORY_ARREST, ref1 = guard, ref2 = c.target, location1 = worldstate.ref_location(ws, db, guard)})
	if c.target == formid.PLAYER {
		if ws.talking != 0 || ws.force_greet.speaker != 0 {return true}
		ws.force_greet = {speaker = guard, subtype = "PFGT"}
	} else {
		settle_bounty(ws, db, guard, c.target)
	}
	c^ = {wait = CONFRONT_AGAIN}
	return true
}

// wanted_by: the guard detects `other`, knows a bounty on it, and is not hostile to it.
@(private = "file")
wanted_by :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, guard, other: Form_ID) -> bool {
	if other == 0 || other == guard || worldstate.is_dead(ws, db, other) || !worldstate.detected(ws, guard, other) {return false}
	if worldstate.jailed_by(ws, other, worldstate.crime_faction(ws, db, guard)) {return false}
	return worldstate.total(worldstate.bounty(ws, db, guard, other)) > 0 && !worldstate.hostile(ws, db, guard, other)
}

// settle_bounty is an NPC's answer to a guard: pay the bounty the guard knows if it carries the
// gold, else jail.
@(private = "file")
settle_bounty :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, guard, actor: Form_ID) {
	faction := worldstate.crime_faction(ws, db, guard)
	owed := worldstate.total(worldstate.bounty(ws, db, guard, actor))
	if worldstate.inv_count(ws, db, actor, formid.GOLD) >= owed {
		worldstate.inv_add(ws, actor, formid.GOLD, -owed)
		worldstate.pay_bounty(ws, actor, faction)
	} else {
		worldstate.send_to_jail(ws, db, actor, faction, guard)
	}
}
