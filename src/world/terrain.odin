package world

// Exterior terrain (ROADMAP Section F2). Turns a cell's LAND heightmap (decoded in
// gamedb from VHGT) into a drawable per-chunk mesh, in NATIVE Skyrim world units, and
// textures it per-quadrant from the cell's base landscape textures (BTXT → LTEX → TXST
// → TX00). Basic, no alpha-layer blending yet: each of the cell's 4 quadrants gets one
// base ground texture with hard seams (the ATXT/VTXT alpha splatting is the next step).
//
// SHADOW-READINESS (the design deviation from Skyrim): terrain is a FIRST-CLASS mesh on
// the SAME render.Mesh / draw_mesh path as every static — NOT a special terrain path the
// way the Creation Engine treats it. So when a sun shadow pass lands, the terrain is
// already an ordinary caster: the pass just iterates the same chunks and draws each
// terrain patch into the shadow map. Two concrete consequences baked in here:
//   1. Per-vertex normals are COMPUTED from the heightmap (central differences), so they
//      are exactly consistent with the surface the shadows are cast from — no reliance on
//      VNML's authored bytes, no guess-and-check encoding to tune. (VNML exists and could
//      replace these later to match Skyrim's exact shading.)
//   2. The terrain's full XY footprint + its Z range are folded into the chunk's culling
//      AABB, so the eventual cascaded-shadow-map caster cull reuses the same
//      aabb_in_frustum machinery against the light frustum.
//
// Terrain build is IO-light (heights are resident in gamedb; only the diffuse DDS reads
// hit the VFS, deduped by the asset cache), so unlike full model loading it runs on the
// MAIN thread at chunk-load time rather than through the worker pipeline. If profiling
// ever shows a hitch, the seam to move it onto the decode→upload worker pipeline is the
// same Req/Result path models use.

import "core:log"
import "core:strings"

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../render"

// TERRAIN_GRID is the heightmap's vertex count per side (must match esm.LAND_GRID);
// TERRAIN_QUADS is one fewer, the quad count per side spanning CELL_SIZE.
TERRAIN_GRID :: 33
TERRAIN_QUADS :: TERRAIN_GRID - 1
TERRAIN_STEP :: CELL_SIZE / f32(TERRAIN_QUADS) // world units between heightmap samples (128)

// QUAD_GRID is a cell quadrant's vertex count per side: the 33×33 grid splits 2×2 at
// the centre row/col (index 16), so each quadrant is 17×17 (sharing the centre line).
QUAD_GRID :: 17
QUAD_QUADS :: QUAD_GRID - 1

// HEIGHT_SCALE converts a LAND cumulative height value to world Z units. This is the
// visual knob to verify (Skyrim's convention is 8) — adjust here if terrain reads too
// flat or too tall.
HEIGHT_SCALE :: f32(8)

// SKIRT_DEPTH is how far a LOD terrain mesh's perimeter drops straight down (world units)
// to hide cracks where a coarse cell meets a finer-LOD neighbour. Only the coarse side
// needs it; the wall is hidden under the finer terrain.
SKIRT_DEPTH :: f32(800)

// TERRAIN_UV_TILES is how many times the base ground texture repeats across a full cell
// (4096 units). Landscape textures TILE in Skyrim — a 0..1 UV would stretch one blurry
// copy over the whole cell — so this sets the visible texel density. Visual knob: raise
// for a finer/denser ground, lower for coarser. (Sampler wrap mode is repeat.)
TERRAIN_UV_TILES :: f32(8)

// Terrain_Patch is one drawable piece of a cell's terrain: a GPU mesh (owned by the
// chunk) and its diffuse (shared, owned by the asset cache). One per textured quadrant.
Terrain_Patch :: struct {
	mesh: render.Mesh,
	tex:  render.Texture,
}

