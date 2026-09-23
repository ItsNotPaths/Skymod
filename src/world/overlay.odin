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

// apply_overlay patches a freshly-built chunk's instances with the overlay (baseline ⊕ overlay):
// a Moved ref's ESM placement is replaced by its settled transform, so it reappears where it came
// to rest, not where the master put it. Call after build_chunk and BEFORE collision is built
// (sync_physics reads inst.world to place the body). No-op without an overlay.
apply_overlay :: proc(s: ^Scene, chunk: ^Chunk) {
	if s.ws == nil {
		return
	}
	for &inst in chunk.instances {
		d, ok := worldstate.get(s.ws, inst.form_id)
		if !ok {
			continue
		}
		// Disabled: hidden + (via inst.disabled) skipped by sync_physics; ignores Moved/Scaled.
		// (Deleted never reaches here — build_overlaid_chunk suppresses those refs entirely.)
		if .Disabled in d.live && d.disabled {
			inst.disabled = true
			inst.vis = .Hidden
			continue
		}
		if .Moved in d.live {
			inst.world = d.world
			inst.pos = d.pos
		}
		if .Scaled in d.live {
			inst.scale = d.scale
			if .Moved not_in d.live {
				// Moved bakes scale into its matrix; a scale-only delta recomputes the placement.
				inst.world = smath.trs(inst.pos, inst.rot, d.scale)
			}
		}
	}
}

// disable_ref is the Layer-1 mutation verb for Disabled (docs/live-state.md §7.1): it records a
// Disabled delta in the overlay (so it persists + reapplies via apply_overlay on the next cell load)
// AND, when the ref is currently resident, applies it live — the instance stops rendering AND loses
// its collision immediately (remove_instance_bodies frees its slice of chunk.bodies). Returns false
// if the scene has no overlay (nothing recorded). Re-enable (disabled=false) restores rendering, but
// collision is rebuilt only on the next cell reload (sync_physics rebuilds when !inst.disabled).
disable_ref :: proc(s: ^Scene, form_id, cell: Form_ID, disabled: bool) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_disabled(s.ws, form_id, cell, disabled)
	if inst, chunk, ok := find_resident(s, form_id); ok {
		inst.disabled = disabled
		inst.vis = .Hidden if disabled else .Show
		if disabled {
			remove_instance_bodies(s.phys, chunk, inst)
		} else {
			inst.phys_built = false // re-enable: let sync_physics rebuild its bodies
			chunk.phys_done = false
		}
	}
	return true
}

// enable_ref re-enables a previously-disabled ref — the inverse of disable_ref (restores rendering +
// flags collision for rebuild). Thin alias so callers/scripts read symmetrically.
enable_ref :: proc(s: ^Scene, form_id, cell: Form_ID) -> bool {
	return disable_ref(s, form_id, cell, false)
}

// rebuild_instance_collision drops a resident instance's current bodies and flags it (+ its chunk)
// for a fresh build by sync_physics — used after a live transform change (move/scale) so collision
// follows the new placement. No-op without a physics world.
@(private)
rebuild_instance_collision :: proc(s: ^Scene, chunk: ^Chunk, inst: ^Instance) {
	if s.phys == nil {
		return
	}
	remove_instance_bodies(s.phys, chunk, inst)
	inst.phys_built = false
	chunk.phys_done = false
}

// move_ref relocates a ref: records a Moved delta (persists + reapplies on load) and, when resident,
// moves the instance live — render follows immediately, collision rebuilds at the new transform.
move_ref :: proc(s: ^Scene, form_id, cell: Form_ID, world: smath.Mat4, pos: smath.Vec3) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_moved(s.ws, form_id, cell, world, pos)
	if inst, chunk, ok := find_resident(s, form_id); ok {
		inst.world = world
		inst.pos = pos
		rebuild_instance_collision(s, chunk, inst)
	}
	return true
}

// scale_ref sets a ref's uniform scale: records a Scaled delta and, when resident, rescales live
// (recomputes the placement from pos/rot/scale; collision rebuilds at the new size).
scale_ref :: proc(s: ^Scene, form_id, cell: Form_ID, scale: f32) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_scale(s.ws, form_id, cell, scale)
	if inst, chunk, ok := find_resident(s, form_id); ok {
		inst.scale = scale
		inst.world = smath.trs(inst.pos, inst.rot, scale)
		rebuild_instance_collision(s, chunk, inst)
	}
	return true
}

