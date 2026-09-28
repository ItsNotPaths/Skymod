package world

// World-state overlay glue (ROADMAP Phase 3c). The streamer renders each cell as "baseline ⊕
// overlay": apply_overlay patches freshly-built instances with their worldstate delta, and
// capture_settles writes deltas back when physics brings a moved clutter body to rest. The overlay
// itself (the FormID→delta store) lives in package worldstate; this file is the world↔overlay
// bridge — the only place that knows both Instances and deltas. No-op unless a Scene borrows a ^ws.

import "core:log"

import "../assetdb"
import "../formid"
import "../gamedb"
import smath "../math"
import "../physics"
import "../worldstate"

// --- resident-instance index (Layer-1 live-apply support; docs/live-state.md §7.1) ---

// index_instances records a freshly-finalised chunk's instances into the resident index (formID ->
// location). Best-effort: the index is a self-healing CACHE (find_resident validates + scans on a
// miss), so a skipped call costs a later scan, never correctness. Call once a chunk's instances are
// final (after build + insert into s.chunks). formID 0 (markerless/synthetic) is skipped.
index_instances :: proc(s: ^Scene, chunk: ^Chunk) {
	for inst, i in chunk.instances {
		if inst.form_id == 0 {
			continue
		}
		s.resident[inst.form_id] = Resident_Ref{cell = chunk.cell_form_id, idx = i}
	}
}

// deindex_instances drops a chunk's entries from the resident index on unload. Best-effort hygiene
// (keeps the map from accumulating stale keys over a long session); find_resident self-heals if a
// site is missed. Call before freeing the chunk's instances array.
deindex_instances :: proc(s: ^Scene, chunk: ^Chunk) {
	for inst in chunk.instances {
		if inst.form_id != 0 {
			delete_key(&s.resident, inst.form_id)
		}
	}
}

// find_resident returns the live Instance (and its owning chunk) for `form_id` if its cell is
// currently loaded. It trusts the index only after validating the hit (the chunk is still resident
// and the slot still holds this formID); on a stale or missing entry it scans every chunk and
// repopulates. So the index is purely an optimisation — correctness holds even if load/unload upkeep
// is imperfect. The chunk is returned so callers can reach chunk.bodies (live collision removal).
find_resident :: proc(s: ^Scene, form_id: Form_ID) -> (inst: ^Instance, chunk: ^Chunk, ok: bool) {
	if form_id == 0 {
		return nil, nil, false
	}
	if loc, hit := s.resident[form_id]; hit {
		if c, cok := &s.chunks[loc.cell]; cok && loc.idx >= 0 && loc.idx < len(c.instances) {
			if in_ := &c.instances[loc.idx]; in_.form_id == form_id {
				return in_, c, true
			}
		}
	}
	// Miss or stale — authoritative scan, then cache the location for next time.
	for cid, &c in s.chunks {
		for &in_, i in c.instances {
			if in_.form_id == form_id {
				s.resident[form_id] = Resident_Ref{cell = cid, idx = i}
				return &in_, &c, true
			}
		}
	}
	return nil, nil, false
}

// MOVE_EPS is the minimum distance (world units) a clutter body must drift from its build position
// before a settle is worth a delta — so clutter that loads already at rest doesn't spam the overlay
// with no-op "moves".
MOVE_EPS :: f32(2)

// disable_ref is the Layer-1 mutation verb for Disabled (docs/live-state.md §7.1): it records a
// Disabled delta in the overlay (so it persists + reapplies via apply_overlay on the next cell load)
// AND, when the ref is currently resident, applies it live — the instance stops rendering AND loses
// its collision immediately (set_ref_disabled drops its bodies). Returns false if the scene has no
// overlay (nothing recorded). Re-enable (disabled=false) restores rendering and rebuilds collision.
disable_ref :: proc(s: ^Scene, form_id, cell: Form_ID, disabled: bool) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_disabled(s.ws, form_id, cell, disabled)
	if inst, _, ok := find_resident(s, form_id); ok {
		inst.disabled = disabled
		inst.vis = .Hidden if disabled else .Show
	}
	set_ref_disabled(s.space, form_id, disabled)
	return true
}

// (hole instance-events :tags (threading world render) :sev gap :needs (render-chunk scene-ops-gpu)) scene ops change the shared chunks in the tick. Wanted: the sim applies them to its cells and publishes instance events (moved, disabled, spawned, removed) main applies to render chunks.
// apply_pending_scene_ops drains the worldstate deferred-apply queue and live-applies each change to
// THIS scene (docs/script-runtime-decisions.md §3 — the "one fixed frame point"). Script natives write
// the overlay synchronously (read-your-writes) but don't touch the live scene; this is what makes the
// change visible. Call once per frame on the active scene. No-op without an overlay / empty queue.
apply_pending_scene_ops :: proc(s: ^Scene, db: ^gamedb.DB) {
	if s.ws == nil {
		return
	}
	if len(s.ws.rebuild_cells) > 0 {
		for cell in s.ws.rebuild_cells {
			if chunk, ok := &s.chunks[cell]; ok {rebuild_chunk_overlay(s, db, cell, chunk)}
		}
		clear(&s.ws.rebuild_cells)
		resolve_created_models(s)
	}
	spawned := false
	for form in worldstate.pending_scene(s.ws) {
		spawned |= spawn_live(s, db, form) // a ref a script created (PlaceAtMe, DropObject)
		apply_overlay_ref(s, form)
		regate_enable(s, db, form)
	}
	if spawned {resolve_created_models(s)}
	worldstate.clear_scene_dirty(s.ws)
}

