package world

// Distant static-object LOD (ROADMAP object-LOD tier 2). For LOD-ring cells (lod ≥ 1) we render
// the cell's statics as GPU instances of Skyrim's OWN prebaked LOD mesh (STAT MNAM, picked by
// distance band), one instanced draw per unique LOD mesh per cell — no runtime decimation. A ref
// whose base form has no MNAM LOD mesh is dropped (Skyrim-faithful: small clutter has no distant
// LOD). Larger objects are kept further out via the per-band OBND size cull. Trees lack MNAM and
// will come back as billboards (the far-far tier). Built/freed with the chunk, in-memory only.
//
// Decode runs on the MAIN thread here (assetdb.get_model, cached/deduped) — the first
// time a distant model is seen it can micro-hitch; revisits are free. Seam: route these
// decodes through the worker pipeline (as lod-0 objects already are) if it bites.

import "../assetdb"
import "../gamedb"
import smath "../math"
import "../render"
import "../vfs"
import "core:strings"

// OBJ_MIN_RADIUS is the minimum world bounding radius a static must have to appear at each LOD
// level (indexed by chunk.lod; lod 0 is the full path and unused here). Farther rings keep only
// larger objects, so distant clutter drops out. OBJ_LOD_FALLOFF scales all of it (the optional
// object_lod_falloff setting): >1 = drop more aggressively/fewer distant objects, <1 = keep more.
OBJ_MIN_RADIUS := [4]f32{0, 60, 150, 350}
OBJ_LOD_FALLOFF := f32(1.0)

// TREE_MIN_RADIUS / TREE_LOD_FALLOFF are the tree billboards' OWN size cull (trees are the cheap
// far-far tier and shouldn't inherit the heavier static thresholds, which left distant hills bare).
// More generous than OBJ_MIN_RADIUS so trees persist farther; indexed by chunk.lod like the statics.
// The optional tree_lod_falloff setting scales it (>1 = fewer/larger-only far trees, <1 = keep more).
// Tree REACH (how many cells out billboards load) is the separate tree_lod_distance / st.tree_radius.
TREE_MIN_RADIUS := [4]f32{0, 0, 30, 70}
TREE_LOD_FALLOFF := f32(1.0)

// Obj_Batch is one unique model's instances in a LOD cell: the per-cell placement buffer
// (chunk-owned, uploaded ONCE at cell load and reused every frame — distant statics never move)
// + the model referenced by PATH (borrowed from gamedb), resolved LAZILY at draw (nil until the
// streamer's worker has decoded+uploaded it). One instanced draw per shape per cell. Per-cell
// buffers (vs a per-frame re-merge) keep steady-state GPU work at ZERO — nothing the iGPU has to
// re-upload each frame — so a large LOD reach can't overload the driver.
Obj_Batch :: struct {
	model_path: string, // borrowed from gamedb (stable for the session)
	model:      ^assetdb.Model, // nil until resolved from the cache
	instances:  render.Obj_Instances, // per-cell instance buffer (built at load; released at unload)
	veg:        Veg_Kind, // cached vegetation class (path match done once at load)
}

// tree_billboard_for resolves a TREE base form to its prebaked distant billboard — Skyrim's flat
// _lod_flat.nif that sits BESIDE the full mesh (same dir, _lod_flat before the extension):
// Landscape\Trees\TreePineForest03.nif → Landscape\Trees\TreePineForest03_lod_flat.nif. The NIF is
// UV-mapped into its worldspace tree atlas, which it references internally (so no atlas handling
// here). TREEs carry no MNAM, so the billboard IS their distant-LOD mesh; it flows through the same
// Obj_Batch path (double-sided, alpha-tested, tree-wind sway via veg_classify). Only the ~35 LOD
// trees ship one; flora/shrubs have none → drop at distance (Skyrim-faithful). Result cached per
// base ("" = none). Scene-owned, freed on worldspace change. Placement stays per-REFR (the
// streamer); the .lst/.btt atlas system is unused.
tree_billboard_for :: proc(s: ^Scene, db: ^gamedb.DB, base: Form_ID) -> (string, bool) {
	if !gamedb.is_tree(db, base) {
		return "", false
	}
	if p, seen := s.tree_billboards[base]; seen {
		return p, p != "" // cached (positive path or a known-missing "")
	}
	resolved := ""
	if modl, ok := gamedb.model_of(db, base); ok {
		if len(modl) >= 4 && strings.equal_fold(modl[len(modl) - 4:], ".nif") {
			path := strings.concatenate({modl[:len(modl) - 4], "_lod_flat.nif"})
			full := strings.concatenate({"meshes\\", path}, context.temp_allocator)
			if vfs.exists(s.cache.v, full) {
				resolved = path // present — keep (scene-owned, freed in clear_tree_billboards)
			} else {
				delete(path)
			}
		}
	}
	s.tree_billboards[base] = resolved
	return resolved, resolved != ""
}

