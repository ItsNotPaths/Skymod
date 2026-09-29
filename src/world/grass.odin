package world

// Grass scatter + instanced draw (ROADMAP Section F2 vegetation). Each terrain cell
// quadrant's base landscape texture maps (LTEX → GNAM) to a GRAS grass type; we scatter
// cluster placements across that quadrant and draw them as ONE instanced call per grass
// type per cell (render.draw_grass), keyed per-cell so the streamer builds/frees them
// with the chunk — exactly like terrain patches.
//
// We deliberately IMPROVE on Skyrim's crude uniform-random scatter:
//   1. STRATIFIED (jittered-grid) placement — one hashed sample per sub-cell → even
//      coverage, no clumps or bald patches.
//   2. NOISE-MODULATED density — a low-frequency value-noise field thins/thickens the
//      scatter into natural patches instead of a flat carpet.
//   3. SLOPE-AWARE — the heightmap gradient culls steep ground (cliffs stay bare).
//   4. PER-INSTANCE variation — hashed yaw / scale so no two clusters match.
// All hashed deterministically by (cell, quadrant, sub-cell), so streaming never
// reshuffles. Grass TYPE is per-quadrant for now (true per-texel type needs the deferred
// ATXT alpha-layer blending). Knobs below are the visual dials.

import "core:math"

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../models"
import "../render"

// --- scatter knobs (visual dials) ---

// GRASS_SCATTER_SIDE is the candidate grid resolution across a whole cell (one stratified
// sample per sub-cell). Spacing = CELL_SIZE / SIDE; each candidate is then kept by the
// grass type's density + noise, so this is the MAX placement resolution, not the count.
GRASS_SCATTER_SIDE :: 64 // 64×64 = 4096 candidates/cell, spacing 64 units

// GRASS_DENSITY_REF maps a GRAS density byte (≈6–79) to a keep probability:
// density / REF (clamped). Lower REF = denser grass overall.
GRASS_DENSITY_REF :: f32(60)

// GRASS_NOISE_CELL is the density-noise patch size (world units); GRASS_MIN_COVER is the
// fraction kept in the sparsest patches (1 = uniform, lower = patchier).
GRASS_NOISE_CELL :: f32(1536)
GRASS_MIN_COVER :: f32(0.35)

// GRASS_MAX_SLOPE_COS skips ground steeper than this (cos of the max slope angle ~50°).
GRASS_MAX_SLOPE_COS :: f32(0.64)

// Per-instance scale jitter and a defensive cap on instances per batch.
GRASS_SCALE_MIN :: f32(0.7)
GRASS_SCALE_MAX :: f32(1.3)
GRASS_MAX_INSTANCES :: 40000

// Grass_Batch is one grass type's clusters in a cell: the per-cell scatter buffer
// (chunk-owned) + the cluster model by ID, resolved LAZILY at
// draw (nil until the worker has decoded it — so the cluster NIF decode never blocks the
// main thread). One instanced draw per shape of the model.
Grass_Batch :: struct {
	model_id: models.ID,
	model:      ^assetdb.Model, // nil until resolved from the cache
	instances:  render.Grass_Instances, // per-cell scatter buffer (chunk-owned)
	shown:      f32, // Scene.time its model resolved (fade_in)
}

