package unit_tests

// Fixed-tick render interpolation (docs/short-term-plan.md §E). The sim runs at a constant
// TICK_DT and the frame draws between two ticks, so physics hands back each dynamic body's last
// step as poses to blend at the frame's alpha — and the exact simulated value when asked for it.
// These pin the endpoints (alpha 0 = where the step started, 1 = where it ended) and the
// midpoint, for a rigid body and for the player capsule. Hermetic: a bare Jolt world, no assets.

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
	poses_interpolate(t)
	character_step_spans_the_move(t)
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
poses_interpolate :: proc(t: ^testing.T) {
	w, ok := physics.world_create()
	testing.expect(t, ok, "world_create")
	defer physics.world_destroy(&w)
	p: physics.Poses
	defer physics.poses_destroy(&p)

	floor := physics.add_box(&w, {1000, 1000, 10}, {0, 0, -10})
	ball := physics.add_sphere(&w, 10, {0, 0, 500}, is_dynamic = true)
	testing.expect(t, floor != 0 && ball != 0, "bodies created")
	physics.optimize_broadphase(&w)

	from := physics.body_position(&w, ball)
	physics.step(&w, TICK)
	to := physics.body_position(&w, ball)
	testing.expect(t, to.z < from.z, "the ball should have fallen over one tick")
	placed := physics.add_sphere(&w, 10, {100, 0, 500}, is_dynamic = true) // after the step: nothing to blend from
	physics.capture_poses(&w, &p)

	z :: proc(p: ^physics.Poses, b: physics.Body, alpha: f32) -> f32 {
		m, _ := physics.posed(p, b, alpha)
		return m[2, 3]
	}
	testing.expectf(t, close(z(&p, ball, 0), from.z), "alpha 0 should be where the step started (%v), got %v", from.z, z(&p, ball, 0))
	testing.expect(t, close(z(&p, ball, 1), to.z), "alpha 1 should be where it ended")
	testing.expect(t, close(z(&p, ball, 0.5), (from.z + to.z) * 0.5), "alpha 0.5 is the midpoint")
	testing.expect(t, close(z(&p, placed, 0), 500) && close(z(&p, placed, 1), 500), "a body placed after the step does not slide")
	_, has_floor := physics.posed(&p, floor, 0)
	testing.expect(t, !has_floor, "a static body has no pose")

	// body_transform and body_position are the simulated values, whatever is drawn.
	testing.expect(t, close(physics.body_transform(&w, ball)[2, 3], to.z), "body_transform is live")
	testing.expect(t, close(physics.body_position(&w, ball).z, to.z), "body_position stays exact")

	physics.remove_body(&w, ball)
	physics.capture_poses(&w, &p)
	_, has_ball := physics.posed(&p, ball, 0)
	testing.expect(t, !has_ball, "a removed body leaves the poses")
}

@(private = "file")
character_step_spans_the_move :: proc(t: ^testing.T) {
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

	sf, st := physics.character_step(&c)
	testing.expect(t, close(sf.x, from.x), "the step starts where the move started")
	testing.expect(t, close(st.x, to.x), "the step ends at the live position")

	// A teleport has nothing to blend from: the step is the destination alone.
	physics.character_set_position(&c, {700, 0, 0})
	sf, st = physics.character_step(&c)
	testing.expect(t, close(sf.x, 700) && close(st.x, 700), "teleport lands outright")
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
