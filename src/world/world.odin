package world

// World / cell scene (ROADMAP Iteration 1 Milestone C; Section E exteriors; Section F
// streaming). Turns gamedb REFR placements into drawable instances at native Skyrim
// units. The static-model skeleton — lighting/water/navmesh/actors/collision are out
// of scope. Markers and disabled refs are skipped.
//
// A Scene is a MAP of CHUNKS keyed by cell formID, one per loaded cell. An interior is
// a single chunk; a bounded exterior (WhiterunWorld) loads them all up front; the
// open world (Tamriel) streams them in/out around the player (see stream.odin). The
// chunk is the streaming unit and the frustum-culling unit.
//
// Instances reference their model by PATH (borrowed from gamedb, stable for the
// session) and hold a `model` pointer that is nil until the asset is uploaded —
// resolved lazily at draw. The synchronous loaders resolve it immediately (get_model);
// the streamer leaves it nil and the model pops in as the worker delivers it.

import "core:log"
import "core:strings"

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../render"
import "../vfs"

// Hardcoded marker base forms (invisible editor helpers): XMarker / XMarkerHeading.
XMARKER :: 0x0000_003B
XMARKER_HEADING :: 0x0000_0034

// Sun direction for the single directional light (world space, toward the light).
LIGHT_DIR :: smath.Vec3{0.4, 0.6, 1.0}

// Vegetation wind tuning, by "weight". Displacement in the shaders is amplitude×height,
// so SHORT foliage needs a much bigger amplitude than a tree to move a visible amount —
// otherwise small plants look frozen next to swaying trees. Frequency varies too: heavy
// trees sway slowly, light foliage flutters fast. (Grass has its own amplitude on its
// dedicated path.) Visual tuning knobs — amplitude (per world-unit of height) + a
// multiplier on the global wind speed.
TREE_WIND :: f32(0.006) // heavy: small lean
TREE_SPEED :: f32(0.7) // …and slow
PLANT_WIND :: f32(0.13) // light: large amplitude (so short flora still moves visibly)
PLANT_SPEED :: f32(1.5) // …and quick flutter
// …but cap the height that feeds the amplitude, so TALL foliage (shrubs, ferns, vine
// maple) doesn't wave wildly — only short flora scale up to it. World units.
PLANT_HEIGHT_CAP :: f32(45)

// veg_wind classifies a model path as vegetation and returns its per-type wind (amplitude,
// oscillation speed, height cap), preserving the global wind DIRECTION. strength 0 = not
// vegetation → rigid. Trees live under `...\Trees\`, other foliage under `...\Plants\` /
// `Plants\`. Everything else (architecture, rocks, clutter) is rigid.
veg_wind :: proc(path: string, base: render.Wind) -> render.Wind {
	p := strings.to_lower(path, context.temp_allocator)
	switch {
	case strings.contains(p, "trees\\"):
		return {dir = base.dir, strength = TREE_WIND, speed = base.speed * TREE_SPEED}
	case strings.contains(p, "plants\\"):
		return {
			dir = base.dir,
			strength = PLANT_WIND,
			speed = base.speed * PLANT_SPEED,
			height_cap = PLANT_HEIGHT_CAP,
		}
	}
	return {dir = base.dir, speed = base.speed} // rigid (strength 0)
}

// veg_phase derives a per-placement wind phase from world position so neighbouring plants
// sway out of sync — while all share the one global wind DIRECTION (no random directions).
veg_phase :: proc(pos: smath.Vec3) -> f32 {
	return pos.x * 0.013 + pos.y * 0.017
}

// is_marker_path reports whether a model is an invisible editor helper (dragon-landing,
// critter/bird-path, link/civil-war markers, etc.) that shouldn't render in-game. Skyrim
// names all such meshes with "marker" in the path; "market" doesn't contain "marker", so
// this is safe. (XMarker/XMarkerHeading base forms are also skipped by formID.)
is_marker_path :: proc(modl: string) -> bool {
	return strings.contains(strings.to_lower(modl, context.temp_allocator), "marker")
}