// build_terrain_verts turns a cell's row-major heightmap (gamedb cumulative values) into
// the full TERRAIN_GRID² world-space vertex grid: positions placed by the cell's grid
// coordinate, normals from the height gradient, planar UVs, and the world AABB. Allocates
// in `alloc` (use temp — the per-quadrant uploads copy out of it immediately).
build_terrain_verts :: proc(
	heights: []f32,
	gx, gy: i32,
	alloc := context.allocator,
) -> (
	verts: []render.Mesh_Vertex,
	lo: smath.Vec3,
	hi: smath.Vec3,
) {
	G :: TERRAIN_GRID
	ox := f32(gx) * CELL_SIZE
	oy := f32(gy) * CELL_SIZE

	verts = make([]render.Mesh_Vertex, G * G, alloc)
	lo = {max(f32), max(f32), max(f32)}
	hi = {min(f32), min(f32), min(f32)}
	for y in 0 ..< G {
		for x in 0 ..< G {
			z := heights[y * G + x] * HEIGHT_SCALE
			px := ox + f32(x) * TERRAIN_STEP
			py := oy + f32(y) * TERRAIN_STEP

			// Normal from the height gradient (central difference, one-sided at edges).
			xm, xp := max(x - 1, 0), min(x + 1, G - 1)
			ym, yp := max(y - 1, 0), min(y + 1, G - 1)
			dzdx := (heights[y * G + xp] - heights[y * G + xm]) * HEIGHT_SCALE / (f32(xp - xm) * TERRAIN_STEP)
			dzdy := (heights[yp * G + x] - heights[ym * G + x]) * HEIGHT_SCALE / (f32(yp - ym) * TERRAIN_STEP)
			n := smath.normalize3({-dzdx, -dzdy, 1})

			verts[y * G + x] = {
				pos     = {px, py, z},
				normal  = n,
				tangent = {1, 0, 0, 1}, // +X (U-aligned); shader re-orthonormalizes against the normal
				uv      = {
					f32(x) / f32(TERRAIN_QUADS) * TERRAIN_UV_TILES,
					f32(y) / f32(TERRAIN_QUADS) * TERRAIN_UV_TILES,
				},
			}
			lo = {min(lo.x, px), min(lo.y, py), min(lo.z, z)}
			hi = {max(hi.x, px), max(hi.y, py), max(hi.z, z)}
		}
	}
	return
}

// quadrant_geo extracts one quadrant's compact 17×17 sub-mesh from the full vertex grid:
// quadrant q is (0=SW,1=SE,2=NW,3=NE), covering grid indices [qx·16 .. qx·16+16] in each
// axis. Returns owned (in `alloc`) compact verts + triangle indices.
quadrant_geo :: proc(
	verts: []render.Mesh_Vertex,
	q: int,
	alloc := context.allocator,
) -> (
	qverts: []render.Mesh_Vertex,
	qidx: []u16,
) {
	G :: TERRAIN_GRID
	QV :: QUAD_GRID
	x0 := (q & 1) * QUAD_QUADS
	y0 := ((q >> 1) & 1) * QUAD_QUADS

	qverts = make([]render.Mesh_Vertex, QV * QV, alloc)
	for ly in 0 ..< QV {
		for lx in 0 ..< QV {
			qverts[ly * QV + lx] = verts[(y0 + ly) * G + (x0 + lx)]
		}
	}

	qidx = make([]u16, QUAD_QUADS * QUAD_QUADS * 6, alloc)
	i := 0
	for ly in 0 ..< QUAD_QUADS {
		for lx in 0 ..< QUAD_QUADS {
			v00 := u16(ly * QV + lx)
			v10 := u16(ly * QV + lx + 1)
			v01 := u16((ly + 1) * QV + lx)
			v11 := u16((ly + 1) * QV + lx + 1)
			qidx[i + 0], qidx[i + 1], qidx[i + 2] = v00, v10, v11
			qidx[i + 3], qidx[i + 4], qidx[i + 5] = v00, v11, v01
			i += 6
		}
	}
	return
}

