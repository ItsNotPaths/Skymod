package main

// BSLODTriShape LOD test scene (ROADMAP object-LOD tier 1 verification). Run with
// `--lodtest`. Draws one rock (a BSLODTriShape with a real 3-way triangle partition) as
// a 3×3 grid: columns = LOD level 0/1/2 (left→right), rows = the three plausible ways to
// map a level to an index sub-range (SUFFIX / PREFIX / ISOLATED, bottom→top). The user
// reads off which ROW coarsens cleanly across the columns, fixing the convention before
// the full distant-object LOD system is built. Throwaway harness; no streaming/gamedb.

import "core:log"
import "core:math"

import "../assetdb"
import smath "../math"
import "../platform"
import "../render"
import "../settings"
import "../tools"
import "../vfs"

when DEVTOOLS {
	// A rock pile whose mountain-slab shape carries lod_tris ≈ [659, 372, 345].
	LODTEST_ROCK :: "landscape\\rocks\\rockpilel01.nif"

	LODTEST_LIGHT :: smath.Vec3{0.4, 0.6, 1.0}

	// run_lod_test mounts the install's meshes/textures, loads one rock, and shows the LOD
	// grid with a free-fly camera. Reached via `--lodtest`; returns when the window closes.
	run_lod_test :: proc(cfg: ^settings.Config) {
		d: Dev_Boot
		defer dev_shutdown(&d)
		if !dev_boot(&d, "SkyMod — LOD test", cfg, "--lodtest") {
			return
		}
		p, r, v := &d.p, &d.r, &d.v

		cache := assetdb.cache_init(r, v)
		defer assetdb.cache_destroy(&cache)

		model, mok := assetdb.get_model(&cache, LODTEST_ROCK)
		if !mok {
			log.errorf("--lodtest: could not load %s", LODTEST_ROCK)
			return
		}
		// Legend shows the first LOD-bearing shape's partition.
		legend_lt: [3]u32
		for sh in model.shapes {
			if sh.lod_tris != {0, 0, 0} {
				legend_lt = sh.lod_tris
				break
			}
		}

		spacing := max(model.radius * 2.5, f32(200))
		cam := Camera {
			pos   = {0, -spacing * 3.5, 0},
			yaw   = math.PI * 0.5, // look toward +Y at the grid wall (XZ plane)
			pitch = 0,
		}

		log.infof("--lodtest: %s loaded, lod_tris=%v. RMB look, WASD/QE fly, Esc to quit.", LODTEST_ROCK, legend_lt)

		for platform.pump(p) {
			render.ui_new_frame(r)
			tools.lod_test_legend(legend_lt)

			mouse_cap, kb_cap := render.ui_capturing(r)
			move, look := p.input.move, p.input.look
			if kb_cap {move = {}}
			if mouse_cap {look = {}}
			camera_update(&cam, move, look, p.input.fast, p.dt)

			if render.begin_frame(r, {0.10, 0.11, 0.13, 1.0}) {
				vp := camera_view_proj(cam, render.aspect(r))
				// Columns (X) = LOD level; rows (Z) = convention. Grid centred on origin.
				for conv in 0 ..< 3 {
					for level in 0 ..< 3 {
						cell := smath.Vec3{f32(level - 1) * spacing, 0, f32(conv - 1) * spacing}
						base := smath.trs(cell, {0, 0, 0}, 1)
						for sh in model.shapes {
							world := base * sh.local
							if sh.lod_tris == {0, 0, 0} {
								render.draw_mesh(r, sh.mesh, vp, world, sh.tex, sh.alpha_cutoff)
								continue
							}
							first, count := lod_range(sh.lod_tris, level, conv)
							if count == 0 {
								continue // empty partition for this (level, convention)
							}
							render.draw_mesh(r, sh.mesh, vp, world, sh.tex, sh.alpha_cutoff, first, count)
						}
					}
				}
				render.end_frame(r)
			}
			free_all(context.temp_allocator)
		}
	}

	// lod_range maps a BSLODTriShape triangle partition [a,b,c] + a LOD level to an index
	// sub-range (first index, index count — both in INDICES, i.e. triangles·3) under one of
	// three candidate conventions. The test renders all three so the correct one is obvious.
	@(private = "file")
	lod_range :: proc(lt: [3]u32, level, conv: int) -> (first: u32, count: u32) {
		a, b, c := lt[0], lt[1], lt[2]
		total := a + b + c
		off := [3]u32{0, a, a + b} // start of each partition
		switch conv {
		case 0: // SUFFIX: draw from partition `level` to the end (drop the front detail)
			return off[level] * 3, (total - off[level]) * 3
		case 1: // PREFIX: draw the first N triangles, fewer at coarser levels
			cnt := [3]u32{total, a + b, a}
			return 0, cnt[level] * 3
		case 2: // ISOLATED: just partition `level` on its own
			part := [3]u32{a, b, c}
			return off[level] * 3, part[level] * 3
		}
		return 0, 0
	}
} // when DEVTOOLS