// clear_tree_billboards frees the scene-owned billboard path strings + resets the cache (called on
// worldspace change / teardown).
clear_tree_billboards :: proc(s: ^Scene) {
	for _, p in s.tree_billboards {
		if p != "" {
			delete(p)
		}
	}
	clear(&s.tree_billboards)
}

// load_objects_lod scatters a distant cell's larger statics into per-model instance
// batches. MAIN THREAD but CHEAP: it only gathers refs + uploads the small instance
// buffers; the models themselves are decoded off-thread (the streamer enqueues their
// paths and they resolve lazily at draw). No-op for lod 0 (the full path handles those).
// Folds object extents into the chunk AABB.
load_objects_lod :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk, dist, obj_radius, tree_radius: int) {
	if chunk.lod <= 0 {
		return
	}
	// Statics and tree billboards are SEPARATE tiers with independent reach + size cull. Statics
	// (MNAM) load within obj_radius; tree billboards (the cheap far-far tier) load within the
	// usually-larger tree_radius. A cell in the tree-only band loads billboards but no statics.
	load_statics := dist <= obj_radius
	load_trees := dist <= tree_radius
	obj_min := OBJ_MIN_RADIUS[min(chunk.lod, len(OBJ_MIN_RADIUS) - 1)] * OBJ_LOD_FALLOFF
	tree_min := TREE_MIN_RADIUS[min(chunk.lod, len(TREE_MIN_RADIUS) - 1)] * TREE_LOD_FALLOFF
	lod_idx := chunk.lod - 1 // ring lod 1 → MNAM slot 0 (LOD4) … coarser outward; lod_model_of clamps

	// Group placements by their PREBAKED LOD mesh (Skyrim's own MNAM low-poly model, or a tree's
	// _lod_flat billboard), one instanced batch per unique mesh. Refs with neither are dropped —
	// that's the Skyrim-faithful behaviour (small clutter has no distant LOD).
	by_model := make(map[string][dynamic]render.Obj_Instance, 32, context.temp_allocator)
	lo := smath.Vec3{max(f32), max(f32), max(f32)}
	hi := smath.Vec3{min(f32), min(f32), min(f32)}
	any := false
	for r in gamedb.refs_of(db, chunk.cell_form_id) {
		if gamedb.ref_effective_disabled(db, r) || r.base == XMARKER || r.base == XMARKER_HEADING {
			continue
		}
		min_r: f32
		lod_path, has_lod := gamedb.lod_model_of(db, r.base, lod_idx)
		if has_lod && !is_marker_path(lod_path) {
			if !load_statics {
				continue // a static beyond obj_radius (its band loads only trees)
			}
			min_r = obj_min
		} else {
			// No MNAM LOD mesh. TREEs fall back to their prebaked billboard (the far-far tier);
			// everything else (small clutter) drops, Skyrim-faithfully.
			if !load_trees {
				continue
			}
			bb, is_bb := tree_billboard_for(s, db, r.base)
			if !is_bb {
				continue
			}
			lod_path = bb
			min_r = tree_min
		}
		wr := gamedb.base_size(db, r.base) * r.scale
		if wr < min_r {
			continue // too small to matter at this distance
		}
		list, has := &by_model[lod_path]
		if !has {
			by_model[lod_path] = make([dynamic]render.Obj_Instance, 0, 16, context.temp_allocator)
			list = &by_model[lod_path]
		}
		append(list, render.Obj_Instance{world = smath.trs(r.pos, r.rot, r.scale)})
		lo = {min(lo.x, r.pos.x - wr), min(lo.y, r.pos.y - wr), min(lo.z, r.pos.z - wr)}
		hi = {max(hi.x, r.pos.x + wr), max(hi.y, r.pos.y + wr), max(hi.z, r.pos.z + wr)}
		any = true
	}
	if !any {
		return
	}

	for modl, list in by_model {
		if len(list) == 0 {
			continue
		}
		// Upload this cell's placements for the model ONCE; the buffer lives with the chunk and is
		// reused every frame (released at unload). No per-frame re-upload — static geometry is static.
		buf := render.upload_obj_instances(s.cache.r, list[:])
		append(&chunk.objects, Obj_Batch{model_path = modl, instances = buf, veg = veg_classify(modl)})
	}

	// Distant objects can be taller than the terrain — extend the chunk's cull AABB.
	chunk.lo = {min(chunk.lo.x, lo.x), min(chunk.lo.y, lo.y), min(chunk.lo.z, lo.z)}
	chunk.hi = {max(chunk.hi.x, hi.x), max(chunk.hi.y, hi.y), max(chunk.hi.z, hi.z)}
}