// is_nonworld_path reports whether a model belongs to a SPECIAL-render system, not static
// world geometry: `Sky\` (the sky dome / clouds — managed by the sky system, would otherwise
// draw as giant opaque quads) and `Water\` (water planes — need a water shader we don't have).
// Both appear as persistent-cell refs; skip them so the persistent statics layer stays clean.
// Folder-prefixed (`sky\`/`water\`) so names like `WRStairsWater01River01` (real geometry,
// not in a Water\ folder) are kept.
is_nonworld_path :: proc(modl: string) -> bool {
	low := strings.to_lower(modl, context.temp_allocator)
	return strings.contains(low, "sky\\") || strings.contains(low, "water\\")
}

// CELL_SIZE is the side of one exterior cell in world units.
CELL_SIZE :: f32(4096)

// Conservative half-extent added to a chunk's instance-position bounds so culling
// never clips a tall/wide mesh whose origin sits near a cell edge.
CHUNK_MARGIN :: f32(4096)

// Instance_Vis is a placement's render visibility. Show is the default (zero) value.
// Hidden / ShadowOnly are set by the open-interiors experiment to suppress an exterior
// building's shell while the player is inside the inlined interior — the color passes skip
// both. ShadowOnly is reserved: a future shadow/depth pass will still render it, so the
// hidden building keeps casting shadows. Today it behaves like Hidden (no shadow pass yet).
Instance_Vis :: enum u8 {
	Show,
	ShadowOnly,
	Hidden,
}

// Instance is one placed reference: its model (shared, nil until uploaded) referenced
// by path, the raw REFR placement, and a door teleport if this is a load door.
Instance :: struct {
	model_path: string, // borrowed from gamedb (valid for the DB's lifetime)
	model:      ^assetdb.Model, // nil until the asset is uploaded; resolved lazily
	base:       u32,
	pos:        smath.Vec3,
	rot:        smath.Vec3, // XYZ euler radians (REFR DATA)
	scale:      f32,
	has_tp:     bool,
	tp_door:    u32, // destination door formID (XTEL)
	tp_pos:     smath.Vec3, // XTEL landing position in the DEST cell (arrival placement)
	tp_rot:     smath.Vec3, // XTEL landing rotation (arrival facing)
	vis:        Instance_Vis, // render visibility (Show by default; see Instance_Vis)
}

// Chunk is one loaded cell's instances + a culling AABB. Exterior cells carry their
// grid coordinate and detail level (lod 0 = full; higher reserved for Section-F LOD).
Chunk :: struct {
	cell_form_id: u32,
	gx, gy:       i32,
	has_grid:     bool,
	lod:          int,
	pinned:       bool, // always-resident (the worldspace persistent cell); never unloaded/re-lod'd by the streamer
	instances:    [dynamic]Instance,
	terrain:      [dynamic]Terrain_Patch, // exterior LAND heightmap patches (one per quadrant)
	grass:        [dynamic]Grass_Batch, // scattered grass (one batch per grass type)
	objects:      [dynamic]Obj_Batch, // distant instanced statics (lod ≥ 1; one batch per model)
	water:        render.Mesh, // flat per-cell water plane (zero mesh = none); see water.odin
	has_water:    bool,
	lo, hi:       smath.Vec3, // world-space culling bounds (incl. terrain footprint)
}

// Scene is the loaded world: chunks keyed by cell formID + the asset cache.
Scene :: struct {
	cache:    assetdb.Cache,
	chunks:   map[u32]Chunk,
	lo, hi:   smath.Vec3, // overall AABB of placed refs (spawn framing)
	sel_cell: u32, // selected instance's chunk (0 = none)
	sel_inst: int,
	has_sel:  bool,
	hover_cell: u32, // instance under the cursor this frame (inspect mode)
	hover_inst: int,
	has_hover:  bool,
	last_land_tex: render.Texture, // most recently resolved ground texture (terrain fallback)
	far:      [dynamic]Far_Block, // whole-world coarse terrain backdrop (always resident)
}

scene_init :: proc(r: ^render.Renderer, v: ^vfs.VFS) -> Scene {
	return Scene {
		cache = assetdb.cache_init(r, v),
		chunks = make(map[u32]Chunk),
		lo = {max(f32), max(f32), max(f32)},
		hi = {min(f32), min(f32), min(f32)},
	}
}

scene_destroy :: proc(s: ^Scene) {
	release_far_terrain(s)
	for _, &chunk in s.chunks {
		release_terrain(s, &chunk)
		release_grass(s, &chunk)
		release_objects(s, &chunk)
		release_water(s, &chunk)
		delete(chunk.instances)
	}
	delete(s.chunks)
	assetdb.cache_destroy(&s.cache)
	s^ = {}
}

