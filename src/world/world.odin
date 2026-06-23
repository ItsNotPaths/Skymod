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
import "core:math"
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

// is_marker_path reports whether a model is an invisible editor helper (dragon-landing,
// critter/bird-path, link/civil-war markers, etc.) that shouldn't render in-game. Skyrim
// names all such meshes with "marker" in the path; "market" doesn't contain "marker", so
// this is safe. (XMarker/XMarkerHeading base forms are also skipped by formID.)
is_marker_path :: proc(modl: string) -> bool {
	return strings.contains(strings.to_lower(modl, context.temp_allocator), "marker")
}

// CELL_SIZE is the side of one exterior cell in world units.
CELL_SIZE :: f32(4096)

// Conservative half-extent added to a chunk's instance-position bounds so culling
// never clips a tall/wide mesh whose origin sits near a cell edge.
CHUNK_MARGIN :: f32(4096)

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
	tp_door:    u32,
}

// Chunk is one loaded cell's instances + a culling AABB. Exterior cells carry their
// grid coordinate and detail level (lod 0 = full; higher reserved for Section-F LOD).
Chunk :: struct {
	cell_form_id: u32,
	gx, gy:       i32,
	has_grid:     bool,
	lod:          int,
	instances:    [dynamic]Instance,
	terrain:      [dynamic]Terrain_Patch, // exterior LAND heightmap patches (one per quadrant)
	grass:        [dynamic]Grass_Batch, // scattered grass (one batch per grass type)
	objects:      [dynamic]Obj_Batch, // distant instanced statics (lod ≥ 1; one batch per model)
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
		if !ok || modl == "" || is_marker_path(modl) {
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
draw :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4) {
	f := smath.frustum_from_vp(vp)
	for _, &chunk in s.chunks {
		if !smath.aabb_in_frustum(f, chunk.lo, chunk.hi) {
			continue
		}
		// Terrain: verts are already world-space, so model = identity and mvp = vp. Each
		// quadrant patch carries its own base diffuse (white fallback if unresolved).
		for p in chunk.terrain {
			render.draw_mesh(r, p.mesh, vp, smath.Mat4(1), LIGHT_DIR, p.tex)
		}
		for &inst in chunk.instances {
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
			for sh in inst.model.shapes {
				if sh.is_effect {
					continue // ghosted in the translucent draw_effects pass
				}
				model := world * sh.local
				render.draw_mesh(r, sh.mesh, vp * model, model, LIGHT_DIR, sh.tex, sh.alpha_cutoff)
			}
		}
	}
}

// draw_effects draws the GHOSTED (translucent ~40%) effect shapes — a separate pass AFTER
// all opaque geometry so they blend over the scene. Same frustum/instance traversal as
// draw, but only the BSEffectShaderProperty shapes (which draw skips).
draw_effects :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4) {
	f := smath.frustum_from_vp(vp)
	for _, &chunk in s.chunks {
		if !smath.aabb_in_frustum(f, chunk.lo, chunk.hi) {
			continue
		}
		for &inst in chunk.instances {
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
				render.draw_effect(r, sh.mesh, vp * model, model, LIGHT_DIR, sh.tex)
			}
		}
	}
}

// pick ray-casts (origin + t·dir, dir normalized) against loaded instance bounding
// spheres and selects the nearest hit. Returns the chosen instance, or ok=false on a
// miss. Instances not yet streamed in (nil model) are not pickable.
pick :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (^Instance, bool) {
	best_cell: u32
	best_inst := -1
	best_t := max(f32)
	for cid, &chunk in s.chunks {
		for inst, ii in chunk.instances {
			if inst.model == nil {
				continue
			}
			world := smath.trs(inst.pos, inst.rot, inst.scale)
			cw := world * [4]f32{inst.model.center.x, inst.model.center.y, inst.model.center.z, 1}
			center := smath.Vec3{cw.x, cw.y, cw.z}
			radius := inst.model.radius * inst.scale
			if t, hit := ray_sphere(origin, dir, center, radius); hit && t < best_t {
				best_t = t
				best_cell, best_inst = cid, ii
			}
		}
	}
	if best_inst < 0 {
		s.has_sel = false
		return nil, false
	}
	s.sel_cell, s.sel_inst, s.has_sel = best_cell, best_inst, true
	chunk := &s.chunks[best_cell]
	return &chunk.instances[best_inst], true
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

@(private)
ray_sphere :: proc(origin, dir, center: smath.Vec3, radius: f32) -> (t: f32, hit: bool) {
	oc := origin - center
	b := smath.dot3(oc, dir)
	c := smath.dot3(oc, oc) - radius * radius
	disc := b * b - c
	if disc < 0 {
		return 0, false
	}
	root := math.sqrt(disc)
	t0 := -b - root
	if t0 >= 0 {
		return t0, true
	}
	t1 := -b + root
	if t1 >= 0 {
		return t1, true
	}
	return 0, false
}