// lod_object_stats totals the loaded distant-object batches across resident chunks: how many
// instance batches exist and how many have their LOD mesh decoded+resolved (drawn). A diagnostic
// to tell "no LOD objects loaded" (settings/coverage) from "loaded but not drawn" (decode/render).
lod_object_stats :: proc(s: ^Scene) -> (batches, resolved: int) {
	for _, &chunk in s.chunks {
		for &b in chunk.objects {
			batches += 1
			if b.model != nil || assetdb.model_ptr(&s.cache, b.model_path) != nil {
				resolved += 1
			}
		}
	}
	return
}

// release_objects frees a chunk's per-cell object instance buffers (models are cache-owned).
release_objects :: proc(s: ^Scene, chunk: ^Chunk) {
	for b in chunk.objects {
		render.release_obj_instances(s.cache.r, b.instances)
	}
	delete(chunk.objects)
	chunk.objects = nil
}

// draw_objects draws every loaded LOD chunk's instanced distant objects from their persistent
// per-cell buffers, frustum-culled by chunk AABB. Iterates the flat per-frame chunk list
// (cull_begin) rather than the chunk MAP, so a huge resident window doesn't thrash cache. Nothing
// is gathered or uploaded here — the buffers were built at cell load and never change — so steady
// state is draw-only (no per-frame GPU upload, the thing that overloaded the iGPU). One instanced
// draw per shape per in-frustum cell. `wind`/`time`: same global sway as the near path.
draw_objects :: proc(s: ^Scene, r: ^render.Renderer, vp: smath.Mat4, wind: render.Wind = {}, time: f32 = 0) {
	f := smath.frustum_from_vp(vp)
	for vc in s.frame_chunks {
		if len(vc.c.objects) == 0 {
			continue
		}
		if !smath.aabb_in_frustum(f, vc.lo, vc.hi) {
			continue
		}
		for &b in vc.c.objects {
			if b.model == nil {
				b.model = assetdb.model_ptr(&s.cache, b.model_path)
				if b.model == nil {
					continue // not decoded yet — pops in when the worker delivers it
				}
			}
			bw := veg_wind_for(b.veg, wind) // amplitude+speed+cap by vegetation type (0 = rigid)
			for sh in b.model.shapes {
				// The mesh IS Skyrim's prebaked LOD model for this band — drawn whole (index_count 0).
				render.draw_obj(
					r,
					sh.mesh,
					b.instances,
					vp,
					sh.local,
					sh.tex,
					sh.alpha_cutoff,
					0,
					wind = bw,
					time = time,
					normal = sh.normal,
					mat = shape_mat(sh),
				)
			}
		}
	}
}
