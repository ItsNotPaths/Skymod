package combat

// The combat brain: for each loaded actor, whether it warns, fights or flees, and whom; the AI's
// mover carries it out. This is a seam (ws.md Workstream H): the host hands in the actor snapshot
// and each fighter's last fight, answers the queries, and keeps each fight `set` reports. A plugin
// replaces Table.tick, and Table.damage (damage.odin).

import "core:math"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_combat"
VERSION :: u32(3)

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
	swing:  f32, // seconds until it may swing again
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
	world: ^plugin.World, // a pointer, so World grows without moving this Host's fields
	data:  rawptr,
	aggro: proc "c" (data: rawptr, actor: Form_ID) -> Aggro,
	set:   proc "c" (data: rawptr, actor: Form_ID, f: Fight), // applied after tick returns
	swing: proc "c" (data: rawptr, actor: Form_ID, kind: Attack_Kind), // swings its weapon; the host lands it on what is in reach
}

Input :: struct {
	host:     Host,
	table:    ^Table,
	dt:       f32,
	actors:   plugin.Span(plugin.Actor), // the loaded actors, the player's too
	fighters: plugin.Span(Fighter), // the loaded actors the AI drives
}

Table :: struct {
	tick:   proc "c" (inp: ^Input),
	damage: proc "c" (w: ^plugin.World, a: Attack, base: f32) -> f32,
}

BUILTIN :: Table{tick_builtin, damage_builtin}

COMBAT_LEAVE :: f32(1.5) // combat ends when the target is lost and past this times the aggro radius (guess)
// (hole disengage-distance :tags (ai combat) :sev polish) unsourced: how far a fighter chases a target it still detects; DISENGAGE is a guess (no GMST names one).
DISENGAGE :: f32(4096) // combat ends past this, detected or not (guess)
SWING_EVERY :: f32(1.5) // seconds between a stand-in fighter's swings (guess)
FAR :: f32(1e9) // the distance to an actor not loaded

// (hole hit-model :tags (combat unclaimed) :sev gap ) the built-in hit is flat weapon damage in reach: no swing arc, block, power attack, stagger or sneak multiplier.
// (hole combat-brain :tags (ai combat unclaimed) :sev gap :needs (actor-states)) the brain is a stand-in: close, swing in reach, flee on low confidence, and it can only answer a State and a target. Wanted: real tactics (block, dodge, ranged, spells, groups) from someone who knows combat AI; its actions (a swing, a block, a mod's dodge roll) are actor states it asks the actor-state model for, a new Fight field under a new VERSION.
tick_builtin :: proc "c" (inp: ^Input) {
	for f in plugin.items(inp.fighters) {
		c := next(inp, f)
		if c.state == .Combat {swing(inp, f.actor, &c)}
		inp.host.set(inp.host.data, f.actor, c)
	}
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
	c.swing = max(c.swing - inp.dt, 0)
	if f.struck_by != 0 {
		if by, ok := find(actors, f.struck_by); !ok || !by.dead {return {engage(h, f.actor), f.struck_by, 0, c.swing}}
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
		seen := detected(h, me.id, other.id)
		d := distance_xy(me, other)
		if !seen && d > reach || d > DISENGAGE || other.dead || h.world.relation(h.world.data, me.id, other.id) >= .Ally {continue}
		if seen && d < attack_d && attacks_on_sight(h, me.id, other.id) {attack, attack_d = other.id, d}
		if d < near_d {near, near_d = other.id, d}
	}
	if attack != 0 {return {engage(h, me.id), attack, 0, c.swing}}
	if !aggro.on || near == 0 || near_d > reach {return {}}
	if near != c.target {c.target, c.warned = near, 0}
	if near_d <= aggro.warn_attack {c.warned += inp.dt} else {c.warned = 0}
	c.state = .Warn
	if near_d <= aggro.attack || c.warned >= h.world.setting(h.world.data, "fWarningTimer", 5) {c.state = engage(h, me.id)}
	return c
}

// swing: a fighter whose target is inside fCombatDistance swings once its last swing is past.
@(private = "file")
swing :: proc "contextless" (inp: ^Input, actor: Form_ID, c: ^Fight) {
	h := inp.host
	me, _ := find(plugin.items(inp.actors), actor)
	target, ok := find(plugin.items(inp.actors), c.target)
	if !ok || c.swing > 0 || distance_xy(me, target) > h.world.setting(h.world.data, "fCombatDistance", 141) {return}
	h.swing(h.data, actor, {})
	c.swing = SWING_EVERY
}

// engage is Combat, or Flee for a Cowardly actor.
@(private = "file")
engage :: proc "contextless" (h: Host, actor: Form_ID) -> State {
	return .Flee if h.world.actor_value(h.world.data, actor, "Confidence", .Value) == 0 else .Combat
}

// keeps: a fight goes on while the target lives, is loaded and within DISENGAGE, and is detected or
// near; a flight while it is near.
@(private = "file")
keeps :: proc "contextless" (inp: ^Input, me: plugin.Actor, c: Fight, aggro: Aggro) -> bool {
	h := inp.host
	target, loaded := find(plugin.items(inp.actors), c.target)
	if c.target == 0 || loaded && target.dead {return false}
	d := distance_xy(me, target) if loaded else FAR
	if c.state == .Flee {return d <= flee_distance(h, me)}
	if d > DISENGAGE {return false}
	return detected(h, me.id, c.target) || d <= max(aggro.warn_attack, aggro.attack) * COMBAT_LEAVE
}

// attacks_on_sight: Aggressive attacks the hostile actors it has detected, Very Aggressive
// neutrals too, Frenzied anyone.
@(private = "file")
attacks_on_sight :: proc "contextless" (h: Host, actor, other: Form_ID) -> bool {
	aggression := h.world.actor_value(h.world.data, actor, "Aggression", .Value)
	return aggression >= 2 || aggression >= 1 && h.world.hostile(h.world.data, actor, other)
}

@(private = "file")
flee_distance :: proc "contextless" (h: Host, me: plugin.Actor) -> f32 {
	if me.interior {return h.world.setting(h.world.data, "fFleeDistanceInterior", 3000)}
	return h.world.setting(h.world.data, "fFleeDistanceExterior", 5000)
}

@(private = "file")
detected :: proc "contextless" (h: Host, viewer, target: Form_ID) -> bool {
	return h.world.awareness(h.world.data, viewer, target).detected
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
