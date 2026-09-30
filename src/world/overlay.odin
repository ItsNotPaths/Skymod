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
import "../models"
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
// Disabled delta in the overlay and applies it to the live ref, which loses its collision (or gets it
// back); render follows from the ref event. Returns false without an overlay.
disable_ref :: proc(sp: ^Space, form_id, cell: Form_ID, disabled: bool) -> bool {
	if sp.ws == nil {
		return false
	}
	worldstate.set_disabled(sp.ws, form_id, cell, disabled)
	set_ref_disabled(sp, form_id, disabled)
	return true
}

// apply_pending_scene_ops drains the worldstate deferred-apply queue into the live cells
// (docs/script-runtime-decisions.md §3 — the "one fixed frame point"). Script natives write the
// overlay synchronously (read-your-writes) but don't touch the live cells; this makes the change real,
// and its ref events make it visible. Call once per tick on the active space.
apply_pending_scene_ops :: proc(sp: ^Space, db: ^gamedb.DB) {
	if sp.ws == nil {
		return
	}
	for cell in sp.ws.rebuild_cells {rebuild_cell(sp, db, cell)}
	clear(&sp.ws.rebuild_cells)
	for form in worldstate.pending_scene(sp.ws) {
		spawn_ref(sp, db, form) // a ref a script created (PlaceAtMe, DropObject)
		apply_delta_live(sp, form)
		regate_enable(sp, db, form)
	}
	worldstate.clear_scene_dirty(sp.ws)
}

// regate_enable rebuilds the live cells an Enable/Disable changes beyond the ref's own placement:
// the ref's cell when it was never built, and every cell with a ref below it in an enable chain.
@(private = "file")
regate_enable :: proc(sp: ^Space, db: ^gamedb.DB, form: Form_ID) {
	d, ok := worldstate.get(sp.ws, form)
	if !ok || .Disabled not_in d.live {return}
	if r, known := gamedb.ref_by_formid(db, form); known && !d.disabled {
		if _, _, built := find_ref(sp, form); !built {
			if cell := gamedb.ref_attach_cell(db, r); cell in sp.cells {rebuild_cell(sp, db, cell)}
		}
	}
	if form not_in db.enable_parents {return}
	for cell, &c in sp.cells {
		if gated_by(sp, db, &c, form) {rebuild_cell(sp, db, cell)}
	}
}

// apply_delta_live applies a form's CURRENT overlay delta to its live ref — for deltas written
// straight to the overlay (script natives). A ref not live picks the delta up when its cell builds.
// Precedence mirrors build_cell: deleted, then disabled (which ignores Moved/Scaled), then placement.
@(private = "file")
apply_delta_live :: proc(sp: ^Space, form: Form_ID) {
	d, ok := worldstate.get(sp.ws, form)
	if !ok {return}
	if .Deleted in d.live {
		remove_ref(sp, form)
		return
	}
	r, _, live := find_ref(sp, form)
	if !live {return}
	if .Disabled in d.live || .Held in d.live {
		set_ref_disabled(sp, form, worldstate.hidden(d))
		if worldstate.hidden(d) {return}
	}
	switch {
	case .Moved in d.live:  place_ref(sp, form, d.world, d.pos, r.scale)
	case .Scaled in d.live: place_ref(sp, form, smath.trs(r.pos, r.rot, d.scale), r.pos, d.scale)
	}
}

// rebuild_resident_overlay recomputes every live cell's refs as baseline ⊕ overlay from a clean
// baseline, so every delta kind (created refs added or gone, disabled/moved/scaled set or dropped by
// a loaded save) falls out with no per-field reset. Terrain bodies stay. Call after an overlay LOAD.
rebuild_resident_overlay :: proc(sp: ^Space, db: ^gamedb.DB) {
	if sp.ws == nil {
		return
	}
	cells := make([dynamic]Form_ID, 0, len(sp.cells), context.temp_allocator)
	for cell in sp.cells {append(&cells, cell)}
	for cell in cells {rebuild_cell(sp, db, cell)}
}

// create_ref is the Layer-1 spawn verb: mints a runtime ref (worldstate) and makes it live when its
// cell is; sync_physics builds its collision. Returns the new FormID (0 without an overlay).
create_ref :: proc(sp: ^Space, db: ^gamedb.DB, base, cell: Form_ID, pos, rot: [3]f32, scale: f32) -> Form_ID {
	if sp.ws == nil {
		return 0
	}
	id := worldstate.create_ref(sp.ws, base, cell, pos, rot, scale)
	spawn_ref(sp, db, id)
	return id
}

// apply_ref_event applies a change the sim made to a live cell to the render chunk: placement and
// visibility, instances added or dropped, and the model refs they hold. Main runs it; created refs'
// models resolve after a batch (resolve_created_models).
apply_ref_event :: proc(s: ^Scene, e: Ref_Event) {
	switch v in e {
	case Ref_Placed:
		if inst, _, ok := find_resident(s, v.ref.form_id); ok {
			model, posed := inst.model, inst.posed
			inst^ = instance_of(v.ref)
			inst.model, inst.posed = model, posed
		} else if chunk, res := &s.chunks[v.cell]; res {
			add_instance(s, chunk, instance_of(v.ref))
		}
	case Ref_Removed:
		_, chunk, ok := find_resident(s, v.form)
		if !ok {return}
		for inst, i in chunk.instances {
			if inst.form_id == v.form {
				assetdb.model_release(&s.cache, inst.model_id) // D1: drop this ref's model ref
				unordered_remove(&chunk.instances, i)
				break
			}
		}
		delete_key(&s.resident, v.form)
		index_instances(s, chunk)
	case Cell_Rebuilt:
		chunk, ok := &s.chunks[v.cell]
		if !ok {return}
		// The new instances hold their models before the old ones let go, or trim could evict a
		// model the rebuilt cell still needs. The chunk's bounds stay: they cover its terrain.
		old := make([dynamic]models.ID, 0, len(chunk.instances), context.temp_allocator)
		for inst in chunk.instances {append(&old, inst.model_id)}
		deindex_instances(s, chunk)
		clear(&chunk.instances)
		for p in v.refs {add_instance(s, chunk, instance_of(p))}
		for model in old {assetdb.model_release(&s.cache, model)}
	case Cell_Added, Cell_Removed: // the streamer's (stream_apply)
	}
}

// add_instance appends an instance to a resident chunk and holds its model.
@(private = "file")
add_instance :: proc(s: ^Scene, chunk: ^Chunk, inst: Instance) {
	assetdb.model_acquire(&s.cache, inst.model_id) // D1: pin — released when the chunk unloads
	append(&chunk.instances, inst) // may realloc the array — re-index below; no ^Instance held
	index_instances(s, chunk)
}

// resolve_created_models synchronously resolves the model for every resident CREATED ref whose model
// isn't loaded yet: an interior scene has no streamer. Main runs it after applying ref events.
resolve_created_models :: proc(s: ^Scene) {
	for _, &chunk in s.chunks {
		for &inst in chunk.instances {
			if inst.model == nil && inst.form_id >= formid.CREATED_FORM_BASE {
				if m, ok := assetdb.get_model(&s.cache, inst.model_id); ok {
					inst.model = m
				}
			}
		}
	}
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
