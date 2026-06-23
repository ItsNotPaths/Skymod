package world

// World / cell scene (ROADMAP Iteration 1 Milestone C; Section E exteriors). Turns
// gamedb REFR placements into drawable instances: resolve each ref's base → model
// path → load via assetdb (deduped) → place at the ref's transform (native Skyrim
// units). The static-model SKELETON — lighting/water/navmesh/actors/collision are
// out of scope. Markers and disabled refs are skipped.
//
// A Scene is a list of CHUNKS, one per loaded cell. An interior loads a single chunk;
// an exterior worldspace (e.g. WhiterunWorld) loads one chunk per cell. The chunk is
// the streaming/terrain unit: Section F (Riverwood / Tamriel) loads/unloads chunks by
// the player's grid position and hangs a LAND terrain mesh off each. Exterior REFRs
// already carry absolute worldspace coordinates, so placement is identical to
// interiors — gathering more cells is the only difference.
//
// Instances keep their RAW placement (pos/rot/scale); smath.trs bakes Skyrim's
// rotation convention (the transpose of RH Rz·Ry·Rx — pinned down with the inspector).

import "core:log"
import "core:math"

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

// Instance is one placed reference: a shared model + its raw REFR placement, plus a
// door teleport (tp_door = destination door REFR formID) if this is a load door.
Instance :: struct {
	model:   ^assetdb.Model,
	base:    u32,
	pos:     smath.Vec3,
	rot:     smath.Vec3, // XYZ euler radians (REFR DATA)
	scale:   f32,
	has_tp:  bool,
	tp_door: u32,
}

// Chunk is one loaded cell's drawable instances. Exterior cells carry their grid
// coordinate (each step = 4096 units); interiors have has_grid=false. The unit that
// streaming loads/unloads and that terrain attaches to.
Chunk :: struct {
	cell_form_id: u32,
	gx, gy:       i32,
	has_grid:     bool,
	instances:    [dynamic]Instance,
}

// Scene is the loaded world: its chunks + the asset cache backing them.
Scene :: struct {
	cache:     assetdb.Cache,
	chunks:    [dynamic]Chunk,
	lo, hi:    smath.Vec3, // world-space AABB of placed refs (for spawn framing)
	sel_chunk: int, // selected chunk index, or -1
	sel_inst:  int, // selected instance within sel_chunk
}

scene_init :: proc(r: ^render.Renderer, v: ^vfs.VFS) -> Scene {
	return Scene {
		cache = assetdb.cache_init(r, v),
		lo = {max(f32), max(f32), max(f32)},
		hi = {min(f32), min(f32), min(f32)},
		sel_chunk = -1,
		sel_inst = -1,
	}
}

scene_destroy :: proc(s: ^Scene) {
	for &chunk in s.chunks {
		delete(chunk.instances)
	}
	delete(s.chunks)
	assetdb.cache_destroy(&s.cache)
	s^ = {}
}

// load_cell appends one cell's refs to the scene as a new chunk. Returns the number
// of instances placed. Skips disabled refs, markers, and refs whose base has no
// model. Used for interiors (one chunk) and by load_worldspace (one chunk per cell).
load_cell :: proc(s: ^Scene, db: ^gamedb.DB, cell_form_id: u32) -> int {
	refs := gamedb.refs_of(db, cell_form_id)

	chunk := Chunk {
		cell_form_id = cell_form_id,
	}
	if c, ok := gamedb.cell_by_formid(db, cell_form_id); ok {
		chunk.gx, chunk.gy, chunk.has_grid = c.gx, c.gy, c.has_grid
	}

	skipped_marker, skipped_disabled, skipped_nomodel := 0, 0, 0
	for r in refs {
		if r.disabled {
			skipped_disabled += 1
			continue
		}
		if r.base == XMARKER || r.base == XMARKER_HEADING {
			skipped_marker += 1
			continue
		}
		modl, ok := gamedb.model_of(db, r.base)
		if !ok || modl == "" {
			skipped_nomodel += 1
			continue
		}
		model, mok := assetdb.get_model(&s.cache, modl)
		if !mok {
			skipped_nomodel += 1
			continue
		}
		append(
			&chunk.instances,
			Instance {
				model = model,
				base = r.base,
				pos = r.pos,
				rot = r.rot,
				scale = r.scale,
				has_tp = r.has_tp,
				tp_door = r.teleport.door,
			},
		)
		s.lo = {min(s.lo.x, r.pos.x), min(s.lo.y, r.pos.y), min(s.lo.z, r.pos.z)}
		s.hi = {max(s.hi.x, r.pos.x), max(s.hi.y, r.pos.y), max(s.hi.z, r.pos.z)}
	}

	n := len(chunk.instances)
	append(&s.chunks, chunk)
	log.debugf(
		"world: cell 0x%08X → %d instances (skipped %d marker, %d disabled, %d no-model)",
		cell_form_id,
		n,
		skipped_marker,
		skipped_disabled,
		skipped_nomodel,
	)
	return n
}