// delete_ref destroys an ESM ref: records a Deleted delta (so the cell-build suppresses it forever)
// and, when resident, removes the live instance + its collision immediately. The permanent sibling of
// disable_ref (a deleted ref can't be re-enabled).
delete_ref :: proc(s: ^Scene, form_id, cell: Form_ID) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_deleted(s.ws, form_id, cell)
	if _, chunk, ok := find_resident(s, form_id); ok {
		for i in 0 ..< len(chunk.instances) {
			if chunk.instances[i].form_id == form_id {
				remove_instance_bodies(s.phys, chunk, &chunk.instances[i])
				assetdb.model_release(&s.cache, chunk.instances[i].model_path) // D1: drop this ref's model ref
				unordered_remove(&chunk.instances, i)
				break
			}
		}
		delete_key(&s.resident, form_id)
		index_instances(s, chunk) // indices shifted by unordered_remove
	}
	return true
}

// open_ref / lock_ref record door/container open-state + lock-state deltas. RECORD-ONLY for now: the
// visible open/close (animation/pose) and the activation-time lock check land with the door/container
// + activation systems (game-logic). The state persists today, and Layer 2 can already call these —
// see docs/live-state.md "triggered movables" (state-not-transform). Resident live-apply is a no-op
// until those systems exist.
open_ref :: proc(s: ^Scene, form_id, cell: Form_ID, open: bool) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_open(s.ws, form_id, cell, open)
	return true
}

lock_ref :: proc(s: ^Scene, form_id, cell: Form_ID, locked: bool) -> bool {
	if s.ws == nil {
		return false
	}
	worldstate.set_locked(s.ws, form_id, cell, locked)
	return true
}

// apply_pending_scene_ops drains the worldstate deferred-apply queue and live-applies each change to
// THIS scene (docs/script-runtime-decisions.md §3 — the "one fixed frame point"). Script natives write
// the overlay synchronously (read-your-writes) but don't touch the live scene; this is what makes the
// change visible. Call once per frame on the active scene. No-op without an overlay / empty queue.
apply_pending_scene_ops :: proc(s: ^Scene) {
	if s.ws == nil {
		return
	}
	for form in worldstate.pending_scene(s.ws) {
		apply_overlay_ref(s, form)
	}
	worldstate.clear_scene_dirty(s.ws)
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
	// Deleted: remove the resident instance + its collision entirely (delete_ref's live half).
	if .Deleted in d.live {
		if _, chunk, res := find_resident(s, form_id); res {
			for i in 0 ..< len(chunk.instances) {
				if chunk.instances[i].form_id == form_id {
					remove_instance_bodies(s.phys, chunk, &chunk.instances[i])
					assetdb.model_release(&s.cache, chunk.instances[i].model_path) // D1: drop this ref's model ref
					unordered_remove(&chunk.instances, i)
					break
				}
			}
			delete_key(&s.resident, form_id)
			index_instances(s, chunk)
		}
		return
	}
	inst, chunk, res := find_resident(s, form_id)
	if !res {
		return
	}
	// Disabled wins over transform (a hidden ref ignores Moved/Scaled, as in apply_overlay).
	if .Disabled in d.live && d.disabled {
		if !inst.disabled {
			inst.disabled = true
			inst.vis = .Hidden
			remove_instance_bodies(s.phys, chunk, inst)
		}
		return
	}
	// Re-enable a previously-hidden ref (flag collision for rebuild).
	if .Disabled in d.live && !d.disabled && inst.disabled {
		inst.disabled = false
		inst.vis = .Show
		inst.phys_built = false
		chunk.phys_done = false
	}
	if .Moved in d.live {
		inst.world = d.world
		inst.pos = d.pos
		rebuild_instance_collision(s, chunk, inst)
	} else if .Scaled in d.live {
		inst.scale = d.scale
		inst.world = smath.trs(inst.pos, inst.rot, d.scale)
		rebuild_instance_collision(s, chunk, inst)
	}
}

