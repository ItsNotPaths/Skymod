package ai

// The host side of the combat seam (src/combat): each loaded actor's fight, and the mover goal
// that carries it out. No attacks land yet.


import "base:runtime"
import "core:math/linalg"
import "../combat"
import "../formats/esm"
import "../gamedb"
import "../plugin"
import "../worldstate"

FLEE_STEP :: f32(512) // how far each flee leg runs

// fought: some actor fights `target`.
fought :: proc(w: ^World, target: Form_ID) -> bool {
	for _, a in w.agents {
		if a.combat.state == .Combat && a.combat.target == target {return true}
	}
	return false
}

combat_state :: proc(w: ^World, actor: Form_ID) -> combat.State {
	a, ok := w.agents[actor]
	return a.combat.state if ok else .None
}

// set_present is the loaded actors this tick: whom combat and guards
// look at. Every persistent actor has an agent, so the agents are no candidate list.
set_present :: proc(w: ^World, loaded: map[Form_ID]bool) {
	clear(&w.present)
	for a in loaded {append(&w.present, a)}
}

Combat_Host :: struct {
	ctx:  runtime.Context,
	ws:   ^worldstate.World_State,
	db:   ^gamedb.DB,
	sets: [dynamic]combat.Fighter,
}

// tick_combat runs the combat seam for the loaded actors the AI drives, before their packages
// tick. A fight that ends restarts the actor's package.
tick_combat :: proc(w: ^World, ws: ^worldstate.World_State, db: ^gamedb.DB, t: ^combat.Table, actors: []plugin.Actor, dt: f32) {
	fighters := make([dynamic]combat.Fighter, 0, len(actors), context.temp_allocator)
	for a in actors {
		if a.id == ws.player || a.dead {continue}
		by, _ := worldstate.take_struck(ws, a.id)
		append(&fighters, combat.Fighter{a.id, agent_of(w, ws, db, a.id).combat, by})
	}
	h := Combat_Host{context, ws, db, make([dynamic]combat.Fighter, context.temp_allocator)}
	inp := combat.Input {
		host     = {&h, combat_detected, combat_ally, combat_hostile, combat_actor_value, combat_aggro, combat_setting, combat_set},
		table    = t,
		dt       = dt,
		actors   = plugin.span(actors),
		fighters = plugin.span(fighters[:]),
	}
	t.tick(&inp)
	for s in h.sets {
		a := agent_of(w, ws, db, s.actor)
		if a.combat.state != .None && s.fight.state == .None {interrupt(w, s.actor)}
		a.combat = s.fight
	}
}

@(private = "file")
combat_detected :: proc "c" (data: rawptr, viewer, target: Form_ID) -> bool {
	h := (^Combat_Host)(data)
	context = h.ctx
	return worldstate.detected(h.ws, viewer, target)
}

@(private = "file")
combat_ally :: proc "c" (data: rawptr, a, b: Form_ID) -> bool {
	h := (^Combat_Host)(data)
	context = h.ctx
	return worldstate.faction_relation(h.ws, h.db, a, b) >= .Ally
}

@(private = "file")
combat_hostile :: proc "c" (data: rawptr, a, b: Form_ID) -> bool {
	h := (^Combat_Host)(data)
	context = h.ctx
	return worldstate.hostile(h.ws, h.db, a, b)
}

@(private = "file")
combat_actor_value :: proc "c" (data: rawptr, actor: Form_ID, name: cstring) -> f32 {
	h := (^Combat_Host)(data)
	context = h.ctx
	return worldstate.av_current(h.ws, h.db, actor, string(name))
}

// combat_aggro is the actor's aggro radii, through its AI data template.
@(private = "file")
combat_aggro :: proc "c" (data: rawptr, actor: Form_ID) -> combat.Aggro {
	h := (^Combat_Host)(data)
	context = h.ctx
	base := worldstate.record_of(h.ws, actor)
	if r, ok := gamedb.ref_by_formid(h.db, base); ok {base = r.base}
	a := gamedb.template_part(h.db, base, esm.ACBS_TEMPLATE_AI_DATA, worldstate.actor_pick(h.ws, h.db, actor)).aggro
	return {a.on, a.warn, a.warn_attack, a.attack}
}

@(private = "file")
combat_setting :: proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32 {
	h := (^Combat_Host)(data)
	context = h.ctx
	return gamedb.setting_float(h.db, string(name), fallback)
}

@(private = "file")
combat_set :: proc "c" (data: rawptr, actor: Form_ID, f: combat.Fight) {
	h := (^Combat_Host)(data)
	context = h.ctx
	append(&h.sets, combat.Fighter{actor = actor, fight = f})
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
