package world

// CDLOD terrain (terrain pivot). The whole worldspace's terrain is a single height TEXTURE sampled
// in the vertex shader and drawn as ONE reusable grid patch instanced per quadtree node — fine near
// the camera, progressively coarser outward. Ground = a downscaled land-texture array indexed by a
// per-vertex dominant map with a noise blend; the streamed NEAR cells (lod 0) draw the same blended
// ground at full geometry on top. Replaced the old per-cell terrain LOD rings + the Far_Block
// backdrop entirely. Next: vertex geomorph (smooth LOD transitions) — see the terrain memory.
//
// The height data (one float per texel) is assembled once from the resident heightmaps (no IO), so
// it slots into the full-load screen rather than popping in. Gaps (cells with no LAND) are filled
// by neighbour interpolation (real terrain gaps, not covered areas).

import "core:log"

import "../gamedb"
import smath "../math"
import "../render"

// SUB height texels per cell (must divide TERRAIN_QUADS=32). PATCH_GRID quads per patch side: the
// fixed mesh tessellation reused at every quadtree level — a node's world size scales it, so a leaf
// (1 cell) gets PATCH_GRID quads/cell and a coarse node spreads the same grid over many cells.
TERR_SUB :: 8
TERR_PATCH_GRID :: 32

// TERR_DROP sinks the CDLOD field slightly below true height so the full-detail NEAR terrain (drawn
// on top in the lod-0 cells) wins where the two overlap — no z-fight. (Formerly farland's FAR_DROP.)
TERR_DROP :: f32(1024)

// Quadtree LOD: a node is detailed enough (gets emitted as one patch instance) once the camera is
// farther than terr_lod_k × its world size; nearer than that it subdivides into 4. TERR_LEAF_CELLS
// is the finest node. Rebuild the selection only when the camera moves past TERR_REBUILD_STEP.
// terr_lod_k is a VAR (tunable via the terrain_lod_falloff setting): lower = finer distant terrain.
terr_lod_k := f32(2.5)
TERR_LEAF_CELLS :: 1
TERR_REBUILD_STEP :: f32(2048) // half a cell

// CDLOD geomorph: each patch vertex blends toward the next-coarser grid across the tail of its
// active distance band, so terrain slides into resolution instead of popping when the quadtree
// re-selects. Both VARs are tunable (terrain_geomorph_* settings; compiled defaults here):
//   terr_geomorph_falloff = morph start ratio — where in the band (0=band start, 1=the switch) the
//     morph begins. Lower spreads the morph over more distance (gentler); >0.5 keeps it crack-free.
//   terr_geomorph_strength = morph amount [0..1]. 1 = fully crack-free; <1 reintroduces minor pops
//     (a debug/taste knob). 0 disables geomorph entirely (hard LOD snaps, the pre-geomorph look).
//   terr_geomorph_distance = morph-zone distance scale. 1 = morph completes exactly at the LOD
//     switch (crack-free); >1 starts it from farther out (more gradual, slight pop at the switch);
//     <1 finishes it before the switch (snappier).
terr_geomorph_falloff := f32(0.65)
terr_geomorph_strength := f32(1.0)
terr_geomorph_distance := f32(1.0)

// The CDLOD field is sunk TERR_DROP below true height so the full-detail NEAR terrain (lod-0 cells)
// wins where they overlap — but that overlap only exists close to the camera. terr_drop_fade_*
// ramp the sink back to ZERO past the near-terrain edge so DISTANT terrain reads at true height
// (otherwise it sits ~TERR_DROP low, distant water floats above it and the per-cell water squares
// show). The ramp lands UNDER the near terrain, so the bend stays hidden. Derived from full_radius
// in main (the near-terrain reach), not user knobs; defaults cover the no-override case.
terr_drop_fade_start := f32(2 * CELL_SIZE)
terr_drop_fade_band := f32(CELL_SIZE)