// --- created refs (the ADDITIVE half of baseline ⊕ overlay; docs/live-state.md §6 created-ref store) ---

// build_created_instance constructs an Instance for a runtime-created ref (base form → model path via
// gamedb). ok=false if the base has no world model (nothing to place).
build_created_instance :: proc(db: ^gamedb.DB, form_id: Form_ID, c: worldstate.Created_Ref) -> (Instance, bool) {
	modl, ok := gamedb.model_of(db, c.base)
	if !ok || modl == "" || is_marker_path(modl) || is_nonworld_path(modl) {
		return {}, false
	}
	return Instance {
			model_path = modl,
			base = c.base,
			form_id = form_id,
			pos = c.pos,
			rot = c.rot,
			scale = c.scale,
			world = smath.trs(c.pos, c.rot, c.scale),
			veg = veg_classify(modl),
		},
		true
}

// build_overlaid_chunk assembles a cell's instance layer as baseline ⊕ overlay in ONE step: the ESM
// baseline (build_chunk) plus the runtime-created refs (spawn_created). Every cell-build path goes
// through this — interior load_cell, the exterior streamer, the persistent cell, and the F9 rebuild —
// so the two halves can never drift apart (a raw build_chunk that forgets spawn_created would silently
// drop created refs). Models are left unresolved (the caller resolves sync or enqueues async); deltas
// are patched afterward via apply_overlay.
build_overlaid_chunk :: proc(s: ^Scene, db: ^gamedb.DB, cell: Form_ID) -> Chunk {
	chunk := build_chunk(db, cell)
	merge_persistent(s, db, &chunk) // fold in this grid cell's persistent refs (doors/bridges/gates)
	if s.ws != nil {
		// Deleted refs are SUPPRESSED at build — never instantiated (vs Disabled, which is built then
		// hidden so it can be re-enabled). Downward scan so unordered_remove only moves checked items.
		for i := len(chunk.instances) - 1; i >= 0; i -= 1 {
			if d, ok := worldstate.get(s.ws, chunk.instances[i].form_id); ok && .Deleted in d.live {
				unordered_remove(&chunk.instances, i)
			}
		}
	}
	spawn_created(s, db, &chunk)
	return chunk
}

// spawn_created appends the runtime-created refs registered for this chunk's cell as Instances — the
// ADDITIVE half of the overlay (apply_overlay only PATCHES existing ESM refs; created refs have no
// baseline). The instances then flow through the normal resolve/collision/render/index paths. Call
// right after build_chunk, BEFORE model resolve + index_instances + collision. No-op without overlay.
spawn_created :: proc(s: ^Scene, db: ^gamedb.DB, chunk: ^Chunk) {
	if s.ws == nil {
		return
	}
	outer: for fid in worldstate.created_in(s.ws, chunk.cell_form_id) {
		for inst in chunk.instances {
			if inst.form_id == fid {
				continue outer // already spawned — keep idempotent so reapply_overlay_resident is safe
			}
		}
		c, ok := worldstate.get_created(s.ws, fid)
		if !ok {
			continue
		}
		if inst, built := build_created_instance(db, fid, c); built {
			append(&chunk.instances, inst)
		}
	}
}

