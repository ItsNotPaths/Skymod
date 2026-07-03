package main

// Jolt smoke test (ROADMAP §2e / physics M1). Run `--phystest`: drop a dynamic sphere
// onto a static floor and log it settling. Pure console — no window, no game assets —
// so it proves the whole physics toolchain end-to-end: the vendored joltc + Jolt static
// libs, the static link, and the FFI through src/physics. Throwaway harness.

import "core:log"

import "../physics"

when DEVTOOLS {
	run_phys_test :: proc() {
		if !physics.init() {
			log.error("--phystest: Jolt init failed")
			return
		}
		defer physics.shutdown()

		w, ok := physics.world_create()
		if !ok {
			log.error("--phystest: world_create failed")
			return
		}
		defer physics.world_destroy(&w)

		// Z-UP (Skyrim convention, matching physics.GRAVITY). Floor: a static box, top face at
		// z = 0 (centre z=-1, half-height-Z 1).
		physics.add_box(&w, {100, 100, 1}, {0, 0, -1}, is_dynamic = false)
		// Sphere: r=0.5, dropped from z=5 — should rest with its centre at z≈0.5.
		ball := physics.add_sphere(&w, 0.5, {0, 0, 5}, is_dynamic = true)
		physics.set_velocity(&w, ball, {0, 0, -2})
		physics.optimize_broadphase(&w)

		// Second floor: a TRIMESH (exercises MeshShape cooking + triangle collision — the path
		// real bhk* static collision uses). A 200×200 quad in the XY plane at z=0.
		mverts := [][3]f32{{-100, -100, 0}, {100, -100, 0}, {100, 100, 0}, {-100, 100, 0}}
		midx := []u32{0, 1, 2, 0, 2, 3}
		physics.add_static_mesh(&w, mverts, midx)
		ball2 := physics.add_sphere(&w, 0.5, {30, 30, 5}, is_dynamic = true)
		physics.set_velocity(&w, ball2, {0, 0, -2})
		physics.optimize_broadphase(&w)

		// Step a while, then check each sphere settled at z≈0.5 (resting on its floor). We test
		// POSITION (not sleep): at Skyrim-scale gravity a resting body keeps a micro-velocity
		// above Jolt's default sleep threshold, so it never deactivates — fine for static collision.
		log.info("--phystest: dropping spheres onto a box floor + a trimesh floor (Jolt, Z-up)…")
		dt: f32 = 1.0 / 60.0
		for _ in 1 ..= 180 {physics.step(&w, dt)}
		pb := physics.body_position(&w, ball)
		pm := physics.body_position(&w, ball2)
		ok_box := pb.z > 0.4 && pb.z < 0.6
		ok_mesh := pm.z > 0.4 && pm.z < 0.6
		log.infof("--phystest: box-floor sphere z=%.3f (%s), trimesh-floor sphere z=%.3f (%s)",
			pb.z, "OK" if ok_box else "BAD", pm.z, "OK" if ok_mesh else "BAD")
		if ok_box && ok_mesh {
			log.info("--phystest: both rest at ~0.5 — Jolt chain + MeshShape collision OK.")
		} else {
			log.warn("--phystest: a sphere did not rest at the expected height")
		}
	}
} // when DEVTOOLS
