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

