package world

// Per-cell water (stopgap). Skyrim stores water as a flat height per cell (CELL.XCLW,
// resolved in gamedb against the worldspace default), so each exterior cell with water
// becomes ONE quad spanning the cell at that height — the cheap "do better than Skyrim
// for less" win: 2 triangles per cell, no tessellation, all ripples procedural in the
// shader (render/water.frag). Drawn in a transparent pass after opaque geometry; the
// depth buffer masks it for free (terrain above the plane occludes it).
//
// OPTIMIZATION: a cell whose terrain never dips below the water height shows no water, so
// we skip its quad entirely (the FLT_MAX-default sea level prunes every inland cell this
// way — only coasts/rivers/lakes build a plane).
//
// Interiors are skipped for now (no grid footprint to size the quad to); flooded-dungeon
// water is a later pass.

import "../gamedb"
import smath "../math"
import "../render"

// load_water builds + uploads a chunk's flat water plane if its cell has water AND that
// water is visible (some terrain dips below it). MAIN THREAD (GPU upload), like
// load_terrain. No-op for cells without a grid, without water, or fully above the plane.
// Call AFTER load_terrain (it does not depend on the terrain mesh, only the heightmap).
load_water :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if !chunk.has_grid {
		return
	}
	wh, ok := gamedb.cell_water(db, chunk.cell_form_id)
	if !ok {
		return
	}
	// Visibility cull: if the whole cell's terrain sits at or above the water height, the
	// plane is buried and never seen — skip it. (No heightmap → can't tell → draw it.)
	if heights, hok := gamedb.cell_terrain(db, chunk.cell_form_id); hok {
		tmin := max(f32)
		for v in heights {
			tmin = min(tmin, v * HEIGHT_SCALE)
		}
		if wh <= tmin {
			return
		}
	}

	ox := f32(chunk.gx) * CELL_SIZE
	oy := f32(chunk.gy) * CELL_SIZE
	up := smath.Vec3{0, 0, 1}
	verts := [4]render.Mesh_Vertex {
		{pos = {ox, oy, wh}, normal = up, uv = {0, 0}},
		{pos = {ox + CELL_SIZE, oy, wh}, normal = up, uv = {1, 0}},
		{pos = {ox + CELL_SIZE, oy + CELL_SIZE, wh}, normal = up, uv = {1, 1}},
		{pos = {ox, oy + CELL_SIZE, wh}, normal = up, uv = {0, 1}},
	}
	idx := [6]u16{0, 1, 2, 0, 2, 3}
	chunk.water = render.upload_mesh(s.cache.r, verts[:], idx[:])
	chunk.has_water = true

	// Fold the plane's height into the culling AABB so a cell that is ONLY water (no
	// statics, terrain entirely below) still passes the frustum test and draws.
	chunk.lo.z = min(chunk.lo.z, wh)
	chunk.hi.z = max(chunk.hi.z, wh)
}

// release_water frees a chunk's water plane mesh. Call on chunk unload / scene teardown.
release_water :: proc(s: ^Scene, chunk: ^Chunk) {
	if chunk.has_water {
		render.release_mesh(s.cache.r, chunk.water)
		chunk.water = {}
		chunk.has_water = false
	}
}

// draw_water draws every visible chunk's water plane (transparent pass). Same frustum cull
// as draw; call AFTER opaque geometry so the depth buffer masks submerged-only regions and
// the blend lands over the underwater terrain. `cam_pos` drives fresnel/specular, `time`
// the procedural ripples.
draw_water :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, cam_pos: smath.Vec3, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	for vc in s.frame_chunks {
		if !vc.c.has_water || !smath.aabb_in_frustum(f, vc.lo, vc.hi) {
			continue
		}
		render.draw_water(r, vc.c.water, vp, cam_pos, time)
	}
}
