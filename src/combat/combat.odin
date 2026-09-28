package combat

// The combat brain: for each loaded actor, whether it warns, fights or flees, and whom; the AI's
// mover carries it out. This is a seam (ws.md Workstream H): the host hands in the actor snapshot
// and each fighter's last fight, answers the queries, and keeps each fight `set` reports. A plugin
// replaces Table.tick.

import "core:math"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_combat"
VERSION :: u32(1)

State :: enum u8 {
	None,
	Warn, // inside its warn radius: holds
	Combat, // closes on the target
	Flee, // runs from the target
}

// Fight is one actor's combat toward its target.
Fight :: struct {
	state:  State,
	target: Form_ID, // whom it warns, fights or flees
	warned: f32, // seconds the target has spent inside the warn/attack radius
}

Fighter :: struct {
	actor:     Form_ID,
	fight:     Fight, // as of the last tick
	struck_by: Form_ID, // who hit it since the last tick; 0 = nobody
}

// Aggro is the actor's aggro radii (AIDT, through its AI data template).
Aggro :: struct {
	on:                        bool,
	warn, warn_attack, attack: f32,
}

// Host is what the engine answers and takes; each proc gets `data` back.
Host :: struct {
	data:        rawptr,
	detected:    proc "c" (data: rawptr, viewer, target: Form_ID) -> bool,
	ally:        proc "c" (data: rawptr, a, b: Form_ID) -> bool, // ally or friend
	hostile:     proc "c" (data: rawptr, a, b: Form_ID) -> bool,
	actor_value: proc "c" (data: rawptr, actor: Form_ID, name: cstring) -> f32, // current value
	aggro:       proc "c" (data: rawptr, actor: Form_ID) -> Aggro,
	setting:     proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32, // a GMST
	set:         proc "c" (data: rawptr, actor: Form_ID, f: Fight), // applied after tick returns
}

Input :: struct {
	host:     Host,
	table:    ^Table,
	dt:       f32,
	actors:   plugin.Span(plugin.Actor), // the loaded actors, the player's too
	fighters: plugin.Span(Fighter), // the loaded actors the AI drives
}

Table :: struct {
	tick: proc "c" (inp: ^Input),
}

BUILTIN :: Table{tick_builtin}

COMBAT_LEAVE :: f32(1.5) // combat ends when the target is lost and past this times the aggro radius (guess)
FAR :: f32(1e9) // the distance to an actor not loaded

// (hole combat-brain :tags (ai combat unclaimed) :sev gap :needs (combat-damage actor-states)) the brain is a stand-in: close, swing in reach, flee on low confidence, and it can only answer a State and a target. Wanted: real tactics (block, dodge, ranged, spells, groups) from someone who knows combat AI; its actions (a swing, a block, a mod's dodge roll) are actor states it asks the actor-state model for, a new Fight field under a new VERSION.
tick_builtin :: proc "c" (inp: ^Input) {
	for f in plugin.items(inp.fighters) {inp.host.set(inp.host.data, f.actor, next(inp, f))}
}

// next is the fighter's fight this tick. An actor that was hit turns on whoever hit it. Otherwise
// it keeps its fight while the target stays near, else attacks the nearest actor it has detected
// that its aggression lets it attack, else warns or attacks the nearest non-ally inside its aggro
// radii.
// (hole aggro-radius-targets :tags (ai combat) :sev polish) unsourced: whether the aggro radii warn and attack every actor that is not an ally, or only the player; they take every non-ally.
@(private = "file")
next :: proc "contextless" (inp: ^Input, f: Fighter) -> (c: Fight) {
	h := inp.host
	actors := plugin.items(inp.actors)
	me, _ := find(actors, f.actor)
	if me.dead {return {}}
	c = f.fight
	if f.struck_by != 0 {
		if by, ok := find(actors, f.struck_by); !ok || !by.dead {return {engage(h, f.actor), f.struck_by, 0}}
	}
	aggro := h.aggro(h.data, f.actor)
	if c.state == .Combat || c.state == .Flee {
		if keeps(inp, me, c, aggro) {return c}
		c = {}
	}

	attack, near := Form_ID(0), Form_ID(0)
	attack_d, near_d := max(f32), max(f32)
	reach := max(aggro.warn, aggro.warn_attack, aggro.attack) if aggro.on else 0
	for other in actors {
		if other.id == me.id {continue}
		seen := h.detected(h.data, me.id, other.id)
		d := distance_xy(me, other)
		if !seen && d > reach || other.dead || h.ally(h.data, me.id, other.id) {continue}
		if seen && d < attack_d && attacks_on_sight(h, me.id, other.id) {attack, attack_d = other.id, d}
		if d < near_d {near, near_d = other.id, d}
	}
	if attack != 0 {return {engage(h, me.id), attack, 0}}
	if !aggro.on || near == 0 || near_d > reach {return {}}
	if near != c.target {c.target, c.warned = near, 0}
	if near_d <= aggro.warn_attack {c.warned += inp.dt} else {c.warned = 0}
	c.state = .Warn
	if near_d <= aggro.attack || c.warned >= h.setting(h.data, "fWarningTimer", 5) {c.state = engage(h, me.id)}
	return c
}

// engage is Combat, or Flee for a Cowardly actor.
@(private = "file")
engage :: proc "contextless" (h: Host, actor: Form_ID) -> State {
	return .Flee if h.actor_value(h.data, actor, "Confidence") == 0 else .Combat
}

// keeps: a fight goes on while the target lives and is detected or near; a flight while it is near.
@(private = "file")
keeps :: proc "contextless" (inp: ^Input, me: plugin.Actor, c: Fight, aggro: Aggro) -> bool {
	h := inp.host
	target, loaded := find(plugin.items(inp.actors), c.target)
	if c.target == 0 || loaded && target.dead {return false}
	d := distance_xy(me, target) if loaded else FAR
	if c.state == .Flee {return d <= flee_distance(h, me)}
	return h.detected(h.data, me.id, c.target) || d <= max(aggro.warn_attack, aggro.attack) * COMBAT_LEAVE
}

// attacks_on_sight: Aggressive attacks the hostile actors it has detected, Very Aggressive
// neutrals too, Frenzied anyone.
@(private = "file")
attacks_on_sight :: proc "contextless" (h: Host, actor, other: Form_ID) -> bool {
	aggression := h.actor_value(h.data, actor, "Aggression")
	return aggression >= 2 || aggression >= 1 && h.hostile(h.data, actor, other)
}

@(private = "file")
flee_distance :: proc "contextless" (h: Host, me: plugin.Actor) -> f32 {
	if me.interior {return h.setting(h.data, "fFleeDistanceInterior", 3000)}
	return h.setting(h.data, "fFleeDistanceExterior", 5000)
}

@(private = "file")
distance_xy :: proc "contextless" (a, b: plugin.Actor) -> f32 {
	d := a.pos.xy - b.pos.xy
	return math.sqrt(d.x * d.x + d.y * d.y)
}

@(private = "file")
find :: proc "contextless" (actors: []plugin.Actor, id: Form_ID) -> (plugin.Actor, bool) {
	for a in actors {
		if a.id == id {return a, true}
	}
	return {}, false
}