// regate_enable rebuilds the resident chunks an Enable/Disable changes beyond the ref's own
// instance: the ref itself when it was never built, and every ref below it in an enable chain.
@(private = "file")
regate_enable :: proc(s: ^Scene, db: ^gamedb.DB, form: Form_ID) {
	d, ok := worldstate.get(s.ws, form)
	if !ok || .Disabled not_in d.live {return}
	if r, known := gamedb.ref_by_formid(db, form); known && !d.disabled {
		if _, _, built := find_resident(s, form); !built {
			cell := gamedb.ref_attach_cell(db, r)
			if chunk, res := &s.chunks[cell]; res {rebuild_chunk_overlay(s, db, cell, chunk)}
		}
	}
	if form not_in db.enable_parents || s.space == nil {return}
	for cell, &c in s.space.cells {
		if chunk, res := &s.chunks[cell]; res && gated_by(s.space, db, &c, form) {rebuild_chunk_overlay(s, db, cell, chunk)}
	}
}

// apply_overlay_ref live-applies a single form's CURRENT overlay delta to the resident scene — the
// deferred sibling of the *_ref verbs, for deltas written straight to the overlay (script natives).
// It does NOT write the overlay (already written); it only reconciles the resident instance's render +
// collision with the recorded state. No-op if the form has no delta / isn't resident (a non-resident
// ref picks the delta up via apply_overlay when its cell next builds). Precedence mirrors apply_overlay.
apply_overlay_ref :: proc(s: ^Scene, form_id: Form_ID) {
	if s.ws == nil {
		return
	}
	d, ok := worldstate.get(s.ws, form_id)
	if !ok {
		return
	}
	// Deleted: remove the resident instance + its collision entirely.
	if .Deleted in d.live {
		if _, chunk, res := find_resident(s, form_id); res {
			for i in 0 ..< len(chunk.instances) {
				if chunk.instances[i].form_id == form_id {
					assetdb.model_release(&s.cache, chunk.instances[i].model_path) // D1: drop this ref's model ref
					unordered_remove(&chunk.instances, i)
					break
				}
			}
			delete_key(&s.resident, form_id)
			index_instances(s, chunk)
		}
		remove_ref(s.space, form_id)
		return
	}
	inst, _, res := find_resident(s, form_id)
	if !res {
		return
	}
	if .Disabled in d.live {
		inst.disabled = d.disabled
		inst.vis = .Hidden if d.disabled else .Show
		set_ref_disabled(s.space, form_id, d.disabled)
		if d.disabled {return} // a hidden ref ignores Moved/Scaled, as in apply_overlay
	}
	switch {
	case .Moved in d.live:
		inst.world, inst.pos = d.world, d.pos
	case .Scaled in d.live:
		inst.scale = d.scale
		inst.world = smath.trs(inst.pos, inst.rot, d.scale)
	case:
		return
	}
	place_ref(s.space, form_id, inst.world, inst.pos, inst.scale)
}

// rebuild_resident_overlay recomputes every resident chunk's refs as baseline ⊕ overlay from a
// clean baseline, so every delta kind (created refs added or gone, disabled/moved/scaled set or
// dropped by a loaded save) falls out with no per-field reset. Terrain, grass, water and the terrain
// body stay. GPU-free. Call after an overlay LOAD.
rebuild_resident_overlay :: proc(s: ^Scene, db: ^gamedb.DB) {
	if s.ws == nil {
		return
	}
	for cid, &chunk in s.chunks {
		rebuild_chunk_overlay(s, db, cid, &chunk)
	}
}

