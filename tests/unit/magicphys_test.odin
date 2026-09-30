package unit_tests

import "base:runtime"
import "core:testing"
import "../../src/magic"
import "../../src/magicphys"
import "../../src/plugin"

// A flat world: actors stand on a line along +y; a wall, if any, stands at y = wall.
@(private = "file")
Fake_Phys :: struct {
	ctx:     runtime.Context,
	shape:   magicphys.Shape,
	wall:    f32, // 0 = no wall
	actors:  []plugin.Actor,
	hits:    [dynamic]magic.Hit,
	spawned: [dynamic]magicphys.Body,
	removed: int,
}

CASTER_P, NEAR_P, FAR_P, BEHIND_P :: plugin.Form_ID(0x10), plugin.Form_ID(0x11), plugin.Form_ID(0x12), plugin.Form_ID(0x13)

@(private = "file")
fake_def :: proc "c" (data: rawptr, spell: plugin.Form_ID) -> magicphys.Def {return {(^Fake_Phys)(data).shape, ""}}

@(private = "file")
fake_anchor :: proc "c" (data: rawptr, actor: plugin.Form_ID, name: cstring) -> magicphys.Anchor {
	for a in (^Fake_Phys)(data).actors {if a.id == actor {return {a.pos, {0, 1, 0}}}}
	return {}
}

// fake_strike meets the first actor within 20 of the segment, else the wall.
@(private = "file")
fake_strike :: proc "c" (data: rawptr, from, to: [3]f32, radius: f32, skip: plugin.Form_ID) -> magicphys.Strike {
	f := (^Fake_Phys)(data)
	lo, hi := min(from.y, to.y), max(from.y, to.y)
	best := magicphys.Strike{}
	best_y := hi + 1
	for a in f.actors {
		if a.id != skip && a.pos.y >= lo && a.pos.y <= hi && abs(a.pos.x - from.x) < 20 && abs(a.pos.y - from.y) < abs(best_y - from.y) {
			best, best_y = {true, a.id, a.pos}, a.pos.y
		}
	}
	if f.wall != 0 && f.wall >= lo && f.wall <= hi && abs(f.wall - from.y) < abs(best_y - from.y) {
		best = {true, 0, {from.x, f.wall, from.z}}
	}
	return best
}

@(private = "file")
fake_spawn :: proc "c" (data: rawptr, b: magicphys.Body) -> magicphys.Body_ID {
	f := (^Fake_Phys)(data)
	context = f.ctx
	body := b
	body.id = magicphys.Body_ID(len(f.spawned) + 1)
	append(&f.spawned, body)
	return body.id
}

@(private = "file")
fake_put :: proc "c" (data: rawptr, b: magicphys.Body) {
	f := (^Fake_Phys)(data)
	for &s in f.spawned {if s.id == b.id {s = b}}
}

@(private = "file")
fake_remove :: proc "c" (data: rawptr, id: magicphys.Body_ID) {
	f := (^Fake_Phys)(data)
	context = f.ctx
	for s, i in f.spawned {if s.id == id {ordered_remove(&f.spawned, i); break}}
	f.removed += 1
}

@(private = "file")
fake_hit :: proc "c" (data: rawptr, h: magic.Hit) {
	f := (^Fake_Phys)(data)
	context = f.ctx
	append(&f.hits, h)
}

// cast_phys casts once with `shape`, then ticks the live bodies `ticks` more times.
@(private = "file")
cast_phys :: proc(f: ^Fake_Phys, shape: magicphys.Shape, ticks := 0) {
	f.ctx, f.shape = context, shape
	f.actors = []plugin.Actor{{id = CASTER_P}, {id = NEAR_P, pos = {0, 300, 0}}, {id = FAR_P, pos = {0, 900, 0}}, {id = BEHIND_P, pos = {0, -300, 0}}}
	f.hits.allocator, f.spawned.allocator = context.temp_allocator, context.temp_allocator
	table := magicphys.BUILTIN
	casts := []magicphys.Cast{{spell = 0x800, caster = CASTER_P, from = {}, aim = {0, 1, 0}}}
	inp := magicphys.Input {
		host    = {nil, f, fake_def, fake_anchor, fake_strike, fake_spawn, fake_put, fake_remove, fake_hit},
		table   = &table,
		dt      = 0.1,
		gravity = {0, 0, -686},
		actors  = plugin.span(f.actors),
		casts   = plugin.span(casts),
	}
	table.tick(&inp)
	inp.casts = {}
	for _ in 0 ..< ticks {
		live := make([]magicphys.Body, len(f.spawned), context.temp_allocator)
		copy(live, f.spawned[:])
		inp.bodies = plugin.span(live)
		table.tick(&inp)
	}
}

@(private = "file")
hit_ids :: proc(f: ^Fake_Phys) -> (ids: [dynamic]plugin.Form_ID) {
	ids.allocator = context.temp_allocator
	for h in f.hits {append(&ids, h.target)}
	return
}

@(test)
test_magicphys_beam :: proc(t: ^testing.T) {
	f: Fake_Phys
	cast_phys(&f, {kind = .Beam, range = 3000, burst = 600})
	ids := hit_ids(&f)
	testing.expect(t, len(ids) == 2 && ids[0] == NEAR_P && f.hits[0].direct, "the beam strikes the nearest actor")
	testing.expect(t, len(ids) == 2 && ids[1] == BEHIND_P && !f.hits[1].direct, "its burst reaches behind it, skipping the caster")
}

@(test)
test_magicphys_projectile :: proc(t: ^testing.T) {
	f: Fake_Phys
	f.wall = 200
	cast_phys(&f, {kind = .Projectile, speed = 1000, range = 5000, burst = 150}, 3)
	testing.expect_value(t, len(f.hits), 0) // the wall stops it, and hides the near actor from its burst
	testing.expect_value(t, f.removed, 1)

	g: Fake_Phys
	cast_phys(&g, {kind = .Projectile, speed = 1000, range = 5000}, 4)
	testing.expect(t, len(g.hits) == 1 && g.hits[0].target == NEAR_P, "it flies until it meets the near actor")
}

@(test)
test_magicphys_spray_aura :: proc(t: ^testing.T) {
	f: Fake_Phys
	cast_phys(&f, {kind = .Spray, range = 1000, speed = 5000, spread = 0.5}, 2)
	ids := hit_ids(&f)
	testing.expect(t, len(ids) == 2 && ids[0] == NEAR_P && ids[1] == FAR_P, "the front reaches near, then far; never behind")

	g: Fake_Phys
	cast_phys(&g, {kind = .Aura, radius = 400, lasts = 1.5}, 16)
	ids = hit_ids(&g)
	testing.expect(t, len(ids) == 4, "near and behind, at once and again a second later")
	testing.expect_value(t, g.removed, 1)
}