// build_terrain_lod builds a single DOWNSAMPLED terrain mesh for a distant cell: it
// samples the heightmap every `stride` vertices (stride 2→17², 4→9², 8→5²) and adds a
// perimeter skirt dropping SKIRT_DEPTH down to hide LOD-boundary cracks. One mesh, one
// texture (full detail isn't needed at distance). Allocates in `alloc` (use temp).
build_terrain_lod :: proc(
	heights: []f32,
	gx, gy: i32,
	stride: int,
	alloc := context.allocator,
) -> (
	verts: [dynamic]render.Mesh_Vertex,
	indices: [dynamic]u16,
	lo: smath.Vec3,
	hi: smath.Vec3,
) {
	G :: TERRAIN_GRID
	N := (G - 1) / stride + 1 // vertices per side (17 / 9 / 5)
	ox := f32(gx) * CELL_SIZE
	oy := f32(gy) * CELL_SIZE
	verts = make([dynamic]render.Mesh_Vertex, 0, N * N + 4 * N, alloc)
	indices = make([dynamic]u16, 0, (N - 1) * (N - 1) * 6 + 4 * (N - 1) * 6, alloc)
	lo = {max(f32), max(f32), max(f32)}
	hi = {min(f32), min(f32), min(f32)}

	for gyi in 0 ..< N {
		for gxi in 0 ..< N {
			hx := gxi * stride // height-grid index 0..32
			hy := gyi * stride
			z := heights[hy * G + hx] * HEIGHT_SCALE
			px := ox + f32(hx) * TERRAIN_STEP
			py := oy + f32(hy) * TERRAIN_STEP

			// Normal from the gradient over the strided neighbours (clamped at edges).
			xm, xp := max(hx - stride, 0), min(hx + stride, G - 1)
			ym, yp := max(hy - stride, 0), min(hy + stride, G - 1)
			dzdx := (heights[hy * G + xp] - heights[hy * G + xm]) * HEIGHT_SCALE / (f32(xp - xm) * TERRAIN_STEP)
			dzdy := (heights[yp * G + hx] - heights[ym * G + hx]) * HEIGHT_SCALE / (f32(yp - ym) * TERRAIN_STEP)
			append(
				&verts,
				render.Mesh_Vertex {
					pos = {px, py, z},
					normal = smath.normalize3({-dzdx, -dzdy, 1}),
					tangent = {1, 0, 0, 1},
					uv = {f32(hx) / f32(TERRAIN_QUADS) * TERRAIN_UV_TILES, f32(hy) / f32(TERRAIN_QUADS) * TERRAIN_UV_TILES},
				},
			)
			lo = {min(lo.x, px), min(lo.y, py), min(lo.z, z)}
			hi = {max(hi.x, px), max(hi.y, py), max(hi.z, z)}
		}
	}
	for gyi in 0 ..< N - 1 {
		for gxi in 0 ..< N - 1 {
			v00 := u16(gyi * N + gxi)
			v10 := u16(gyi * N + gxi + 1)
			v01 := u16((gyi + 1) * N + gxi)
			v11 := u16((gyi + 1) * N + gxi + 1)
			append(&indices, v00, v10, v11, v00, v11, v01)
		}
	}

	// Perimeter skirt: drop each edge straight down so a coarser/finer neighbour's gap
	// is covered by this wall. Build the four edges' top-vertex index runs, then wall each.
	south := make([]u16, N, context.temp_allocator)
	north := make([]u16, N, context.temp_allocator)
	west := make([]u16, N, context.temp_allocator)
	east := make([]u16, N, context.temp_allocator)
	for k in 0 ..< N {
		south[k] = u16(k)
		north[k] = u16((N - 1) * N + k)
		west[k] = u16(k * N)
		east[k] = u16(k * N + (N - 1))
	}
	add_skirt_edge(&verts, &indices, south[:])
	add_skirt_edge(&verts, &indices, north[:])
	add_skirt_edge(&verts, &indices, west[:])
	add_skirt_edge(&verts, &indices, east[:])
	lo.z -= SKIRT_DEPTH
	return
}

// add_skirt_edge appends a vertical wall hanging SKIRT_DEPTH below the edge whose top
// vertices are `top` (in order), linking each segment to its dropped copies.
@(private)
add_skirt_edge :: proc(verts: ^[dynamic]render.Mesh_Vertex, indices: ^[dynamic]u16, top: []u16) {
	for k in 0 ..< len(top) {
		v := verts[top[k]]
		v.pos.z -= SKIRT_DEPTH
		append(verts, v)
	}
	base := u16(len(verts) - len(top)) // first appended skirt vertex
	for k in 0 ..< len(top) - 1 {
		t0, t1 := top[k], top[k + 1]
		s0, s1 := base + u16(k), base + u16(k + 1)
		append(indices, t0, t1, s1, t0, s1, s0)
	}
}

// resolve_landscape_tex resolves an LTEX formID to its diffuse GPU texture (LTEX → TXST →
// TX00, prefixed with textures\, via the deduped cache). Returns the zero Texture if the
// LTEX is 0, unresolvable (e.g. Skyrim's 0x844 default-land sentinel — no record), or the
// DDS fails. MAIN THREAD.
@(private)
resolve_landscape_tex :: proc(s: ^Scene, db: ^gamedb.DB, ltex: Form_ID) -> render.Texture {
	if ltex == 0 {
		return {}
	}
	path, ok := gamedb.landscape_diffuse(db, ltex)
	if !ok {
		return {}
	}
	full := strings.concatenate({"textures\\", path}, context.temp_allocator)
	tex, _ := assetdb.get_texture(&s.cache, full)
	return tex
}