// reapply_overlay_resident re-applies the overlay to every CURRENTLY-RESIDENT chunk: spawns created
// refs (resolving their models synchronously) and patches disabled/moved/scaled. The fix for overlay
// LOADS landing on chunks that are already loaded (built before the menu's Continue and not reloaded
// on the crossing), so their created refs would otherwise never appear. spawn_created is idempotent,
// so this is safe to call repeatedly (Continue +
// F9 quickload). Grid cells not yet streamed pick the overlay up normally when they build. (It does
// NOT remove stale live state for refs dropped by the loaded save — full exterior reconciliation on
// F9 is still deferred; see the F9 note in main.)
// rebuild_resident_overlay recomputes every resident chunk's INSTANCE layer as a pure function of
// baseline ⊕ overlay — the architecturally-correct overlay re-apply, NOT incremental patching. Per
// chunk: drop the old instances (+ their object collision), rebuild the ESM baseline from gamedb
// (build_chunk), add the created refs (spawn_created), then apply deltas (apply_overlay). Because it
// starts from a CLEAN baseline every time, it handles every delta kind uniformly with zero per-field
// reset logic — created add/remove AND disabled/moved/scaled that the loaded save dropped all just
// fall out (the ref is rebuilt un-disabled / at its ESM transform, and the delta simply isn't there to
// re-apply). This is the same model interiors already use (traversal_reload re-enters the cell).
//
// KEPT (the overlay never touches them, so no churn): terrain/grass/water meshes + the terrain
// collision body — only object collision rebuilds (via sync_physics). GPU-free (build_chunk is pure;
// models resolve lazily at draw / via resolve_created_models; physics ops are nil-guarded), so it's
// unit-testable headless — the synthetic test drives exactly this. Call after an overlay LOAD.
rebuild_resident_overlay :: proc(s: ^Scene, db: ^gamedb.DB) {
	if s.ws == nil {
		return
	}
	for cid, &chunk in s.chunks {
		// Drop old object bodies (the terrain body stays in chunk.bodies) + old instances + their index.
		// D1 TRAP: this swaps chunk.instances WITHOUT release_chunk_assets, so it must rebalance the
		// model refs itself — release over the OLD instances, acquire over the FRESH ones. Miss it and
		// every F9 quickload pins the old instances' models forever (a ref leak eviction can never reclaim).
		for &inst in chunk.instances {
			remove_instance_bodies(s.phys, &chunk, &inst)
			assetdb.model_release(&s.cache, inst.model_path)
		}
		deindex_instances(s, &chunk)
		delete(chunk.instances)
		// Recompute: ESM baseline ⊕ created refs ⊕ deltas.
		fresh := build_overlaid_chunk(s, db, cid)
		chunk.instances = fresh.instances // ownership transfers; only .instances is heap-allocated
		for inst in chunk.instances {
			assetdb.model_acquire(&s.cache, inst.model_path)
		}
		index_instances(s, &chunk)
		apply_overlay(s, &chunk)
		chunk.phys_done = false // object collision rebuilds via sync_physics; terrain body untouched
	}
}

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
	if chunk, ok := &s.chunks[cell]; ok {
		c, _ := worldstate.get_created(s.ws, id)
		if inst, built := build_created_instance(db, id, c); built {
			if m, mok := assetdb.get_model(&s.cache, inst.model_path); mok {
				inst.model = m
			}
			assetdb.model_acquire(&s.cache, inst.model_path) // D1: pin — released when the chunk unloads
			append(&chunk.instances, inst) // may realloc the array — re-index below; no ^Instance held
			chunk.phys_done = false         // let sync_physics build the new ref's collision
			index_instances(s, chunk)
		}
	}
	return id
}

// capture_settles writes a debounced Moved delta for every movable-clutter body that JUST came to
// rest this frame (the active→asleep edge). Debounced by construction — fires only on settle, never
// per frame — mirroring why vanilla separates HAVOK_MOVE from MOVE. Bodies that barely moved from
// where they were built are skipped (MOVE_EPS), so a cell-load's settling clutter doesn't fill the
// overlay with no-op deltas. Call once per frame after physics.step. No-op without an overlay.
capture_settles :: proc(s: ^Scene) {
	if s.ws == nil || s.phys == nil {
		return
	}
	for _, &chunk in s.chunks {
		for &inst in chunk.instances {
			if inst.dyn_body == 0 {
				continue
			}
			act := physics.body_active(s.phys, inst.dyn_body)
			if inst.dyn_active && !act {
				// Just settled — snapshot the resting placement as a Moved delta.
				m := instance_world(s, &inst)
				p := smath.Vec3{m[0, 3], m[1, 3], m[2, 3]}
				if smath.length3(p - inst.pos) > MOVE_EPS {
					worldstate.set_moved(s.ws, inst.form_id, chunk.cell_form_id, m, p)
					log.infof(
						"overlay: ref 0x%08X settled at (%.0f, %.0f, %.0f) — %d delta(s)",
						inst.form_id, p.x, p.y, p.z, worldstate.count(s.ws),
					)
				}
			}
			inst.dyn_active = act
		}
	}
}