// chunk_meta makes an empty chunk carrying just a cell's identity + grid (no instances,
// no terrain). Used directly for distant terrain-only LOD chunks; the base of build_chunk.
chunk_meta :: proc(db: ^gamedb.DB, cell_form_id: u32) -> Chunk {
	chunk := Chunk {
		cell_form_id = cell_form_id,
	}
	if c, ok := gamedb.cell_by_formid(db, cell_form_id); ok {
		chunk.gx, chunk.gy, chunk.has_grid = c.gx, c.gy, c.has_grid
	}
	return chunk
}

// build_chunk gathers a cell's placeable refs into a chunk (instances + culling
// bounds), WITHOUT resolving/uploading models (model stays nil). Cheap, main-thread:
// no IO, no GPU. Shared by the sync loaders and the streamer.
build_chunk :: proc(db: ^gamedb.DB, cell_form_id: u32) -> Chunk {
	chunk := chunk_meta(db, cell_form_id)
	lo := smath.Vec3{max(f32), max(f32), max(f32)}
	hi := smath.Vec3{min(f32), min(f32), min(f32)}
	for r in gamedb.refs_of(db, cell_form_id) {
		if r.disabled || r.base == XMARKER || r.base == XMARKER_HEADING {
			continue
		}
		modl, ok := gamedb.model_of(db, r.base)
		if !ok || modl == "" || is_marker_path(modl) || is_nonworld_path(modl) {
			continue
		}
		append(
			&chunk.instances,
			Instance {
				model_path = modl,
				base = r.base,
				pos = r.pos,
				rot = r.rot,
				scale = r.scale,
				has_tp = r.has_tp,
				tp_door = r.teleport.door,
				tp_pos = r.teleport.pos,
				tp_rot = r.teleport.rot,
			},
		)
		lo = {min(lo.x, r.pos.x), min(lo.y, r.pos.y), min(lo.z, r.pos.z)}
		hi = {max(hi.x, r.pos.x), max(hi.y, r.pos.y), max(hi.z, r.pos.z)}
	}
	if len(chunk.instances) > 0 {
		m := smath.Vec3{CHUNK_MARGIN, CHUNK_MARGIN, CHUNK_MARGIN}
		chunk.lo, chunk.hi = lo - m, hi + m
	}
	return chunk
}

// load_cell loads one cell synchronously (build + resolve every model via get_model)
// and inserts it as a chunk. Returns the instance count. Used for interiors and the
// bounded Whiterun load — NOT the streamer (which decodes off-thread).
load_cell :: proc(s: ^Scene, db: ^gamedb.DB, cell_form_id: u32) -> int {
	chunk := build_chunk(db, cell_form_id)
	for &inst in chunk.instances {
		if m, ok := assetdb.get_model(&s.cache, inst.model_path); ok {
			inst.model = m
		}
	}
	expand_scene_bounds(s, chunk)
	load_terrain(s, db, &chunk)
	load_water(s, db, &chunk)
	load_grass(s, db, &chunk)
	n := len(chunk.instances)
	s.chunks[cell_form_id] = chunk
	return n
}

// load_worldspace loads every cell of a bounded exterior worldspace (e.g.
// WhiterunWorld) synchronously, as chunks. Returns the total instance count.
load_worldspace :: proc(s: ^Scene, db: ^gamedb.DB, world_form_id: u32) -> int {
	cells := gamedb.cells_of(db, world_form_id)
	total := 0
	for cid in cells {
		total += load_cell(s, db, cid)
	}
	log.infof("world: worldspace 0x%08X → %d cells, %d instances", world_form_id, len(cells), total)
	return total
}

@(private)
expand_scene_bounds :: proc(s: ^Scene, chunk: Chunk) {
	if len(chunk.instances) == 0 {
		return
	}
	for inst in chunk.instances {
		s.lo = {min(s.lo.x, inst.pos.x), min(s.lo.y, inst.pos.y), min(s.lo.z, inst.pos.z)}
		s.hi = {max(s.hi.x, inst.pos.x), max(s.hi.y, inst.pos.y), max(s.hi.z, inst.pos.z)}
	}
}

