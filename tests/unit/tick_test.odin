package unit_tests

// Fixed-tick render interpolation (docs/short-term-plan.md §E). The sim runs at a constant
// TICK_DT and the frame draws between two ticks, so physics has to hand back a BLENDED pose
// at the alpha the frame sits at — and the exact simulated value when asked for it. These
// pin the endpoints (alpha 0 = where the step started, 1 = where it ended) and the midpoint,
// for a rigid body and for the player capsule. Hermetic: a bare Jolt world, no assets.

import "core:math"
import "core:testing"
import "../../src/physics"

TICK :: f32(1.0 / 60.0)

@(private = "file")
close :: proc(a, b: f32) -> bool {return math.abs(a - b) < 0.01}

// ONE test proc on purpose: Jolt's factory + temp allocator are process globals, so two test
// threads each holding a live world race and crash the runner.
@(test)
test_fixed_tick_interpolation :: proc(t: ^testing.T) {
	body_transform_interpolates(t)
	character_render_position_interpolates(t)
	ray_hits_nearest_first(t)
}

// A ray names each body it crosses by owner, nearest first; a one-sided mesh blocks from behind.
@(private = "file")
ray_hits_nearest_first :: proc(t: ^testing.T) {
	w, ok := physics.world_create()
	testing.expect(t, ok, "world_create")
	defer physics.world_destroy(&w)

	far := physics.add_box(&w, {10, 100, 100}, {200, 0, 0})
	near := physics.add_box(&w, {10, 100, 100}, {100, 0, 0})
	wall := physics.add_static_mesh(&w, {{-50, -100, -100}, {-50, 100, -100}, {-50, 0, 100}}, {0, 1, 2})
	physics.set_owner(&w, far, 2)
	physics.set_owner(&w, near, 1)
	physics.set_owner(&w, wall, 3)
	physics.optimize_broadphase(&w)

	hits := physics.ray_hits(&w, {0, 0, 0}, {300, 0, 0})
	testing.expect_value(t, len(hits), 2)
	if len(hits) == 2 {
		testing.expect_value(t, hits[0].owner, 1)
		testing.expect_value(t, hits[1].owner, 2)
	}
	testing.expect_value(t, len(physics.ray_hits(&w, {0, 0, 0}, {-100, 0, 0})), 1)
	testing.expect_value(t, len(physics.ray_hits(&w, {-100, 0, 0}, {0, 0, 0})), 1)
}

@(private = "file")
body_transform_interpolates :: proc(t: ^testing.T) {
	w, ok := physics.world_create()
	testing.expect(t, ok, "world_create")
	defer physics.world_destroy(&w)

	floor := physics.add_box(&w, {1000, 1000, 10}, {0, 0, -10})
	ball := physics.add_sphere(&w, 10, {0, 0, 500}, is_dynamic = true)
	testing.expect(t, floor != 0 && ball != 0, "bodies created")
	physics.optimize_broadphase(&w)

	from := physics.body_position(&w, ball)
	physics.step(&w, TICK)
	to := physics.body_position(&w, ball)
	testing.expect(t, to.z < from.z, "the ball should have fallen over one tick")

	// step leaves the world at the live pose, whatever it last rendered at.
	testing.expect(t, close(physics.body_transform(&w, ball)[2, 3], to.z), "alpha after step is 1")

	physics.set_render_alpha(&w, 0)
	testing.expectf(
		t, close(physics.body_transform(&w, ball)[2, 3], from.z),
		"alpha 0 should be where the step started (%v), got %v", from.z, physics.body_transform(&w, ball)[2, 3],
	)
	physics.set_render_alpha(&w, 1)
	testing.expect(t, close(physics.body_transform(&w, ball)[2, 3], to.z), "alpha 1 should be the live pose")
	physics.set_render_alpha(&w, 0.5)
	testing.expect(t, close(physics.body_transform(&w, ball)[2, 3], (from.z + to.z) * 0.5), "alpha 0.5 is the midpoint")

	// A static body never moves, so it has no blend endpoint and reads live at any alpha.
	physics.set_render_alpha(&w, 0)
	testing.expect(t, close(physics.body_transform(&w, floor)[2, 3], -10), "static body ignores alpha")

	// body_position is the simulated value — never blended, whatever the render alpha is.
	testing.expect(t, close(physics.body_position(&w, ball).z, to.z), "body_position stays exact")
}

@(private = "file")
character_render_position_interpolates :: proc(t: ^testing.T) {
	w, ok := physics.world_create()
	testing.expect(t, ok, "world_create")
	defer physics.world_destroy(&w)

	physics.add_box(&w, {1000, 1000, 10}, {0, 0, -10})
	physics.optimize_broadphase(&w)

	c, cok := physics.character_create(&w, {0, 0, 0}, 20, 40)
	testing.expect(t, cok, "character_create")
	defer physics.character_destroy(&c)

	from := physics.character_position(&c)
	physics.character_move(&w, &c, {200, 0}, false, TICK)
	to := physics.character_position(&c)
	testing.expect(t, to.x > from.x, "the capsule should have walked +X over one tick")

	testing.expect(t, close(physics.character_render_position(&c, 0).x, from.x), "alpha 0 is the tick's start")
	testing.expect(t, close(physics.character_render_position(&c, 1).x, to.x), "alpha 1 is the live position")
	testing.expect(
		t, close(physics.character_render_position(&c, 0.5).x, (from.x + to.x) * 0.5),
		"alpha 0.5 is the midpoint",
	)

	// A teleport has nothing to blend from: every alpha lands on the destination.
	physics.character_set_position(&c, {700, 0, 0})
	testing.expect(t, close(physics.character_render_position(&c, 0).x, 700), "teleport lands outright")
}

// A capsule fits beside or on top of a box, not inside it (actor spawns avoid clipping furniture).
@(test)
test_capsule_fits :: proc(t: ^testing.T) {
	w, ok := physics.world_create()
	if !testing.expect(t, ok) {return}
	defer physics.world_destroy(&w)
	physics.add_box(&w, {50, 50, 40}, {0, 0, 40}) // a bench: top at z 80
	physics.optimize_broadphase(&w)
	testing.expect(t, !physics.capsule_fits(&w, {0, 0, 0}, 20, 40))
	testing.expect(t, physics.capsule_fits(&w, {0, 0, 80}, 20, 40))
	testing.expect(t, physics.capsule_fits(&w, {200, 0, 0}, 20, 40))
	testing.expect(t, !physics.capsule_fits(&w, {60, 0, 0}, 20, 40)) // clips the side
}