// Ground array layer size: every unique land texture is blitted down to this square (mipped, so
// distance picks the right level). Small → tiny memory + uniform array dims; detail is plenty for
// the distances CDLOD covers. TERR_MAX_LAYERS caps the R8 index map's range.
TERR_GROUND_SIZE :: 256 // ground-array layer size; bigger now that NEAR terrain samples it too
TERR_MAX_LAYERS :: 255
TERR_INDEX_SUB :: 8 // index-map texels per cell: the per-VERTEX dominant LTEX (not one per cell), so
// painted-texture boundaries follow the alpha curves (continuous across cells) — no cell squares.

// Terrain_Field is the whole-world CDLOD terrain: the height texture + the reusable patch + the
// quadtree extent + the (per-move-rebuilt) selected-node instance buffer + the world→UV uniforms.
Terrain_Field :: struct {
	height:    render.Texture,
	ground:    render.Texture, // ground diffuse 2D array (one layer per unique land texture)
	index:     render.Texture, // R8 per-cell map: cell → ground array layer
	patch:     render.Mesh,
	inst:      render.Terrain_Instances,
	uni_field: [4]f32, // xy = world origin of the height texture; zw = 1 / world extent
	uni_texel: [4]f32, // xy = 1 / texture dims; z = world units per texel; w = height drop
	root_gx:   i32, // quadtree root corner (cells) + side (power-of-two cells covering the bbox)
	root_gy:   i32,
	root_side: i32,
	bb_min_gx: i32, // worldspace cell bbox — nodes fully outside it are all-holes, skipped
	bb_min_gy: i32,
	bb_max_gx: i32,
	bb_max_gy: i32,
	have_sel:  bool, // an instance set has been selected at least once
	last_cx:   f32, // camera XY at the last selection (rebuild gate)
	last_cy:   f32,
	built:     bool,
}

