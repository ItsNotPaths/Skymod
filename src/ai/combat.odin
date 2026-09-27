package ai

// Combat state toward the player: when an actor warns, attacks or flees, and where it moves. No
// attacks land yet.

// (hole combat-brain :tags (ai combat unclaimed) :sev gap :needs (combat-damage)) the brain is a stand-in: close, swing in reach, flee on low confidence. Wanted: real tactics (block, dodge, ranged, spells, groups) behind the same seam, from someone who knows combat AI.

import "core:math/linalg"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

Combat_State :: enum u8 {
	None,
	Warn, // inside its warn radius: holds
	Combat, // closes on the player
	Flee, // runs from the player
}

Combat :: struct {
	state:  Combat_State,
	warned: f32, // seconds inside the warn/attack radius
}

// (hole detection-store :tags (ai combat) :sev gap :needs (sight-modes)) an aggressive actor attacks anyone within DETECT_RADIUS, through walls. Wanted: a saved awareness 0..1 per viewer and target, with gained/lost events, read by combat start, GetDetected, IsDetectedBy, OnGainLOS, the stealth meter and the sneak attack bonus. Our model is a stub (Cone above 0 in range = aware at once); sneak-detection replaces it.
DETECT_RADIUS :: f32(2048)
COMBAT_LEAVE :: f32(1.5) // combat ends past this times the radius that started it (guess)
FLEE_STEP :: f32(512) // how far each flee leg runs

combat_state :: proc(w: ^World, actor: Form_ID) -> Combat_State {
	a, ok := w.agents[actor]
	return a.combat.state if ok else .None
}

// next_combat is the actor's combat state this tick, from its distance to the player, its
// aggression and confidence, its aggro radii and its factions' reaction to the player.
@(private)
next_combat :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, feet: [3]f32, c: ^Combat, dt: f32) -> Combat_State {
	if worldstate.is_dead(ws, actor) || worldstate.faction_relation(ws, db, actor, formid.PLAYER) >= .Ally {return .None}
	d := linalg.length(worldstate.ref_pos(ws, db, formid.PLAYER).xy - feet.xy)
	aggro := actor_aggro(ws, db, actor)
	switch c.state {
	case .Flee:
		return .Flee if d <= flee_distance(ws, db, actor) else .None
	case .Combat:
		return .Combat if d <= max(DETECT_RADIUS, aggro.warn_attack, aggro.attack) * COMBAT_LEAVE else .None
	case .None, .Warn:
	}
	if !starts_combat(ws, db, actor, aggro, d, c, dt) {
		return .Warn if aggro.on && d <= max(aggro.warn, aggro.warn_attack) else .None
	}
	return .Flee if worldstate.av_current(ws, db, actor, "Confidence") == 0 else .Combat // Cowardly
}

// starts_combat: Aggressive attacks Enemies on sight, Very Aggressive Neutrals too, Frenzied anyone;
// the aggro radii start it whatever the aggression.
@(private = "file")
starts_combat :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, aggro: esm.Aggro, d: f32, c: ^Combat, dt: f32) -> bool {
	aggression := worldstate.av_current(ws, db, actor, "Aggression")
	enemy := worldstate.faction_relation(ws, db, actor, formid.PLAYER) == .Enemy
	if d <= DETECT_RADIUS && (aggression >= 2 || (aggression >= 1 && enemy)) {return true}
	if !aggro.on {return false}
	if d > aggro.warn_attack {c.warned = 0}
	if d <= aggro.warn_attack {c.warned += dt}
	return d <= aggro.attack || c.warned >= gamedb.setting_float(db, "fWarningTimer", 5)
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

// combat_goal aims the mover for a combat state: at the player, away from it, or nowhere.
@(private)
combat_goal :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: ^Agent, feet: [3]f32) {
	player := worldstate.ref_pos(ws, db, formid.PLAYER)
	switch a.combat.state {
	case .None:
	case .Warn:
		a.mover.goal = {}
	case .Combat:
		a.mover.goal = {active = true, point = player, radius = gamedb.setting_float(db, "fCombatDistance", 141), gait = .Run}
	case .Flee:
		if a.mover.goal.active && !a.mover.arrived && !a.mover.stuck {return}
		away := linalg.normalize0(feet.xy - player.xy)
		a.mover.goal = {active = true, point = feet + {away.x, away.y, 0} * FLEE_STEP, radius = ARRIVED, gait = .Run}
	}
}