// load_grass scatters and uploads a chunk's grass batches (MAIN THREAD: it decodes the
// grass cluster NIF via the cache on first use and uploads the instance buffer). No-op
// for cells without a grid / heightmap. Grass types are grouped across quadrants so each
// distinct type is one batch (one instanced draw).
load_grass :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if !chunk.has_grid {
		return
	}
	heights, hok := gamedb.cell_terrain(db, chunk.cell_form_id)
	if !hok {
		return
	}
	dom, dok := gamedb.cell_dominant_texture(db, chunk.cell_form_id)
	if !dok {
		return
	}

	// Scatter a stratified grid over the whole cell; each candidate resolves its grass
	// type from the DOMINANT texture at that point (so type + presence vary per-point and
	// follow the painted texture across cell boundaries — not a coarse per-cell base).
	// Accumulate per landscape texture so each distinct type is one batch.
	by_ltex := make(map[Form_ID][dynamic]render.Grass_Instance, 8, context.temp_allocator)
	step := CELL_SIZE / f32(GRASS_SCATTER_SIDE)
	ox := f32(chunk.gx) * CELL_SIZE
	oy := f32(chunk.gy) * CELL_SIZE
	for j in 0 ..< GRASS_SCATTER_SIDE {
		for i in 0 ..< GRASS_SCATTER_SIDE {
			seed := hash4(u32(chunk.cell_form_id), u32(chunk.cell_form_id >> 32), u32(i), u32(j))
			px := ox + (f32(i) + hashf(seed + 1)) * step
			py := oy + (f32(j) + hashf(seed + 2)) * step

			ltex := sample_dominant(dom, chunk.gx, chunk.gy, px, py)
			if ltex == 0 {
				continue
			}
			g, gok := gamedb.grass_for_texture(db, ltex)
			if !gok {
				continue // this texture grows no grass
			}

			// Keep by the type's density × a noise-patch factor.
			cover := math.lerp(GRASS_MIN_COVER, f32(1), value_noise(px, py))
			keep := clamp(f32(g.density) / GRASS_DENSITY_REF, 0, 1) * cover
			if hashf(seed + 3) > keep {
				continue
			}

			z, nz := height_and_slope(heights, chunk.gx, chunk.gy, px, py)
			if nz < GRASS_MAX_SLOPE_COS {
				continue
			}
			yaw := hashf(seed + 4) * 2 * math.PI
			scale := math.lerp(GRASS_SCALE_MIN, GRASS_SCALE_MAX, hashf(seed + 5))

			list, has := &by_ltex[ltex]
			if !has {
				by_ltex[ltex] = make([dynamic]render.Grass_Instance, 0, 256, context.temp_allocator)
				list = &by_ltex[ltex]
			}
			if len(list) < GRASS_MAX_INSTANCES {
				append(list, render.Grass_Instance{pos = {px, py, z}, ys = {yaw, scale}})
			}
		}
	}

	for ltex, list in by_ltex {
		if len(list) == 0 {
			continue
		}
		g, _ := gamedb.grass_for_texture(db, ltex)
		buf := render.upload_grass_instances(s.cache.r, list[:])
		append(&chunk.grass, Grass_Batch{model_id = models.intern(g.model), instances = buf})
	}
}

// sample_dominant returns the dominant-texture LTEX formID at world (wx,wy) — the nearest
// vertex of the cell's TERRAIN_GRID² dominant grid (0 where nothing is painted).
@(private)
sample_dominant :: proc(dom: []Form_ID, gx, gy: i32, wx, wy: f32) -> Form_ID {
	G :: TERRAIN_GRID
	fx := clamp((wx - f32(gx) * CELL_SIZE) / TERRAIN_STEP, 0, f32(G - 1))
	fy := clamp((wy - f32(gy) * CELL_SIZE) / TERRAIN_STEP, 0, f32(G - 1))
	ix := int(fx + 0.5)
	iy := int(fy + 0.5)
	return dom[iy * G + ix]
}

// release_grass frees a chunk's grass instance buffers (cluster models are cache-owned).
release_grass :: proc(s: ^Scene, chunk: ^Chunk) {
	for b in chunk.grass {
		render.release_grass_instances(s.cache.r, b.instances)
	}
	delete(chunk.grass)
	chunk.grass = nil
}

// draw_grass draws every loaded chunk's grass, frustum-culled by chunk AABB and distance-
// culled against `grass_dist` (world units) from the eye. A separate pass from the static draw
// (its own pipeline).
draw_grass :: proc(
	s: ^Scene,
	r: ^render.Renderer,
	vp: smath.Mat4,
	eye: smath.Vec3,
	grass_dist: f32,
) {
	f := smath.frustum_from_vp(vp)
	gd2 := grass_dist * grass_dist
	for vc in s.frame_chunks {
		chunk := vc.c
		if len(chunk.grass) == 0 {
			continue
		}
		// Distance cull on the cell centre (XY) before the frustum test.
		cx := (f32(chunk.gx) + 0.5) * CELL_SIZE
		cy := (f32(chunk.gy) + 0.5) * CELL_SIZE
		dx, dy := cx - eye.x, cy - eye.y
		if dx * dx + dy * dy > gd2 {
			continue
		}
		if !smath.aabb_in_frustum(f, vc.lo, vc.hi) {
			continue
		}
		for &b in chunk.grass {
			if b.model == nil {
				b.model = assetdb.model_ptr(&s.cache, b.model_id)
				if b.model == nil {
					continue // grass cluster not decoded yet — pops in when ready
				}
				b.shown = s.time
			}
			for sh in b.model.shapes {
				cutoff := sh.alpha_cutoff if sh.alpha_cutoff > 0 else 0.5
				render.draw_grass(r, sh.mesh, b.instances, vp, sh.local, sh.tex, cutoff, fade_in(s, b.shown))
			}
		}
	}
}