// build_terrain_field assembles the worldspace heightfield into an R32F texture, builds the unit
// patch, and lays out one instance per TERR_PATCH_CELLS block over the worldspace bbox. MAIN
// THREAD (GPU uploads); reads only resident heightmaps. Call after the worldspace is known.
build_terrain_field :: proc(s: ^Scene, db: ^gamedb.DB, world_fid: Form_ID) {
	r := s.cache.r

	// Fresh per-base tree-billboard cache for this worldspace (release_terrain_field freed the prior).
	s.tree_billboards = make(map[Form_ID]string)

	cells := gamedb.cells_of(db, world_fid)
	if len(cells) == 0 {
		return
	}
	min_gx, min_gy := max(i32), max(i32)
	max_gx, max_gy := min(i32), min(i32)
	for cid in cells {
		if c, ok := gamedb.cell_by_formid(db, cid); ok && c.has_grid {
			min_gx, min_gy = min(min_gx, c.gx), min(min_gy, c.gy)
			max_gx, max_gy = max(max_gx, c.gx), max(max_gy, c.gy)
		}
	}
	if max_gx < min_gx {
		return
	}

	cols := int(max_gx - min_gx + 1)
	rows := int(max_gy - min_gy + 1)
	W := cols * TERR_SUB + 1
	H := rows * TERR_SUB + 1
	step := TERRAIN_QUADS / TERR_SUB // grid samples per height texel (32/SUB)

	heights := make([]f32, W * H, context.temp_allocator)
	hreal := make([]bool, W * H, context.temp_allocator) // which texels came from a real LAND cell
	// Fill each cell's [0..SUB]² texel block (inclusive: the far edge is shared with the next cell
	// and overwritten with the identical value, so blocks tile seamlessly).
	for cid in cells {
		c, ok := gamedb.cell_by_formid(db, cid)
		if !ok || !c.has_grid {
			continue
		}
		hgt, hok := gamedb.cell_terrain(db, cid)
		if !hok || len(hgt) < TERRAIN_GRID * TERRAIN_GRID {
			continue
		}
		ox := int(c.gx - min_gx) * TERR_SUB
		oy := int(c.gy - min_gy) * TERR_SUB
		for ly in 0 ..= TERR_SUB {
			gy := ly * step
			ty := oy + ly
			for lx in 0 ..= TERR_SUB {
				gx := lx * step
				tx := ox + lx
				heights[ty * W + tx] = hgt[gy * TERRAIN_GRID + gx] * HEIGHT_SCALE
				hreal[ty * W + tx] = true
			}
		}
	}
	// Gaps (cells with no LAND) are REAL holes in the heightfield, not covered areas — fill them by
	// interpolating from real neighbors (smoothed) so the surface stays continuous instead of voiding.
	fill_holes_f32(heights, hreal, W, H)

	s.tfield.height = render.upload_height_texture(r, u32(W), u32(H), heights)
	s.tfield.patch = render.make_terrain_patch(r, TERR_PATCH_GRID)

	// Ground texturing: one array layer per unique cell-dominant land texture + an R8 per-cell map
	// from cell → layer. resolve_landscape_tex warms the same cache the near terrain uses.
	layer_of := make(map[Form_ID]u8, 64, context.temp_allocator)
	sources := make([dynamic]render.Texture, 0, 64, context.temp_allocator)
	icols := cols * TERR_INDEX_SUB
	irows := rows * TERR_INDEX_SUB
	istep := TERRAIN_QUADS / TERR_INDEX_SUB // dominant-grid vertices per index texel (32/SUB)
	ids := make([]u8, icols * irows, context.temp_allocator)
	ireal := make([]bool, icols * irows, context.temp_allocator) // real-cell texels (rest filled below)
	// layer_for resolves an LTEX to its ground-array layer, deduping into `sources` (0 fallback).
	layer_for :: proc(
		s: ^Scene,
		db: ^gamedb.DB,
		ltex: Form_ID,
		layer_of: ^map[Form_ID]u8,
		sources: ^[dynamic]render.Texture,
	) -> u8 {
		if ltex == 0 {
			return 0
		}
		if L, seen := layer_of[ltex]; seen {
			return L
		}
		if len(sources) < TERR_MAX_LAYERS {
			if t := resolve_landscape_tex(s, db, ltex); render.tex_valid(t) {
				L := u8(len(sources))
				append(sources, t)
				layer_of[ltex] = L
				return L
			}
		}
		return 0
	}
	for cid in cells {
		c, ok := gamedb.cell_by_formid(db, cid)
		if !ok || !c.has_grid {
			continue
		}
		if _, tok := gamedb.cell_terrain(db, cid); !tok {
			continue // has_grid but no LAND heightmap → leave as a hole (Skyrim draws no terrain here)
		}
		dom, dok := gamedb.cell_dominant_texture(db, cid)
		if !dok || len(dom) < TERRAIN_GRID * TERRAIN_GRID {
			continue
		}
		ox := int(c.gx - min_gx) * TERR_INDEX_SUB
		oy := int(c.gy - min_gy) * TERR_INDEX_SUB
		for ly in 0 ..< TERR_INDEX_SUB {
			gy := ly * istep
			for lx in 0 ..< TERR_INDEX_SUB {
				ltex := dom[gy * TERRAIN_GRID + lx * istep] // per-VERTEX dominant LTEX
				ids[(oy + ly) * icols + (ox + lx)] = layer_for(s, db, ltex, &layer_of, &sources)
				ireal[(oy + ly) * icols + (ox + lx)] = true
			}
		}
	}
	// Hole cells now render (their height is interpolated), so give them a neighbour's ground texture.
	fill_holes_u8(ids, ireal, icols, irows)
	s.tfield.ground = render.build_terrain_array(r, sources[:], TERR_GROUND_SIZE)
	s.tfield.index = render.upload_index_texture(r, u32(icols), u32(irows), ids)
	log.infof("terrain: CDLOD field %dx%d cells, %d ground layers, index %dx%d", cols, rows, len(sources), icols, irows)

	// Quadtree root: the smallest power-of-two square (in cells) that covers the worldspace bbox,
	// anchored at its SW corner. Nodes that fall entirely outside the real bbox are skipped.
	side := i32(1)
	span := max(max_gx - min_gx + 1, max_gy - min_gy + 1)
	for side < span {
		side <<= 1
	}
	s.tfield.root_gx, s.tfield.root_gy, s.tfield.root_side = min_gx, min_gy, side
	s.tfield.bb_min_gx, s.tfield.bb_min_gy = min_gx, min_gy
	s.tfield.bb_max_gx, s.tfield.bb_max_gy = max_gx, max_gy

	ox := f32(min_gx) * CELL_SIZE
	oy := f32(min_gy) * CELL_SIZE
	ext_x := f32(cols) * CELL_SIZE
	ext_y := f32(rows) * CELL_SIZE
	s.tfield.uni_field = {ox, oy, 1.0 / ext_x, 1.0 / ext_y}
	s.tfield.uni_texel = {1.0 / f32(W), 1.0 / f32(H), CELL_SIZE / f32(TERR_SUB), TERR_DROP}
	s.tfield.built = true
}