// quadrant_texture picks a quadrant's ground texture with a fallback chain that avoids the
// white-square bug: the quadrant's base LTEX, else the texture actually PAINTED at the
// quadrant centre (dominant grid — handles base = the unresolvable 0x844 default with ATXT
// over it), else any resolvable base in the cell. As a last resort it borrows the most
// recently resolved ground texture (a nearby tile, since loading is nearest-first) and
// logs the miss — so a cell never goes white, and the bad LTEX is surfaced.
@(private)
quadrant_texture :: proc(s: ^Scene, db: ^gamedb.DB, cell_form_id: Form_ID, q: int, base: [4]Form_ID) -> render.Texture {
	ok_tex :: proc(s: ^Scene, t: render.Texture) -> (render.Texture, bool) {
		if render.tex_valid(t) {
			s.last_land_tex = t // remember for the nearby-tile fallback
			return t, true
		}
		return {}, false
	}
	if t, ok := ok_tex(s, resolve_landscape_tex(s, db, base[q])); ok {
		return t
	}
	if dom, ok := gamedb.cell_dominant_texture(db, cell_form_id); ok {
		G :: TERRAIN_GRID
		cx := (q & 1) * QUAD_QUADS + QUAD_QUADS / 2 // quadrant-centre vertex
		cy := ((q >> 1) & 1) * QUAD_QUADS + QUAD_QUADS / 2
		if t, tok := ok_tex(s, resolve_landscape_tex(s, db, dom[cy * G + cx])); tok {
			return t
		}
	}
	for b in base {
		if t, tok := ok_tex(s, resolve_landscape_tex(s, db, b)); tok {
			return t
		}
	}
	// An empty quadrant (no BTXT — common on water/border cells) borrows silently; only a
	// non-zero LTEX that failed to resolve is genuinely odd and worth a warning.
	if base[q] != 0 {
		log.warnf(
			"terrain: cell 0x%08X quadrant %d: LTEX 0x%08X has no resolvable ground texture — borrowing nearest tile",
			cell_form_id,
			q,
			base[q],
		)
	}
	return s.last_land_tex // a nearby/recent tile's texture (zero only before any resolved)
}

// load_terrain builds + uploads a chunk's terrain patches (one per quadrant) if its cell
// has a LAND record, textures each from the cell's base landscape textures, and folds the
// terrain bounds into the chunk's culling AABB. MAIN THREAD (it uploads to the GPU). A
// no-op for cells without a grid or without terrain (interiors). Uses the temp allocator
// for the CPU build — the uploads copy into GPU buffers at once.
load_terrain :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if !chunk.has_grid {
		return
	}
	heights, ok := gamedb.cell_terrain(db, chunk.cell_form_id)
	if !ok {
		return
	}
	base, _ := gamedb.cell_base_textures(db, chunk.cell_form_id)
	tlo, thi: smath.Vec3

	if chunk.lod == 0 {
		// Full detail: 4 quadrant patches, each its own base texture.
		verts: []render.Mesh_Vertex
		verts, tlo, thi = build_terrain_verts(heights, chunk.gx, chunk.gy, context.temp_allocator)
		for q in 0 ..< 4 {
			tex := quadrant_texture(s, db, chunk.cell_form_id, q, base)
			qverts, qidx := quadrant_geo(verts, q, context.temp_allocator)
			append(&chunk.terrain, Terrain_Patch{mesh = render.upload_mesh(s.cache.r, qverts, qidx), tex = tex})
		}
	} else {
		// Distant LOD: one downsampled + skirted mesh, one texture (any quadrant's base).
		stride := 1 << uint(chunk.lod) // lod 1→2, 2→4, 3→8
		verts, idx, lo, hi := build_terrain_lod(heights, chunk.gx, chunk.gy, stride, context.temp_allocator)
		tlo, thi = lo, hi
		// One texture for the whole distant tile: try each quadrant's resolved texture.
		tex: render.Texture
		for q in 0 ..< 4 {
			if t := quadrant_texture(s, db, chunk.cell_form_id, q, base); render.tex_valid(t) {
				tex = t
				break
			}
		}
		append(&chunk.terrain, Terrain_Patch{mesh = render.upload_mesh(s.cache.r, verts[:], idx[:]), tex = tex})
	}

	// Extend (or set) the culling AABB so the chunk is drawn whenever its terrain is
	// visible — even if it has no placed instances.
	if len(chunk.instances) == 0 {
		chunk.lo, chunk.hi = tlo, thi
	} else {
		chunk.lo = {min(chunk.lo.x, tlo.x), min(chunk.lo.y, tlo.y), min(chunk.lo.z, tlo.z)}
		chunk.hi = {max(chunk.hi.x, thi.x), max(chunk.hi.y, thi.y), max(chunk.hi.z, thi.z)}
	}
}

// release_terrain frees a chunk's terrain patch meshes (textures are cache-owned, not
// released here). Call on chunk unload / scene teardown.
release_terrain :: proc(s: ^Scene, chunk: ^Chunk) {
	for p in chunk.terrain {
		render.release_mesh(s.cache.r, p.mesh)
	}
	delete(chunk.terrain)
	chunk.terrain = nil
}
