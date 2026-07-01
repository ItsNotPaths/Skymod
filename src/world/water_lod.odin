package world

// Baked distant water (mirrors object_lod.odin). Per-cell water at VARYING heights — mountain
// lakes high, rivers low — is core to Skyrim's look, so it can't be flattened to one worldspace
// plane. Instead each cell's flat water quad (at its real, gamedb-resolved XCLW height) is merged,
// by QUAD, into one mesh at load — preserving every height — so distant lakes/rivers draw in ~one
// call per quad instead of one per cell. Same visibility cull as the near per-cell path (water
// buried under terrain is skipped). Near cells keep their animated per-cell water; baked quads
// fully inside the full-detail bubble are suppressed at draw, so there's no double-draw.
//
// Built once at load from gamedb (no streamer dependency) — like the object bake, churn-free.

import "core:log"
import "core:math"

import "../gamedb"
import smath "../math"
import "../render"

// Water_Quad is one quad's merged water planes: quad grid coord (for near-suppression), a cull
// AABB, and a single mesh holding every water cell's quad at its own height.
Water_Quad :: struct {
	gx, gy: i32,
	lo, hi: smath.Vec3,
	mesh:   render.Mesh,
}

// bake_water_lod merges the whole worldspace's per-cell water planes into one mesh per quad, once.
// Call after stream_init / on stream_retarget. Heights are per cell (preserved exactly).
bake_water_lod :: proc(st: ^Streamer) {
	s := st.scene
	db := st.db
	clear_water_lod(s)

	QV :: struct {
		verts:  [dynamic]render.Mesh_Vertex,
		idx:    [dynamic]u16,
		lo, hi: smath.Vec3,
	}
	quads := make(map[u64]QV, 256, context.temp_allocator)
	qcoord := make(map[u64][2]i32, 256, context.temp_allocator)

	for cid in gamedb.cells_of(db, st.world_fid) {
		cell, ok := gamedb.cell_by_formid(db, cid)
		if !ok || !cell.has_grid {
			continue
		}
		wh, wok := gamedb.cell_water(db, cid)
		if !wok {
			continue
		}
		// Visibility cull (same as load_water): skip if the cell's terrain never dips below the water.
		if heights, hok := gamedb.cell_terrain(db, cid); hok {
			tmin := max(f32)
			for v in heights {tmin = min(tmin, v * HEIGHT_SCALE)}
			if wh <= tmin {
				continue
			}
		}
		qgx, qgy := lod_quad_div(cell.gx), lod_quad_div(cell.gy)
		key := lod_quad_key(qgx, qgy)
		q, has := &quads[key]
		if !has {
			quads[key] = QV {
				verts = make([dynamic]render.Mesh_Vertex, 0, 256, context.temp_allocator),
				idx   = make([dynamic]u16, 0, 384, context.temp_allocator),
				lo    = {max(f32), max(f32), max(f32)},
				hi    = {min(f32), min(f32), min(f32)},
			}
			q = &quads[key]
			qcoord[key] = {qgx, qgy}
		}
		ox := f32(cell.gx) * CELL_SIZE
		oy := f32(cell.gy) * CELL_SIZE
		up := smath.Vec3{0, 0, 1}
		base := u16(len(q.verts))
		append(
			&q.verts,
			render.Mesh_Vertex{pos = {ox, oy, wh}, normal = up, uv = {0, 0}},
			render.Mesh_Vertex{pos = {ox + CELL_SIZE, oy, wh}, normal = up, uv = {1, 0}},
			render.Mesh_Vertex{pos = {ox + CELL_SIZE, oy + CELL_SIZE, wh}, normal = up, uv = {1, 1}},
			render.Mesh_Vertex{pos = {ox, oy + CELL_SIZE, wh}, normal = up, uv = {0, 1}},
		)
		append(&q.idx, base + 0, base + 1, base + 2, base + 0, base + 2, base + 3)
		q.lo = {min(q.lo.x, ox), min(q.lo.y, oy), min(q.lo.z, wh)}
		q.hi = {max(q.hi.x, ox + CELL_SIZE), max(q.hi.y, oy + CELL_SIZE), max(q.hi.z, wh)}
	}

	nq := 0
	for key, q in quads {
		if len(q.idx) == 0 {
			continue
		}
		c := qcoord[key]
		mesh := render.upload_mesh(s.cache.r, q.verts[:], q.idx[:])
		s.water_quads[key] = Water_Quad{gx = c[0], gy = c[1], lo = q.lo, hi = q.hi, mesh = mesh}
		nq += 1
	}
	log.infof("water LOD: baked %d water quads", nq)
}

// clear_water_lod releases every baked water-quad mesh and empties the map (teardown / retarget).
clear_water_lod :: proc(s: ^Scene) {
	for _, &q in s.water_quads {
		render.release_mesh(s.cache.r, q.mesh)
	}
	clear(&s.water_quads)
}

// draw_water_lod draws the baked distant-water quads (transparent pass, after opaque), frustum-
// culled by quad AABB, suppressing quads fully inside the full-detail bubble (those cells draw
// their own animated per-cell water). Call alongside draw_water.
draw_water_lod :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, cam_pos: smath.Vec3, full_radius: int, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	pcx := i32(math.floor(cam_pos.x / CELL_SIZE))
	pcy := i32(math.floor(cam_pos.y / CELL_SIZE))
	fr := i32(full_radius)
	for _, &q in s.water_quads {
		qx0, qy0 := q.gx * OBJECT_LOD_QUAD, q.gy * OBJECT_LOD_QUAD
		qx1, qy1 := qx0 + OBJECT_LOD_QUAD - 1, qy0 + OBJECT_LOD_QUAD - 1
		if qx0 >= pcx - fr && qx1 <= pcx + fr && qy0 >= pcy - fr && qy1 <= pcy + fr {
			continue // inside the bubble — per-cell animated water draws there
		}
		if !smath.aabb_in_frustum(f, q.lo, q.hi) {
			continue
		}
		render.draw_water(r, q.mesh, vp, cam_pos, time)
	}
}