// spawn returns a sensible camera start: the AABB centre raised toward the top.
// ok=false if nothing was placed.
spawn :: proc(s: ^Scene) -> (pos: smath.Vec3, ok: bool) {
	if len(s.chunks) == 0 || s.hi.z < s.lo.z {
		return {}, false
	}
	c := smath.scale3(s.lo + s.hi, 0.5)
	c.z = s.lo.z + (s.hi.z - s.lo.z) * 0.6
	return c, true
}

// draw renders every visible instance with the camera view-projection `vp`. Culls
// whole chunks against the frustum, then individual instances by bounding sphere.
// Resolves each instance's model lazily (skips ones not yet uploaded by the streamer).
// `wind`/`time` drive the vegetation sway (trees + foliage); rigid statics pass strength 0.
draw :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, wind: render.Wind = {}, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	for _, &chunk in s.chunks {
		if !smath.aabb_in_frustum(f, chunk.lo, chunk.hi) {
			continue
		}
		// Terrain: verts are already world-space, so model = identity (shader mvp = vp).
		// Each quadrant patch carries its own base diffuse (white fallback if unresolved).
		for p in chunk.terrain {
			render.draw_mesh(r, p.mesh, vp, smath.Mat4(1), LIGHT_DIR, p.tex)
		}
		for &inst in chunk.instances {
			if inst.vis != .Show {
				continue // hidden / shadow-only (open-interiors shell clip) — no color draw
			}
			if inst.model == nil {
				inst.model = assetdb.model_ptr(&s.cache, inst.model_path)
				if inst.model == nil {
					continue // not streamed in yet
				}
			}
			world := smath.trs(inst.pos, inst.rot, inst.scale)
			cw := world * [4]f32{inst.model.center.x, inst.model.center.y, inst.model.center.z, 1}
			if !smath.sphere_in_frustum(f, {cw.x, cw.y, cw.z}, inst.model.radius * inst.scale) {
				continue
			}
			// One global wind direction; per-vegetation amplitude+speed+cap, per-placement phase.
			iw := veg_wind(inst.model_path, wind)
			phase := veg_phase(inst.pos)
			for sh in inst.model.shapes {
				if sh.is_effect {
					continue // ghosted in the translucent draw_effects pass
				}
				model := world * sh.local
				render.draw_mesh(
					r,
					sh.mesh,
					vp,
					model,
					LIGHT_DIR,
					sh.tex,
					sh.alpha_cutoff,
					wind = iw,
					time = time,
					phase = phase,
				)
			}
		}
	}
}

// draw_effects draws the ADDITIVE effect shapes (BSEffectShaderProperty FX: flowing water,
// fire, light beams) — a separate pass AFTER all opaque geometry so they blend over the
// scene. Same frustum/instance traversal as draw, but only the effect shapes (which draw
// skips). `time` drives each shape's controller-derived UV scroll (the flow/beam motion).
draw_effects :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	for _, &chunk in s.chunks {
		if !smath.aabb_in_frustum(f, chunk.lo, chunk.hi) {
			continue
		}
		for &inst in chunk.instances {
			if inst.vis != .Show {
				continue // hidden / shadow-only (open-interiors shell clip)
			}
			if inst.model == nil {
				inst.model = assetdb.model_ptr(&s.cache, inst.model_path)
				if inst.model == nil {
					continue
				}
			}
			world := smath.trs(inst.pos, inst.rot, inst.scale)
			cw := world * [4]f32{inst.model.center.x, inst.model.center.y, inst.model.center.z, 1}
			if !smath.sphere_in_frustum(f, {cw.x, cw.y, cw.z}, inst.model.radius * inst.scale) {
				continue
			}
			for sh in inst.model.shapes {
				if !sh.is_effect {
					continue
				}
				model := world * sh.local
				render.draw_effect(r, sh.mesh, vp, model, sh.tex, sh.scroll, time)
			}
		}
	}
}

// draw_highlight overdraws the hovered instance's shapes in the highlight colour (a
// separate pass, after the opaque geometry) so the user sees exactly what a click will
// select. Uses the SAME wind/phase as draw so the highlight tracks a swaying tree. No-op
// when nothing is hovered. `wind`/`time` must match the draw pass.
draw_highlight :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, wind: render.Wind = {}, time: f32 = 0) {
	if !s.has_hover {
		return
	}
	chunk, ok := &s.chunks[s.hover_cell]
	if !ok || s.hover_inst < 0 || s.hover_inst >= len(chunk.instances) {
		return
	}
	inst := &chunk.instances[s.hover_inst]
	if inst.model == nil {
		return
	}
	world := smath.trs(inst.pos, inst.rot, inst.scale)
	iw := veg_wind(inst.model_path, wind)
	phase := veg_phase(inst.pos)
	for sh in inst.model.shapes {
		model := world * sh.local
		render.draw_highlight(r, sh.mesh, vp, model, LIGHT_DIR, sh.tex, sh.alpha_cutoff, iw, time, phase)
	}
}

