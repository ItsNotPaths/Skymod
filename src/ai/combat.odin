package ai

// Combat state toward a target, any actor: when an actor warns, attacks or flees, and where it
// moves. No attacks land yet.

// (hole combat-brain :tags (ai combat unclaimed) :sev gap :needs (combat-damage)) the brain is a stand-in: close, swing in reach, flee on low confidence. Wanted: real tactics (block, dodge, ranged, spells, groups) behind the same seam, from someone who knows combat AI.

import "core:math/linalg"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

Combat_State :: enum u8 {
	None,
	Warn, // inside its warn radius: holds
	Combat, // closes on the target
	Flee, // runs from the target
}

Combat :: struct {
	state:  Combat_State,
	target: Form_ID, // whom it warns, fights or flees
	warned: f32, // seconds the target has spent inside the warn/attack radius
}

COMBAT_LEAVE :: f32(1.5) // combat ends when the target is lost and past this times the aggro radius (guess)
FLEE_STEP :: f32(512) // how far each flee leg runs

// player_in_combat: some actor fights the player.
player_in_combat :: proc(w: ^World) -> bool {
	for _, a in w.agents {
		if a.combat.state == .Combat && a.combat.target == formid.PLAYER {return true}
	}
	return false
}

combat_state :: proc(w: ^World, actor: Form_ID) -> Combat_State {
	a, ok := w.agents[actor]
	return a.combat.state if ok else .None
}

// next_combat is the actor's combat state this tick. An actor that was hit turns on whoever hit
// it. Otherwise it keeps its fight while the target stays near, else attacks the nearest actor it
// has detected that its aggression lets it attack, else warns or attacks the nearest non-ally
// inside its aggro radii.
// (hole aggro-radius-targets :tags (ai combat) :sev polish) unsourced: whether the aggro radii warn and attack every actor that is not an ally, or only the player; they take every non-ally.
@(private)
next_combat :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, c: ^Combat, dt: f32) -> Combat_State {
	if worldstate.is_dead(ws, actor) {
		c^ = {}
		return .None
	}
	if by, ok := worldstate.take_struck(ws, actor); ok && !worldstate.is_dead(ws, by) {
		c.target, c.warned = by, 0
		return engage(ws, db, actor)
	}
	aggro := actor_aggro(ws, db, actor)
	if c.state == .Combat || c.state == .Flee {
		if keeps(ws, db, actor, feet, c^, aggro) {return c.state}
		c^ = {}
	}

	attack, near := Form_ID(0), Form_ID(0)
	attack_d, near_d := max(f32), max(f32)
	reach := max(aggro.warn, aggro.warn_attack, aggro.attack) if aggro.on else 0
	for other in w.present {
		if other == actor {continue}
		seen := worldstate.detected(ws, actor, other)
		d := linalg.length(worldstate.ref_pos(ws, db, other).xy - feet.xy)
		if !seen && d > reach || worldstate.is_dead(ws, other) || worldstate.faction_relation(ws, db, actor, other) >= .Ally {continue}
		if seen && d < attack_d && attacks_on_sight(ws, db, actor, other) {attack, attack_d = other, d}
		if d < near_d {near, near_d = other, d}
	}
	if attack != 0 {
		c.target, c.warned = attack, 0
		return engage(ws, db, actor)
	}
	if !aggro.on || near == 0 || near_d > max(aggro.warn, aggro.warn_attack, aggro.attack) {
		c^ = {}
		return .None
	}
	if near != c.target {c.target, c.warned = near, 0}
	if near_d <= aggro.warn_attack {c.warned += dt} else {c.warned = 0}
	if near_d <= aggro.attack || c.warned >= gamedb.setting_float(db, "fWarningTimer", 5) {return engage(ws, db, actor)}
	return .Warn
}

// set_present is the loaded actors this tick; with the player they are whom combat and guards
// look at. Every persistent actor has an agent, so the agents are no candidate list.
set_present :: proc(w: ^World, loaded: map[Form_ID]bool) {
	clear(&w.present)
	for a in loaded {append(&w.present, a)}
	if formid.PLAYER not_in loaded {append(&w.present, formid.PLAYER)}
}

// engage is Combat, or Flee for a Cowardly actor.
@(private = "file")
engage :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> Combat_State {
	return .Flee if worldstate.av_current(ws, db, actor, "Confidence") == 0 else .Combat
}

// keeps: a fight goes on while the target lives and is detected or near; a flight while it is near.
@(private = "file")
keeps :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, c: Combat, aggro: esm.Aggro) -> bool {
	if c.target == 0 || worldstate.is_dead(ws, c.target) {return false}
	d := linalg.length(worldstate.ref_pos(ws, db, c.target).xy - feet.xy)
	if c.state == .Flee {return d <= flee_distance(ws, db, actor)}
	return worldstate.detected(ws, actor, c.target) || d <= max(aggro.warn_attack, aggro.attack) * COMBAT_LEAVE
}

// attacks_on_sight: Aggressive attacks the hostile actors it has detected, Very Aggressive
// neutrals too, Frenzied anyone.
@(private = "file")
attacks_on_sight :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor, other: Form_ID) -> bool {
	if !worldstate.detected(ws, actor, other) {return false}
	aggression := worldstate.av_current(ws, db, actor, "Aggression")
	return aggression >= 2 || aggression >= 1 && worldstate.hostile(ws, db, actor, other)
}

// actor_aggro is the actor's aggro radii, through its AI data template.
@(private = "file")
actor_aggro :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> esm.Aggro {
	base := worldstate.record_of(ws, actor)
	if r, ok := gamedb.ref_by_formid(db, base); ok {base = r.base}
	return gamedb.template_part(db, base, esm.ACBS_TEMPLATE_AI_DATA, worldstate.actor_pick(ws, db, actor)).aggro
}

@(private = "file")
flee_distance :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> f32 {
	if c, ok := gamedb.cell_by_formid(db, worldstate.ref_cell(ws, db, actor)); ok && c.interior {
		return gamedb.setting_float(db, "fFleeDistanceInterior", 3000)
	}
	return gamedb.setting_float(db, "fFleeDistanceExterior", 5000)
}

// combat_goal aims the mover for a combat state: at the target, away from it, or nowhere.
@(private)
combat_goal :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, feet: [3]f32) {
	target := worldstate.ref_pos(ws, db, a.combat.target)
	switch a.combat.state {
	case .None:
	case .Warn:
		a.mover.goal = {}
	case .Combat:
		a.mover.goal = {active = true, point = target, radius = gamedb.setting_float(db, "fCombatDistance", 141), gait = .Run}
	case .Flee:
		if a.mover.goal.active && !a.mover.arrived && !a.mover.stuck {return}
		away := linalg.normalize0(feet.xy - target.xy)
		a.mover.goal = {active = true, point = feet + {away.x, away.y, 0} * FLEE_STEP, radius = ARRIVED, gait = .Run}
	}
}