// load_worldspace loads every cell of an exterior worldspace (e.g. WhiterunWorld) as
// its own chunk. Returns the total instance count. For a bounded city this loads the
// whole thing; Section F windows this by grid for the open world.
load_worldspace :: proc(s: ^Scene, db: ^gamedb.DB, world_form_id: u32) -> int {
	cells := gamedb.cells_of(db, world_form_id)
	total := 0
	for cid in cells {
		total += load_cell(s, db, cid)
	}
	log.infof(
		"world: worldspace 0x%08X → %d cells, %d instances",
		world_form_id,
		len(cells),
		total,
	)
	return total
}

// spawn returns a sensible camera start: the AABB centre raised toward the top.
// ok=false if nothing was placed.
spawn :: proc(s: ^Scene) -> (pos: smath.Vec3, ok: bool) {
	if len(s.chunks) == 0 || s.hi.z < s.lo.z {
		return {}, false
	}
	c := smath.scale3(s.lo + s.hi, 0.5)
	c.z = s.lo.z + (s.hi.z - s.lo.z) * 0.6 // a little above mid-height
	return c, true
}

// draw renders every instance with the camera view-projection `vp`, building each
// world transform from its raw REFR placement.
draw :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4) {
	for chunk in s.chunks {
		for inst in chunk.instances {
			world := smath.trs(inst.pos, inst.rot, inst.scale)
			for sh in inst.model.shapes {
				model := world * sh.local
				render.draw_mesh(r, sh.mesh, vp * model, model, LIGHT_DIR, sh.tex)
			}
		}
	}
}

// pick ray-casts (origin + t·dir, dir normalized) against instance bounding spheres
// and selects the nearest hit. Sets the selection and returns the chosen instance, or
// ok=false if the ray missed everything.
pick :: proc(s: ^Scene, origin, dir: smath.Vec3) -> (^Instance, bool) {
	best_c, best_i := -1, -1
	best_t := max(f32)
	for chunk, ci in s.chunks {
		for inst, ii in chunk.instances {
			world := smath.trs(inst.pos, inst.rot, inst.scale)
			cw := world * [4]f32{inst.model.center.x, inst.model.center.y, inst.model.center.z, 1}
			center := smath.Vec3{cw.x, cw.y, cw.z}
			radius := inst.model.radius * inst.scale
			if t, hit := ray_sphere(origin, dir, center, radius); hit && t < best_t {
				best_t = t
				best_c, best_i = ci, ii
			}
		}
	}
	s.sel_chunk, s.sel_inst = best_c, best_i
	if best_c < 0 {
		return nil, false
	}
	return &s.chunks[best_c].instances[best_i], true
}

// nearest_door returns the closest load-door instance (has a teleport) to `pos` and
// its distance, or ok=false if the scene has no doors. The caller thresholds the
// distance to decide whether to show an activation prompt.
nearest_door :: proc(s: ^Scene, pos: smath.Vec3) -> (door: ^Instance, dist: f32, ok: bool) {
	best: ^Instance
	best_d := max(f32)
	for &chunk in s.chunks {
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
	if s.sel_chunk < 0 || s.sel_chunk >= len(s.chunks) {
		return nil, false
	}
	chunk := &s.chunks[s.sel_chunk]
	if s.sel_inst < 0 || s.sel_inst >= len(chunk.instances) {
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
