package magicphys

// Magic physicality: the body a spell takes in the world once cast, how it moves while it lives,
// and whom it reaches. This is a seam (ws.md Workstream M): the host hands in the casts since the
// last tick and the live bodies; the model moves them, asks the host what a segment strikes, and
// answers through the host procs, applied after tick returns. A plugin replaces Table.tick.

import "../magic"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_magicphys"
VERSION :: u32(1)

Body_ID :: distinct u32 // the host's; 0 = none

// Primitive is a spell's shape (user, 2026-09-30). Every vanilla delivery maps to one: Aimed Missile,
// Arrow and Lobber, and Target_Location (an invisible one whose landing places the rune, wall or
// summon), to Projectile; Aimed Beam and Target_Actor to Beam; Aimed Flame and Cone to Spray; Self
// with an area, and an explosion where a beam or projectile lands, to Aura. Self without an area and
// Contact (a weapon or unarmed hit carries it) have none.
Primitive :: enum u8 {
	None, // lands on the target at once
	Beam, // a segment to the first thing it strikes, at once
	Spray, // a cone from the caster whose front travels out to its range
	Projectile, // a sphere flying from the caster
	Aura, // a sphere around the caster, or around where a beam or projectile landed
}

Shape :: struct {
	kind:    Primitive,
	range:   f32, // units: a beam's or spray's length, how far a projectile flies
	speed:   f32, // units/s: a projectile's, or a spray's front; 0 = at once
	gravity: f32, // a projectile's; 1 = world gravity (a lobber)
	radius:  f32, // a beam's or projectile's thickness, an aura's size
	spread:  f32, // a spray's half angle, radians
	burst:   f32, // the radius of the aura where a beam or projectile lands; 0 = none
	lasts:   f32, // seconds a spray or aura stays; 0 = one tick
	held:    bool, // it lives while the caster holds the cast (concentration)
	follow:  bool, // it moves with the caster's anchor
}

// Def is a spell's shape as content wrote it.
Def :: struct {
	shape:  Shape,
	anchor: cstring, // where on the caster it leaves ("chest", "hand.right")
}

// Cast is a spell leaving its caster.
Cast :: struct {
	spell, caster, target: Form_ID, // target: what the caster aims at; 0 = nothing
	from, aim:             [3]f32, // where it leaves the caster, and the unit direction it leaves in
}

Body :: struct {
	id:            Body_ID,
	spell, caster: Form_ID,
	shape:         Shape,
	pos, dir, vel: [3]f32,
	reach:         f32, // how far a spray's front has come
	age:           f32, // seconds since it was made
}

Anchor :: struct {
	pos, dir: [3]f32,
}

// Strike is what a segment meets first.
Strike :: struct {
	hit:   bool,
	other: Form_ID, // 0 = the static world
	pos:   [3]f32,
}

// Host is what the engine answers and takes; each proc gets `data` back.
Host :: struct {
	world:  ^plugin.World, // a pointer, so World grows without moving this Host's fields
	data:   rawptr,
	def:    proc "c" (data: rawptr, spell: Form_ID) -> Def,
	anchor: proc "c" (data: rawptr, actor: Form_ID, name: cstring) -> Anchor,
	strike: proc "c" (data: rawptr, from, to: [3]f32, radius: f32, skip: Form_ID) -> Strike,
	spawn:  proc "c" (data: rawptr, b: Body) -> Body_ID, // b.id is ignored
	put:    proc "c" (data: rawptr, b: Body), // the body's next state
	remove: proc "c" (data: rawptr, id: Body_ID),
	hit:    proc "c" (data: rawptr, h: magic.Hit), // lands the spell on h.target
}

Input :: struct {
	host:   Host,
	table:  ^Table,
	dt:     f32,
	actors: plugin.Span(plugin.Actor), // the loaded actors: sprays and auras test them
	casts:  plugin.Span(Cast),
	bodies: plugin.Span(Body), // as of the last tick
}

Table :: struct {
	tick: proc "c" (inp: ^Input),
}

BUILTIN :: Table{tick_builtin}

// (hole spell-shapes :tags (magic combat) :sev gap :needs (shape-defs)) the built-in has no primitives: every cast lands on its target at once. Wanted: Beam strikes along its range at once, Projectile flies by speed and gravity and strikes along each tick's step, Spray's front moves out and hits the actors inside its cone, Aura hits the actors inside its sphere; a burst leaves an Aura where a beam or projectile lands; a held shape lives while the cast is held. `hits = "direct"` entries go only to the actor struck (62 of 227 area spells mix areas); an area needs line of sight (strike).
tick_builtin :: proc "c" (inp: ^Input) {
	h := inp.host
	for c in plugin.items(inp.casts) {
		if c.target != 0 {h.hit(h.data, {c.spell, c.caster, c.target, true})}
	}
}
