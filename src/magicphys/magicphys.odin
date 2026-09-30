package magicphys

// Magic physicality: the body a spell takes in the world once cast, how it moves while it lives,
// and whom it reaches. This is a seam (ws.md Workstream M): the host hands in the casts since the
// last tick and the live bodies; the model moves them, asks the host what a segment strikes, and
// answers through the host procs, applied after tick returns. A plugin replaces Table.tick.

import "core:math"
import "../magic"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_magicphys"
VERSION :: u32(1)

Body_ID :: distinct u32 // the host's; 0 = none

// Primitive is a spell's shape. Every vanilla delivery maps to one: Aimed Missile,
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
	place:   bool, // it lands where it strikes, actor or not: a rune, wall or summon (Target_Location)
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
	place:  proc "c" (data: rawptr, spell, caster: Form_ID, pos: [3]f32), // lands it at a point
}

Input :: struct {
	host:    Host,
	table:   ^Table,
	dt:      f32,
	gravity: [3]f32, // the world's, units/s²
	actors:  plugin.Span(plugin.Actor), // the loaded actors: sprays and auras test them
	casts:   plugin.Span(Cast),
	bodies:  plugin.Span(Body), // as of the last tick
}

Table :: struct {
	tick: proc "c" (inp: ^Input),
}

BUILTIN :: Table{tick_builtin}

// tick_builtin launches this tick's casts and moves the live bodies. A beam strikes at once; a
// projectile strikes along each tick's step; a spray's front hits each actor in its cone as it
// passes them; an aura hits the actors inside it. A spray or aura that lasts hits everyone inside
// again each whole second. A beam or projectile that lands leaves an aura of its burst radius, which
// skips the actor it struck.
tick_builtin :: proc "c" (inp: ^Input) {
	h := inp.host
	for c in plugin.items(inp.casts) {
		d := h.def(h.data, c.spell)
		b := Body{spell = c.spell, caster = c.caster, shape = d.shape, pos = c.from, dir = c.aim}
		switch d.shape.kind {
		case .None:
			if c.target != 0 {h.hit(h.data, {c.spell, c.caster, c.target, true})}
		case .Beam, .Projectile:
			if d.shape.kind == .Projectile && d.shape.speed > 0 {
				b.vel = c.aim * d.shape.speed
				step(inp, &b)
			} else if s := h.strike(h.data, c.from, c.from + c.aim * d.shape.range, d.shape.radius, c.caster); s.hit {
				land(inp, b, s)
			}
		case .Spray, .Aura:
			step(inp, &b)
		}
	}
	for b in plugin.items(inp.bodies) {
		b := b
		step(inp, &b)
	}
}

// step moves a body one tick and hits what it reaches; a new body (id 0) spawns if it lives on.
@(private = "file")
step :: proc "contextless" (inp: ^Input, b: ^Body) {
	h := inp.host
	sh := b.shape
	if sh.follow {
		a := h.anchor(h.data, b.caster, "")
		b.pos, b.dir = a.pos, a.dir
	}
	was, age := b.age, b.age + inp.dt
	alive: bool
	switch sh.kind {
	case .None, .Beam:
	case .Projectile:
		to := b.pos + b.vel * inp.dt
		if s := h.strike(h.data, b.pos, to, sh.radius, b.caster); s.hit {
			land(inp, b^, s)
		} else {
			b.pos, b.vel = to, b.vel + inp.gravity * sh.gravity * inp.dt
			alive = sh.speed > 0 && age * sh.speed < sh.range
		}
	case .Spray:
		front := sh.range if sh.speed <= 0 else min(b.reach + sh.speed * inp.dt, sh.range)
		pulse := b.id != 0 && math.floor(age) > math.floor(was)
		for a in plugin.items(inp.actors) {
			d := a.pos - b.pos
			dist := math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
			ahead := dist > 0 && (d.x * b.dir.x + d.y * b.dir.y + d.z * b.dir.z) / dist >= math.cos(sh.spread)
			if a.id == b.caster || !ahead || dist > front || !(pulse || dist >= b.reach || b.id == 0) {continue}
			if sees(inp, b.pos, a.id, b.caster) {h.hit(h.data, {b.spell, b.caster, a.id, false})}
		}
		b.reach = front
		alive = front < sh.range || age < sh.lasts
	case .Aura:
		if b.id == 0 || math.floor(age) > math.floor(was) {burst(inp, b^, sh.radius, 0)}
		alive = age < sh.lasts
	}
	b.age = age
	switch {
	case !alive && b.id != 0: h.remove(h.data, b.id)
	case alive && b.id == 0:  h.spawn(h.data, b^)
	case alive:               h.put(h.data, b^)
	}
}

// land is a beam or projectile striking: a placing shape lands at the point; otherwise the actor
// struck is hit, then its burst goes off there.
@(private = "file")
land :: proc "contextless" (inp: ^Input, b: Body, s: Strike) {
	h := inp.host
	if b.shape.place {
		h.place(h.data, b.spell, b.caster, s.pos)
		return
	}
	struck := s.other if is_actor(inp, s.other) else 0
	if struck != 0 {h.hit(h.data, {b.spell, b.caster, struck, true})}
	if b.shape.burst > 0 {
		at := b
		at.pos = s.pos - b.dir * 16 // off the surface it struck, so the surface does not hide the actors
		burst(inp, at, b.shape.burst, struck)
	}
}

// burst hits every actor but the caster and `skip` within `radius` of the body that it can see.
@(private = "file")
burst :: proc "contextless" (inp: ^Input, b: Body, radius: f32, skip: Form_ID) {
	h := inp.host
	for a in plugin.items(inp.actors) {
		d := a.pos - b.pos
		if a.id == b.caster || a.id == skip || d.x * d.x + d.y * d.y + d.z * d.z > radius * radius {continue}
		if sees(inp, b.pos, a.id, b.caster) {h.hit(h.data, {b.spell, b.caster, a.id, false})}
	}
}

// sees is whether no object stands between `from` and the actor's chest; actors do not block.
@(private = "file")
sees :: proc "contextless" (inp: ^Input, from: [3]f32, actor, caster: Form_ID) -> bool {
	h := inp.host
	s := h.strike(h.data, from, h.anchor(h.data, actor, "").pos, 0, caster)
	return !s.hit || is_actor(inp, s.other)
}

@(private = "file")
is_actor :: proc "contextless" (inp: ^Input, id: Form_ID) -> bool {
	if id == 0 {return false}
	for a in plugin.items(inp.actors) {if a.id == id {return true}}
	return false
}