// TERR_FILL_SMOOTH is how many Laplacian relaxation passes smooth the interpolated hole region
// (real texels are fixed boundaries, so the fill relaxes to a smooth surface between them).
TERR_FILL_SMOOTH :: 24

// fill_holes_f32 fills `!real` texels by flooding real values inward (multi-pass averaging), then
// relaxes the filled region toward a smooth surface. `real` is consumed (left all-true). Used so
// terrain gaps interpolate from neighbours instead of voiding.
@(private)
fill_holes_f32 :: proc(vals: []f32, real: []bool, w, h: int) {
	hole := make([]bool, len(vals), context.temp_allocator)
	for v, i in real {
		hole[i] = !v
	}
	for {
		any_hole, filled := false, 0
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := y * w + x
				if real[i] {
					continue
				}
				sum: f32
				n := 0
				if x > 0 && real[i - 1] {sum += vals[i - 1];n += 1}
				if x < w - 1 && real[i + 1] {sum += vals[i + 1];n += 1}
				if y > 0 && real[i - w] {sum += vals[i - w];n += 1}
				if y < h - 1 && real[i + w] {sum += vals[i + w];n += 1}
				if n > 0 {
					vals[i] = sum / f32(n)
					real[i] = true
					filled += 1
				} else {
					any_hole = true
				}
			}
		}
		if !any_hole || filled == 0 {
			break // all filled, or an isolated region with no real anchor (give up)
		}
	}
	// Relax the originally-hole texels toward their neighbour average (real texels stay fixed).
	for _ in 0 ..< TERR_FILL_SMOOTH {
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := y * w + x
				if !hole[i] {
					continue
				}
				sum: f32
				n := 0
				if x > 0 {sum += vals[i - 1];n += 1}
				if x < w - 1 {sum += vals[i + 1];n += 1}
				if y > 0 {sum += vals[i - w];n += 1}
				if y < h - 1 {sum += vals[i + w];n += 1}
				if n > 0 {
					vals[i] = sum / f32(n)
				}
			}
		}
	}
}

// fill_holes_u8 fills `!real` texels by copying a real neighbour (nearest, no averaging — these are
// discrete texture-layer indices). `real` is consumed.
@(private)
fill_holes_u8 :: proc(vals: []u8, real: []bool, w, h: int) {
	for {
		any_hole, filled := false, 0
		for y in 0 ..< h {
			for x in 0 ..< w {
				i := y * w + x
				if real[i] {
					continue
				}
				v: u8
				found := false
				if x > 0 && real[i - 1] {v = vals[i - 1];found = true} else if x < w - 1 && real[i + 1] {v = vals[i + 1];found = true} else if y > 0 && real[i - w] {v = vals[i - w];found = true} else if y < h - 1 && real[i + w] {v = vals[i + w];found = true}
				if found {
					vals[i] = v
					real[i] = true
					filled += 1
				} else {
					any_hole = true
				}
			}
		}
		if !any_hole || filled == 0 {
			break
		}
	}
}

// update_terrain_field re-selects the quadtree LOD around the camera and re-uploads the patch
// instances — but only when the camera has moved past TERR_REBUILD_STEP (selection is distance-
// based, so rotation/standing still costs nothing). Call once per frame before draw_terrain_field.
update_terrain_field :: proc(s: ^Scene, cam: smath.Vec3) {
	if !s.tfield.built {
		return
	}
	t := &s.tfield
	moved := abs(cam.x - t.last_cx) + abs(cam.y - t.last_cy)
	if t.have_sel && moved < TERR_REBUILD_STEP {
		return
	}

	insts := make([dynamic]render.Terrain_Instance, 0, 1024, context.temp_allocator)
	select_terrain_nodes(t, &insts, t.root_gx, t.root_gy, t.root_side, cam.x, cam.y)

	render.release_terrain_instances(s.cache.r, t.inst)
	t.inst = render.upload_terrain_instances(s.cache.r, insts[:])
	t.have_sel = true
	t.last_cx, t.last_cy = cam.x, cam.y
}