// (hole rebuild-evict-reacquire :tags (assets world) :sev gap) the old models are released before the new ones are acquired, so with an eviction budget trim can evict a model the rebuilt chunk needs, and nothing loads it again: the ref stays invisible with no collision. Acquire first.
// (hole release-from-tick :tags (threading assets) :sev gap :needs (instance-events)) model_release (and so trim and evict_model, which free GPU buffers) runs in the tick through scene ops. Wanted: all cache refcounting on main, driven by instance events.
// rebuild_chunk_overlay rebuilds one resident cell in the sim and redraws the chunk from it. The
// chunk's bounds stay (they cover its terrain). Model refs are released over the old instances and
// acquired over the new ones, or eviction could never reclaim them.
rebuild_chunk_overlay :: proc(s: ^Scene, db: ^gamedb.DB, cell: Form_ID, chunk: ^Chunk) {
	for &inst in chunk.instances {
		assetdb.model_release(&s.cache, inst.model_path)
	}
	deindex_instances(s, chunk)
	clear(&chunk.instances)
	if c, live := rebuild_cell(s.space, db, cell); live {
		for r in c.refs {append(&chunk.instances, instance_of(r))}
	}
	for inst in chunk.instances {
		assetdb.model_acquire(&s.cache, inst.model_path)
	}
	index_instances(s, chunk)
}

// (hole scene-ops-gpu :tags (threading world assets) :sev gap) apply_pending_scene_ops runs in the tick and this decodes and uploads a model synchronously; the model resolve must move to main.
// resolve_created_models synchronously resolves the model for every resident CREATED ref whose model
// isn't loaded yet (created refs aren't enqueued by the streamer, so they'd never draw otherwise).
// The GPU half of an overlay re-apply; kept separate from reconcile_overlay so that stays testable.
resolve_created_models :: proc(s: ^Scene) {
	for _, &chunk in s.chunks {
		for &inst in chunk.instances {
			if inst.model == nil && inst.form_id >= formid.CREATED_FORM_BASE {
				if m, ok := assetdb.get_model(&s.cache, inst.model_path); ok {
					inst.model = m
				}
			}
		}
	}
}

// reapply_overlay_resident = rebuild (baseline ⊕ overlay, GPU-free logic) + resolve (GPU model decode
// for created refs). Called after an overlay LOAD (Continue / F9) so the loaded state lands on chunks
// already resident (built before the menu's Continue and not reloaded on the crossing).
reapply_overlay_resident :: proc(s: ^Scene, db: ^gamedb.DB) {
	rebuild_resident_overlay(s, db)
	resolve_created_models(s)
}

// create_ref is the Layer-1 spawn verb: mints a runtime ref (worldstate) and, when its cell is
// resident, spawns the Instance live — appended to the chunk, model resolved here, collision built by
// sync_physics next tick. Returns the new FormID (0 if no overlay / the base has no world model).
create_ref :: proc(s: ^Scene, db: ^gamedb.DB, base, cell: Form_ID, pos, rot: [3]f32, scale: f32) -> Form_ID {
	if s.ws == nil {
		return 0
	}
	id := worldstate.create_ref(s.ws, base, cell, pos, rot, scale)
	if spawn_live(s, db, id) {resolve_created_models(s)}
	return id
}

// spawn_live adds a created ref to its cell's chunk when that chunk is resident and the ref is not
// yet live. GPU-free: the caller resolves the model (resolve_created_models); sync_physics builds
// its collision next tick.
spawn_live :: proc(s: ^Scene, db: ^gamedb.DB, id: Form_ID) -> bool {
	r, cell, ok := spawn_ref(s.space, db, id) // sync_physics builds its collision
	if !ok {return false}
	chunk, resident := &s.chunks[cell]
	if !resident {return false}
	inst := instance_of(r)
	assetdb.model_acquire(&s.cache, inst.model_path) // D1: pin — released when the chunk unloads
	append(&chunk.instances, inst) // may realloc the array — re-index below; no ^Instance held
	index_instances(s, chunk)
	return true
}

// capture_settles writes a debounced Moved delta for every movable-clutter body that JUST came to
// rest this frame (the active→asleep edge). Debounced by construction — fires only on settle, never
// per frame — mirroring why vanilla separates HAVOK_MOVE from MOVE. Bodies that barely moved from
// where they were built are skipped (MOVE_EPS), so a cell-load's settling clutter doesn't fill the
// overlay with no-op deltas. Call once per frame after physics.step. No-op without an overlay.
capture_settles :: proc(sp: ^Space) {
	if sp.ws == nil || sp.phys == nil {
		return
	}
	for _, &c in sp.cells {
		for &r in c.refs {
			if r.dyn_body == 0 {
				continue
			}
			act := physics.body_active(sp.phys, r.dyn_body)
			if r.dyn_active && !act {
				// Just settled — snapshot the resting placement as a Moved delta.
				m := physics.body_transform(sp.phys, r.dyn_body) * smath.translate(-r.pos) * r.world
				p := smath.Vec3{m[0, 3], m[1, 3], m[2, 3]}
				if smath.length3(p - r.pos) > MOVE_EPS {
					worldstate.set_moved(sp.ws, r.form_id, c.cell, m, p)
					log.infof(
						"overlay: ref 0x%08X settled at (%.0f, %.0f, %.0f) — %d delta(s)",
						r.form_id, p.x, p.y, p.z, worldstate.count(sp.ws),
					)
				}
			}
			r.dyn_active = act
		}
	}
}