// --- scatter internals ---

// height_and_slope bilinearly samples the cell heightmap at world (wx,wy) and returns the
// world Z plus the terrain normal's Z component (1 = flat, →0 = vertical) for slope culls.
@(private)
height_and_slope :: proc(heights: []f32, gx, gy: i32, wx, wy: f32) -> (z: f32, nz: f32) {
	z = sample_height(heights, gx, gy, wx, wy)
	// Central difference over one terrain step (TERRAIN_STEP) for the gradient.
	e := TERRAIN_STEP
	dzdx := (sample_height(heights, gx, gy, wx + e, wy) - sample_height(heights, gx, gy, wx - e, wy)) / (2 * e)
	dzdy := (sample_height(heights, gx, gy, wx, wy + e) - sample_height(heights, gx, gy, wx, wy - e)) / (2 * e)
	n := smath.normalize3({-dzdx, -dzdy, 1})
	return z, n.z
}

@(private)
sample_height :: proc(heights: []f32, gx, gy: i32, wx, wy: f32) -> f32 {
	G :: TERRAIN_GRID
	fx := (wx - f32(gx) * CELL_SIZE) / TERRAIN_STEP
	fy := (wy - f32(gy) * CELL_SIZE) / TERRAIN_STEP
	fx = clamp(fx, 0, f32(G - 1))
	fy = clamp(fy, 0, f32(G - 1))
	x0 := int(fx)
	y0 := int(fy)
	x1 := min(x0 + 1, G - 1)
	y1 := min(y0 + 1, G - 1)
	tx := fx - f32(x0)
	ty := fy - f32(y0)
	h00 := heights[y0 * G + x0]
	h10 := heights[y0 * G + x1]
	h01 := heights[y1 * G + x0]
	h11 := heights[y1 * G + x1]
	h := math.lerp(math.lerp(h00, h10, tx), math.lerp(h01, h11, tx), ty)
	return h * HEIGHT_SCALE
}

// --- deterministic hashing + value noise ---

@(private)
hash_u32 :: proc(x: u32) -> u32 {
	x := x
	x ~= x >> 16
	x *= 0x7feb352d
	x ~= x >> 15
	x *= 0x846ca68b
	x ~= x >> 16
	return x
}

@(private)
hash4 :: proc(a, b, c, d: u32) -> u32 {
	h := a * 0x9e3779b1
	h = (h ~ b) * 0x9e3779b1
	h = (h ~ c) * 0x9e3779b1
	h = (h ~ d) * 0x9e3779b1
	return hash_u32(h)
}

// hashf maps a seed to a float in [0,1).
@(private)
hashf :: proc(seed: u32) -> f32 {
	return f32(hash_u32(seed) & 0xFF_FFFF) / f32(0x100_0000)
}

// value_noise is smooth 2D value noise (hashed lattice + smoothstep bilerp) over world
// XY at GRASS_NOISE_CELL spacing, in [0,1] — the density-modulation field.
@(private)
value_noise :: proc(wx, wy: f32) -> f32 {
	fx := wx / GRASS_NOISE_CELL
	fy := wy / GRASS_NOISE_CELL
	ix := math.floor(fx)
	iy := math.floor(fy)
	tx := fx - ix
	ty := fy - iy
	ux := tx * tx * (3 - 2 * tx)
	uy := ty * ty * (3 - 2 * ty)
	v00 := lattice(ix, iy)
	v10 := lattice(ix + 1, iy)
	v01 := lattice(ix, iy + 1)
	v11 := lattice(ix + 1, iy + 1)
	return math.lerp(math.lerp(v00, v10, ux), math.lerp(v01, v11, ux), uy)
}

@(private)
lattice :: proc(ix, iy: f32) -> f32 {
	return hashf(hash4(transmute(u32)i32(ix), transmute(u32)i32(iy), 0x5ca1ab1e, 0))
}
