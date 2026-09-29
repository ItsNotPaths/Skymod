package main

// Single-area physics test scene (ROADMAP §2e). Run `--celltest`: loads a small grid of
// Tamriel cells around Riverwood (object + terrain collision) into a STATIC scene — no
// streaming, no LOD, no shadows — so it's cheap on the GPU and isolates physics for
// debugging. Free-fly; press G to drop balls and watch them land on terrain / buildings /
// rocks. Tune the window with the `celltest_radius` setting (cells each side; default 1 = 3×3).
// Throwaway harness.

import "core:log"
import "core:math"

import "../collisions"
import "../gamedb"
import smath "../math"
import "../physics"
import "../platform"
import "../render"
import "../settings"
import "../tools"
import "../vfs"
import "../world"

when DEVTOOLS {
	// Drop is one spawned test body + which mesh to draw it with.
	@(private = "file")
	Drop :: struct {
		body: physics.Body,
		cube: bool,
	}

	CELLTEST_GX :: 5 // Riverwood, Tamriel grid
	CELLTEST_GY :: -11

	// Player capsule + locomotion constants (PLAYER_RADIUS, RUN_SPEED, …) live in game.odin.

	run_cell_test :: proc(cfg: ^settings.Config) {
		d: Dev_Boot
		defer dev_shutdown(&d)
		if !dev_boot(&d, "SkyMod — cell physics test", cfg, "--celltest") {
			return
		}
		p, r, v := &d.p, &d.r, &d.v

		db, db_ok := load_gamedb(resolve_source(cfg))
		if !db_ok {
			log.error("--celltest: could not load Skyrim.esm")
			return
		}
		defer gamedb.destroy(&db)

		phys, phys_ok := physics.world_create()
		if !phys_ok {
			log.error("--celltest: physics init failed")
			return
		}
		defer {
			physics.world_destroy(&phys)
			physics.shutdown()
		}

		store: collisions.Store
		defer collisions.destroy(&store)
		space: world.Space
		world.space_init(&space, &phys, &store, nil, dynamic_clutter = false)
		defer world.space_destroy(&space)
		scene := world.scene_init(r, v, &store)
		defer world.scene_destroy(&scene) // LIFO: runs before space and phys destroy → removes bodies while world lives

		wfid, wok := gamedb.find_world(&db, "Tamriel")
		if !wok {
			log.error("--celltest: Tamriel worldspace not found")
			return
		}
		// CDLOD terrain field: sets up the ground texture array + index that the per-cell near-
		// terrain draw samples (without it, loaded terrain renders invisibly). Also the backdrop.
		world.build_terrain_field(&scene, &db, wfid)

		// Load the grid window of cells (object meshes + per-cell terrain), then build all
		// collision up front (this is a static scene — no streaming budget needed).
		radius := i32(settings.get_int(cfg, "celltest_radius", 1))
		cells := 0
		for gy in -radius ..= radius {
			for gx in -radius ..= radius {
				cid, cok := gamedb.cell_at(&db, wfid, CELLTEST_GX + gx, CELLTEST_GY + gy)
				if cok {
					world.load_cell(&scene, &space, &db, cid)
					cells += 1
				}
			}
		}
		built := 0 // terrain collision is built by load_cell; objects below via sync_physics
		for {
			n := world.sync_physics(&space)
			built += n
			if n == 0 {
				break
			}
		}
		physics.optimize_broadphase(&phys)

		cam := Camera{yaw = 2.3, pitch = -0.3}
		if sp, sok := world.spawn(&scene); sok {
			cam.pos = sp
		} else {
			cam.pos = {f32(CELLTEST_GX) * 4096, f32(CELLTEST_GY) * 4096, 4000}
		}

		// Player character (Jolt CharacterVirtual capsule): ~128u tall, eye ~116u. Spawns at the
		// camera and falls to the ground; WASD walks at Skyrim-ish run speed (Shift = sprint).
		character, char_ok := physics.character_create(&phys, cam.pos, PLAYER_RADIUS, PLAYER_HALF_H)
		defer if char_ok {physics.character_destroy(&character)}
		noclip := !char_ok // fall back to free-fly if the controller failed

		sphere_mesh := make_sphere_mesh(r, 24)
		defer render.release_mesh(r, sphere_mesh)
		cube_mesh := make_cube_mesh(r, 22)
		defer render.release_mesh(r, cube_mesh)
		drops: [dynamic]Drop
		defer delete(drops)

		show_hitboxes := false
		debug_built := false

		log.infof(
			"--celltest: %d cells, %d instances w/ collision. RMB look, WASD/QE fly, G drop ball, Esc quit.",
			cells,
			built,
		)

		for platform.pump(p) {
			render.ui_new_frame(r)
			grounded := char_ok && physics.character_on_ground(&character)
			btn_sphere, btn_cube := tools.phys_test_panel(&show_hitboxes, &noclip, grounded)
			if show_hitboxes && !debug_built {
				world.build_collision_debug(&scene, &db) // build the hitbox wireframe once, on first toggle
				debug_built = true
			}

			mouse_cap, kb_cap := render.ui_capturing(r)
			move, look := p.input.move, p.input.look
			if kb_cap {move = {}}
			if mouse_cap {look = {}}

			dt := min(p.dt, f32(1.0 / 30.0))
			if noclip || !char_ok {
				camera_update(&cam, move, look, p.input.fast, p.dt)
				if char_ok {physics.character_set_position(&character, cam.pos)} // keep the body under the camera
			} else {
				// Walk mode: mouse looks; WASD drives the capsule along the ground at run/sprint
				// speed; Space jumps. Camera rides at eye height above the character's feet.
				cam.yaw -= look.x * LOOK_SENSITIVITY
				cam.pitch = clamp(cam.pitch - look.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
				cy, sy := math.cos(cam.yaw), math.sin(cam.yaw)
				dir := [2]f32{cy * move.x + sy * move.y, sy * move.x - cy * move.y}
				mag := math.sqrt(dir.x * dir.x + dir.y * dir.y)
				speed := SPRINT_SPEED if p.input.fast else RUN_SPEED
				hv: [2]f32
				if mag > 0.001 {hv = {dir.x / mag * speed, dir.y / mag * speed}}
				physics.character_move(&phys, &character, hv, move.z > 0.5, dt)
				cam.pos = physics.character_position(&character) + {0, 0, EYE_HEIGHT}
			}

			// Spawn test bodies at the camera: a sphere (G or button) or a cube (button).
			if btn_sphere || (p.input.drop && !kb_cap) {
				if b := physics.add_sphere(&phys, 24, cam.pos, is_dynamic = true); b != 0 {
					append(&drops, Drop{body = b, cube = false})
				}
			}
			if btn_cube {
				if b := physics.add_box(&phys, {22, 22, 22}, cam.pos, is_dynamic = true); b != 0 {
					append(&drops, Drop{body = b, cube = true})
				}
			}
			physics.step(&phys, dt)
			world.update_terrain_field(&scene, cam.pos)

			if render.begin_frame(r, {0.45, 0.55, 0.72, 1.0}) {
				vp := camera_view_proj(cam, render.aspect(r))
				world.cull_begin(&scene) // flat per-frame chunk list for the draw passes (Fix A)
				world.draw_terrain_field(&scene, r, vp, cam.pos) // CDLOD ground (under the near patches)
				world.draw(&scene, r, vp)
				for d in drops {
					m := physics.body_transform(&phys, d.body) // pos + orientation (tumbling cubes)
					render.draw_mesh(r, cube_mesh if d.cube else sphere_mesh, vp, m, {})
				}
				if show_hitboxes {
					world.draw_collision_debug(&scene, r, vp) // green wireframe = exactly what Jolt collides against
				}
				render.end_frame(r)
			}
			free_all(context.temp_allocator)
		}
	}

	// make_sphere_mesh builds a UV sphere (Z-up) of the given radius for the drop-test.
	make_sphere_mesh :: proc(r: ^render.Renderer, radius: f32) -> render.Mesh {
		RINGS :: 12
		SECTORS :: 16
		verts := make([dynamic]render.Mesh_Vertex, 0, (RINGS + 1) * (SECTORS + 1), context.temp_allocator)
		for i in 0 ..= RINGS {
			phi := math.PI * f32(i) / f32(RINGS) // polar 0..π
			for j in 0 ..= SECTORS {
				theta := 2 * math.PI * f32(j) / f32(SECTORS)
				n := [3]f32{math.sin(phi) * math.cos(theta), math.sin(phi) * math.sin(theta), math.cos(phi)}
				append(&verts, render.mesh_vertex(n * radius, n, {f32(j) / f32(SECTORS), f32(i) / f32(RINGS)}))
			}
		}
		idx := make([dynamic]u16, 0, RINGS * SECTORS * 6, context.temp_allocator)
		stride := SECTORS + 1
		for i in 0 ..< RINGS {
			for j in 0 ..< SECTORS {
				a := u16(i * stride + j)
				b := u16(i * stride + j + 1)
				c := u16((i + 1) * stride + j)
				d := u16((i + 1) * stride + j + 1)
				append(&idx, a, c, b, b, c, d)
			}
		}
		return render.upload_mesh(r, verts[:], idx[:])
	}

	// make_cube_mesh builds a flat-shaded cube (half-size h) — 24 verts, per-face normals so it
	// reads crisply as it tumbles.
	make_cube_mesh :: proc(r: ^render.Renderer, h: f32) -> render.Mesh {
		Face :: struct {
			n: [3]f32,
			c: [4][3]f32,
		}
		faces := [6]Face {
			{{0, 0, -1}, {{-h, -h, -h}, {h, -h, -h}, {h, h, -h}, {-h, h, -h}}},
			{{0, 0, 1}, {{-h, -h, h}, {-h, h, h}, {h, h, h}, {h, -h, h}}},
			{{0, -1, 0}, {{-h, -h, -h}, {-h, -h, h}, {h, -h, h}, {h, -h, -h}}},
			{{0, 1, 0}, {{-h, h, -h}, {h, h, -h}, {h, h, h}, {-h, h, h}}},
			{{-1, 0, 0}, {{-h, -h, -h}, {-h, h, -h}, {-h, h, h}, {-h, -h, h}}},
			{{1, 0, 0}, {{h, -h, -h}, {h, -h, h}, {h, h, h}, {h, h, -h}}},
		}
		verts := make([dynamic]render.Mesh_Vertex, 0, 24, context.temp_allocator)
		idx := make([dynamic]u16, 0, 36, context.temp_allocator)
		for f in faces {
			base := u16(len(verts))
			for c in f.c {
				append(&verts, render.mesh_vertex(c, f.n, {0, 0}))
			}
			append(&idx, base, base + 1, base + 2, base, base + 2, base + 3)
		}
		return render.upload_mesh(r, verts[:], idx[:])
	}
} // when DEVTOOLS