// select_terrain_nodes is the CDLOD top-down LOD pick: emit this node as one patch instance if it
// is a leaf or far enough that its coarseness is acceptable (nearest-point distance > K × size),
// else recurse into its four quadrants. Nodes fully outside the worldspace bbox are pruned.
@(private)
select_terrain_nodes :: proc(
	t: ^Terrain_Field,
	insts: ^[dynamic]render.Terrain_Instance,
	gx, gy, cells: i32,
	camx, camy: f32,
) {
	// Prune nodes that don't overlap the real cell bbox (they would be all holes).
	if gx > t.bb_max_gx || gy > t.bb_max_gy || gx + cells <= t.bb_min_gx || gy + cells <= t.bb_min_gy {
		return
	}

	x0 := f32(gx) * CELL_SIZE
	y0 := f32(gy) * CELL_SIZE
	size := f32(cells) * CELL_SIZE
	// Nearest-point XY distance from the camera to the node rectangle (0 inside).
	dx := max(x0 - camx, 0, camx - (x0 + size))
	dy := max(y0 - camy, 0, camy - (y0 + size))
	d2 := dx * dx + dy * dy
	thresh := terr_lod_k * size

	if cells <= TERR_LEAF_CELLS || d2 > thresh * thresh {
		// w = morph_end: the distance at which this node is replaced by its PARENT (double the size,
		// so terr_lod_k × parent_size). The vertex shader ramps the geomorph to full by here, so the
		// patch matches the parent's grid exactly at the switch — no pop.
		morph_end := terr_lod_k * 2 * size
		append(insts, render.Terrain_Instance{params = {x0, y0, size, morph_end}})
		return
	}
	h := cells / 2
	select_terrain_nodes(t, insts, gx, gy, h, camx, camy)
	select_terrain_nodes(t, insts, gx + h, gy, h, camx, camy)
	select_terrain_nodes(t, insts, gx, gy + h, h, camx, camy)
	select_terrain_nodes(t, insts, gx + h, gy + h, h, camx, camy)
}

// (hole terrain-culling :tags (render unclaimed) :sev polish) terrain patches are not frustum-culled — every selected quadtree node is drawn, including the ones behind the camera.
// draw_terrain_field draws the CDLOD terrain (frustum-culled per patch lands in a later phase).
// Call BEFORE the streamed near terrain so the detailed terrain overdraws it where they overlap.
draw_terrain_field :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, cam: smath.Vec3) {
	if !s.tfield.built {
		return
	}
	u := render.Terrain_Uniforms {
		vp    = vp,
		field = s.tfield.uni_field,
		texel = s.tfield.uni_texel,
		cam   = {cam.x, cam.y, cam.z, terr_drop_fade_band},
		morph = {terr_geomorph_falloff, terr_geomorph_strength, terr_geomorph_distance, terr_drop_fade_start},
	}
	render.draw_terrain(r, s.tfield.patch, s.tfield.inst, s.tfield.height, s.tfield.ground, s.tfield.index, u)
}

release_terrain_field :: proc(s: ^Scene) {
	// Tree-billboard cache is worldspace-scoped (made in build_terrain_field even when the field
	// itself is empty), so free it independent of the tfield guard.
	clear_tree_billboards(s)
	delete(s.tree_billboards)
	s.tree_billboards = nil

	if !s.tfield.built {
		return
	}
	render.release_terrain_instances(s.cache.r, s.tfield.inst)
	render.release_mesh(s.cache.r, s.tfield.patch)
	render.release_texture(s.cache.r, s.tfield.height)
	render.release_texture(s.cache.r, s.tfield.ground)
	render.release_texture(s.cache.r, s.tfield.index)
	s.tfield = {}
}