// pick_nearest ray-casts (origin + t·dir, dir normalized) against loaded instances and
// returns the nearest hit's chunk + index, by PRECISE ray-vs-FACE — so small detail
// meshes and foliage are selectable, not just whatever has the biggest bounding sphere.
// Three phases per instance: a cheap world-sphere reject (no matrix), then transform the
// ray into the instance's local space and reject against the tight model AABB, then
// Möller-Trumbore over the model's triangles. `t` is world distance throughout (the
// local ray is scaled so it stays comparable). Pure query — mutates nothing.
@(private)
pick_nearest :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (cell: u32, idx: int, shape: int, ok: bool) {
	best_cell: u32
	best_inst := -1
	best_shape := -1
	best_t := max(f32)
	for cid, &chunk in s.chunks {
		for inst, ii in chunk.instances {
			m := inst.model
			if m == nil || len(m.pick_idx) == 0 {
				continue
			}
			// Cheap broad reject: a conservative world sphere around the instance origin
			// (radius covers the off-origin model centre), no matrix build.
			rad := (m.radius + smath.length3(m.center)) * inst.scale
			oc := inst.pos - origin
			tca := smath.dot3(oc, dir)
			if tca < -rad {
				continue // entirely behind the eye
			}
			if smath.dot3(oc, oc) - tca * tca > rad * rad {
				continue // ray misses the bounding sphere
			}
			// Transform the ray into the instance's local (model) space.
			lo_o, ld := ray_to_local(inst.pos, inst.rot, inst.scale, origin, dir)
			if tb, hit := ray_aabb(lo_o, ld, m.lo, m.hi); !hit || tb >= best_t {
				continue
			}
			// Precise: nearest front-facing triangle.
			for i := 0; i + 2 < len(m.pick_idx); i += 3 {
				a := m.pick_pos[m.pick_idx[i]]
				b := m.pick_pos[m.pick_idx[i + 1]]
				c := m.pick_pos[m.pick_idx[i + 2]]
				if t, hit := ray_triangle(lo_o, ld, a, b, c); hit && t < best_t {
					best_t = t
					best_cell, best_inst = cid, ii
					best_shape = int(m.pick_shape[i / 3]) if i / 3 < len(m.pick_shape) else -1
				}
			}
		}
	}
	if best_inst < 0 {
		return 0, -1, -1, false
	}
	return best_cell, best_inst, best_shape, true
}

// ray_to_local maps a world ray into the local space of a trs(pos,rot,scale) placement.
// trs = translate · transpose(Rz·Ry·Rx) · scale, so the inverse rotation is (Rz·Ry·Rx)
// and the inverse is (1/scale)·that·(p − pos). The local dir is scaled by 1/scale too,
// which makes the intersection t come out in WORLD units (the scale cancels against the
// placement on the way back out) — so hits are comparable across differently-scaled refs.
@(private)
ray_to_local :: proc(pos, rot: smath.Vec3, scale: f32, o, d: smath.Vec3) -> (lo_o, ld: smath.Vec3) {
	inv := 1.0 / scale if scale != 0 else 1.0
	a := smath.rotate_z(rot.z) * smath.rotate_y(rot.y) * smath.rotate_x(rot.x)
	rel := o - pos
	ro := a * [4]f32{rel.x, rel.y, rel.z, 0}
	rd := a * [4]f32{d.x, d.y, d.z, 0}
	return {ro.x, ro.y, ro.z} * inv, {rd.x, rd.y, rd.z} * inv
}

