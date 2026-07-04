package main

// Headless terrain-collision check (ROADMAP §2e). `--terraintest`: load the Riverwood cell's
// LAND heightmap, build the SAME terrain collision trimesh the world uses, drop a sphere onto
// it, and log whether it rests on the surface or falls through. No window/GPU — so it runs in
// CI-like environments and isolates the terrain collision path (and exposes the Tamriel-scale
// world-coordinate precision problem if there is one).

import "core:log"

import "../gamedb"
import "../physics"
import "../settings"
import "../vfs"
import "../world"

when DEVTOOLS {
	run_terrain_test :: proc(cfg: ^settings.Config) {
		src := resolve_source(cfg)
		if src == "" {
			log.error("--terraintest: source_game not set")
			return
		}
		v := mount_game(src)
		defer vfs.destroy(&v)
		db, ok := load_gamedb(src)
		if !ok {
			log.error("--terraintest: no Skyrim.esm")
			return
		}
		defer gamedb.destroy(&db)

		phys, pok := physics.world_create()
		if !pok {
			log.error("--terraintest: physics init failed")
			return
		}
		defer {
			physics.world_destroy(&phys)
			physics.shutdown()
		}

		wfid, wok := gamedb.find_world(&db, "Tamriel")
		if !wok {
			log.error("--terraintest: Tamriel not found")
			return
		}
		GX :: 5
		GY :: -11
		cid, cok := gamedb.cell_at(&db, wfid, GX, GY)
		if !cok {
			log.error("--terraintest: Riverwood cell not found")
			return
		}
		heights, hok := gamedb.cell_terrain(&db, cid)
		if !hok {
			log.error("--terraintest: no LAND heights for the cell")
			return
		}

		verts, lo, hi := world.build_terrain_verts(heights, GX, GY)
		defer delete(verts)
		// LOCAL geometry (relative to the cell origin) + a world-space body origin — the
		// double-precision pattern (small single-precision shape, double body position).
		ox := f32(GX) * 4096
		oy := f32(GY) * 4096
		pts := make([][3]f32, len(verts))
		defer delete(pts)
		for vv, i in verts {
			pts[i] = {vv.pos.x - ox, vv.pos.y - oy, vv.pos.z}
		}
		G :: 33
		idx := make([dynamic]u32, 0, 32 * 32 * 6)
		defer delete(idx)
		for y in 0 ..< 32 {
			for x in 0 ..< 32 {
				a := u32(y * G + x)
				b := u32(y * G + x + 1)
				c := u32((y + 1) * G + x)
				d := u32((y + 1) * G + x + 1)
				append(&idx, a, b, c, b, d, c) // winding → upward normals (Jolt MeshShape is single-sided)
			}
		}

		cx := (lo.x + hi.x) * 0.5
		cy := (lo.y + hi.y) * 0.5
		ch := heights[16 * G + 16] * world.HEIGHT_SCALE // centre-vertex height
		floor_z := ch - 40 // put the test floors just below the terrain centre

		// Three static floors at the SAME Tamriel coords, to separate the variables:
		//  A) a box   B) a small 2-tri quad   C) the full terrain trimesh.
		add_box_at := physics.add_box(&phys, {300, 300, 16}, {cx, cy, floor_z}, false)
		qv := [][3]f32{{-300, -300, 0}, {300, -300, 0}, {300, 300, 0}, {-300, 300, 0}}
		qi := []u32{0, 1, 2, 0, 2, 3}
		add_quad := physics.add_static_mesh(&phys, qv, qi, {cx, cy, floor_z}, two_sided = true) // verify two-siding rests cleanly
		terr := physics.add_static_mesh(&phys, pts, idx[:], {ox, oy, 0})
		log.infof("--terraintest: bodies box=%d quad=%d terrain=%d; centre (%.0f,%.0f) floor_z=%.0f", add_box_at, add_quad, terr, cx, cy, floor_z)

		// Drop a sphere onto each (offset in X so they don't interfere).
		b_box := physics.add_sphere(&phys, 24, {cx - 150, cy, floor_z + 300}, is_dynamic = true)
		b_quad := physics.add_sphere(&phys, 24, {cx, cy, floor_z + 300}, is_dynamic = true)
		b_terr := physics.add_sphere(&phys, 24, {cx + 150, cy, hi.z + 300}, is_dynamic = true)
		physics.optimize_broadphase(&phys)

		for _ in 1 ..= 240 {physics.step(&phys, 1.0 / 60.0)}
		zb := physics.body_position(&phys, b_box).z
		zq := physics.body_position(&phys, b_quad).z
		zt := physics.body_position(&phys, b_terr).z
		res :: proc(z, floor: f32) -> string {return "RESTS" if z > floor - 10 && z < floor + 200 else "FELL THROUGH"}
		log.infof("--terraintest @ Tamriel coords (%.0f,%.0f):", cx, cy)
		log.infof("  box floor:   sphere z=%.1f (floor %.0f) -> %s", zb, floor_z, res(zb, floor_z))
		log.infof("  quad trimesh: sphere z=%.1f (floor %.0f) -> %s", zq, floor_z, res(zq, floor_z))
		log.infof("  terrain:     sphere z=%.1f (terrain ~%.0f) -> %s", zt, ch, res(zt, ch - 40))

		// Character controller: spawn above an empty spot of terrain, let it fall + rest, then
		// walk. Feet should rest at the terrain height under that XY (sampled below).
		chx := lo.x + 6 * 128 // a vertex column a few quads in from the SW corner
		chy := lo.y + 16 * 128
		terr_h := heights[16 * G + 6] * world.HEIGHT_SCALE // terrain height at (col 6, row 16)
		ch2, cok2 := physics.character_create(&phys, {chx, chy, terr_h + 250}, 28, 36)
		if !cok2 {
			log.error("--terraintest: character_create failed")
			return
		}
		for _ in 1 ..= 180 {physics.character_move(&phys, &ch2, {0, 0}, false, 1.0 / 60.0)}
		rest := physics.character_position(&ch2)
		grounded := physics.character_on_ground(&ch2)
		start_x := rest.x
		for _ in 1 ..= 120 {physics.character_move(&phys, &ch2, {200, 0}, false, 1.0 / 60.0)} // walk +X at 200 u/s
		walked := physics.character_position(&ch2)
		log.infof("  CHARACTER: feet rest z=%.1f vs terrain %.1f (grounded=%v); walked Δx=%.0f in 2s @200u/s (expect ~400)",
			rest.z, terr_h, grounded, walked.x - start_x)
		physics.character_destroy(&ch2)
	}
} // when DEVTOOLS