// ray_aabb slab test. Returns the entry distance (negative if the origin is inside) and
// whether the ray meets the box at all (in front of, or surrounding, the origin).
@(private)
ray_aabb :: proc(o, d, lo, hi: smath.Vec3) -> (t: f32, hit: bool) {
	tmin := -max(f32)
	tmax := max(f32)
	for i in 0 ..< 3 {
		if abs(d[i]) < 1e-9 {
			if o[i] < lo[i] || o[i] > hi[i] {
				return 0, false // parallel and outside this slab
			}
		} else {
			inv := 1.0 / d[i]
			t1 := (lo[i] - o[i]) * inv
			t2 := (hi[i] - o[i]) * inv
			if t1 > t2 {t1, t2 = t2, t1}
			tmin = max(tmin, t1)
			tmax = min(tmax, t2)
			if tmin > tmax {
				return 0, false
			}
		}
	}
	if tmax < 0 {
		return 0, false // box entirely behind the origin
	}
	return tmin, true
}

// ray_triangle: Möller-Trumbore, two-sided (meshes draw with cull_mode NONE). Returns the
// forward hit distance, or hit=false on a miss / parallel / behind-the-origin.
@(private)
ray_triangle :: proc(o, d, v0, v1, v2: smath.Vec3) -> (t: f32, hit: bool) {
	EPS :: f32(1e-7)
	e1 := v1 - v0
	e2 := v2 - v0
	p := smath.cross3(d, e2)
	det := smath.dot3(e1, p)
	if abs(det) < EPS {
		return 0, false // ray parallel to the triangle
	}
	inv := 1.0 / det
	tv := o - v0
	u := smath.dot3(tv, p) * inv
	if u < 0 || u > 1 {
		return 0, false
	}
	q := smath.cross3(tv, e1)
	v := smath.dot3(d, q) * inv
	if v < 0 || u + v > 1 {
		return 0, false
	}
	t = smath.dot3(e2, q) * inv
	if t <= EPS {
		return 0, false // behind the origin
	}
	return t, true
}

// pick selects the nearest instance along the ray (for the Inspector). Returns the instance
// and the index of the SHAPE the ray hit (-1 if unknown). ok=false on a miss.
pick :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (inst: ^Instance, shape: int, ok: bool) {
	cell, idx, shp, hit := pick_nearest(s, origin, dir)
	if !hit {
		s.has_sel = false
		return nil, -1, false
	}
	s.sel_cell, s.sel_inst, s.has_sel = cell, idx, true
	chunk := &s.chunks[cell]
	return &chunk.instances[idx], shp, true
}

// hover_pick records the nearest instance along the ray as the HOVERED one (cursor inspect
// mode) without changing the selection. Returns the instance + the hit SHAPE index (-1 if
// unknown). ok=false on a miss (clears the hover). The hovered instance is drawn highlighted.
hover_pick :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (inst: ^Instance, shape: int, ok: bool) {
	cell, idx, shp, hit := pick_nearest(s, origin, dir)
	if !hit {
		s.has_hover = false
		return nil, -1, false
	}
	s.hover_cell, s.hover_inst, s.has_hover = cell, idx, true
	chunk := &s.chunks[cell]
	return &chunk.instances[idx], shp, true
}

// clear_hover drops the hover highlight (call when inspect mode is off).
clear_hover :: proc(s: ^Scene) {
	s.has_hover = false
}

// select_instance promotes the currently-hovered instance to the selection (on click).
select_instance :: proc(s: ^Scene) {
	if s.has_hover {
		s.sel_cell, s.sel_inst, s.has_sel = s.hover_cell, s.hover_inst, true
	}
}

// nearest_door returns the closest load-door instance (has a teleport) to `pos` and
// its distance, or ok=false if the scene has no doors. Doors don't need a loaded model.
nearest_door :: proc(s: ^Scene, pos: smath.Vec3) -> (door: ^Instance, dist: f32, ok: bool) {
	best: ^Instance
	best_d := max(f32)
	for _, &chunk in s.chunks {
		for &inst in chunk.instances {
			if !inst.has_tp {
				continue
			}
			d := smath.length3(inst.pos - pos)
			if d < best_d {
				best_d = d
				best = &inst
			}
		}
	}
	if best == nil {
		return nil, 0, false
	}
	return best, best_d, true
}

// selected returns the currently-selected instance, if any.
selected :: proc(s: ^Scene) -> (^Instance, bool) {
	if !s.has_sel {
		return nil, false
	}
	chunk, ok := &s.chunks[s.sel_cell]
	if !ok || s.sel_inst < 0 || s.sel_inst >= len(chunk.instances) {
		return nil, false
	}
	return &chunk.instances[s.sel_inst], true
}
