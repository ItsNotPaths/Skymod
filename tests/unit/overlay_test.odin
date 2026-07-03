package unit_tests

// Synthetic overlay-rebuild harness (the streamlined seat for mutation-layer bugfixing). It drives the
// EXACT logic of an in-game overlay re-apply — the architecturally-correct "recompute baseline ⊕
// overlay" path (world.rebuild_resident_overlay) — against a hand-built in-memory gamedb + Scene +
// World_State, with NO renderer/physics/ESM. rebuild is GPU-free (build_chunk is pure; models resolve
// lazily/elsewhere; physics ops are nil-guarded), so the whole F9 sequence runs headless.
//
// What it pins (all of which fall out of rebuilding from a clean baseline, with zero per-field reset
// logic): created refs spawn into the right cell; an F9 to an earlier save REMOVES a later-spawned
// created ref (stale) while KEEPING the saved one; a `disabled` delta dropped by the loaded save RESETS
// the ref to visible; and the ESM baseline ref is always present and untouched.

import "core:os"
import "core:testing"
import "../../src/assetdb"
import "../../src/gamedb"
import "../../src/world"
import ws "../../src/worldstate"

@(private = "file")
CELL :: 0x0000D74A
@(private = "file")
BASE :: 0x000B1234
@(private = "file")
BASELINE :: 0x00000100 // a pre-existing ESM ref in the cell (rebuild must always recreate it)

@(private = "file")
find :: proc(s: ^world.Scene, cell, fid: gamedb.Form_ID) -> (world.Instance, bool) {
	ch := s.chunks[cell]
	for inst in ch.instances {
		if inst.form_id == fid {
			return inst, true
		}
	}
	return {}, false
}

@(private = "file")
cell_count :: proc(s: ^world.Scene, cell: gamedb.Form_ID) -> int {
	ch := s.chunks[cell]
	return len(ch.instances)
}

@(test)
test_overlay_rebuild_f9 :: proc(t: ^testing.T) {
	// Minimal gamedb: the cell's ESM refs (build_chunk reads cell_refs) + base→model (model_of).
	db: gamedb.DB
	db.base_models = make(map[gamedb.Form_ID]string)
	db.base_models[BASE] = "clutter\\testpile.nif"
	db.cell_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref)
	db.cell_refs[CELL] = make([dynamic]gamedb.Ref)
	append(&db.cell_refs[CELL], gamedb.Ref{form_id = BASELINE, cell_form_id = CELL, base = BASE, scale = 1})
	defer {
		delete(db.cell_refs[CELL])
		delete(db.cell_refs)
		delete(db.base_models)
	}

	state: ws.World_State
	ws.init(&state)
	defer ws.destroy(&state)

	// Scene with one resident (empty) chunk for CELL — rebuild recomputes its instances from gamedb.
	s: world.Scene
	s.chunks = make(map[gamedb.Form_ID]world.Chunk)
	s.resident = make(map[gamedb.Form_ID]world.Resident_Ref)
	s.ws = &state
	defer {
		for _, &c in s.chunks {delete(c.instances)}
		delete(s.chunks)
		delete(s.resident)
		// rebuild_resident_overlay now acquires model refs (D1 eviction) into s.cache; free the
		// refs map + its owned keys the way scene_destroy does in-game (this synthetic Scene has a
		// zero-value cache and no renderer, so a bare cache_destroy — nil model/tex maps are no-ops).
		assetdb.cache_destroy(&s.cache)
	}
	s.chunks[CELL] = world.Chunk{cell_form_id = CELL, instances = make([dynamic]world.Instance)}

	// Rebuild from a fresh overlay → just the ESM baseline.
	world.rebuild_resident_overlay(&s, &db)
	_, has_base := find(&s, CELL, BASELINE)
	testing.expect(t, has_base, "baseline ESM ref not built")
	testing.expect_value(t, cell_count(&s, CELL), 1)

	// Spawn A + disable the baseline, rebuild → baseline(hidden) + A.
	a := ws.create_ref(&state, BASE, CELL, {1, 2, 3}, {0, 0, 0}, 1)
	ws.set_disabled(&state, BASELINE, CELL, true)
	world.rebuild_resident_overlay(&s, &db)
	if inst, ok := find(&s, CELL, BASELINE); testing.expect(t, ok, "baseline lost") {
		testing.expect(t, inst.disabled, "baseline not disabled by overlay")
	}
	testing.expect(t, func_has(&s, a), "A not spawned")
	testing.expect_value(t, cell_count(&s, CELL), 2)

	// Save the overlay (has A + the disable) — the F5 snapshot.
	path := "test_overlay_rebuild.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&state, path, ws.Save_Manifest{save_number = 1, game_cell = CELL}), "save failed")

	// Spawn B live after the save, rebuild → baseline(hidden) + A + B.
	b := ws.create_ref(&state, BASE, CELL, {4, 5, 6}, {0, 0, 0}, 1)
	world.rebuild_resident_overlay(&s, &db)
	testing.expect(t, func_has(&s, b), "B not spawned")
	testing.expect_value(t, cell_count(&s, CELL), 3)

	// F9: load the save (A + disable, no B), rebuild. Stale B is GONE; A kept; baseline still disabled.
	_, ok := ws.load_from_file(&state, path)
	testing.expect(t, ok, "load failed")
	world.rebuild_resident_overlay(&s, &db)
	testing.expect(t, func_has(&s, a), "A lost after F9 rebuild")
	testing.expect(t, !func_has(&s, b), "stale B not removed after F9 rebuild")
	if inst, hb := find(&s, CELL, BASELINE); testing.expect(t, hb, "baseline lost after F9") {
		testing.expect(t, inst.disabled, "baseline disable not restored from save")
	}
	testing.expect_value(t, cell_count(&s, CELL), 2)

	// Clear the disable in the overlay + rebuild → baseline RESETS to visible (the case incremental
	// patching couldn't do; rebuild gets it for free by starting from a clean baseline).
	ws.set_disabled(&state, BASELINE, CELL, false)
	world.rebuild_resident_overlay(&s, &db)
	if inst, hb := find(&s, CELL, BASELINE); testing.expect(t, hb, "baseline lost") {
		testing.expect(t, !inst.disabled, "baseline disable not reset")
	}
}

@(private = "file")
func_has :: proc(s: ^world.Scene, fid: gamedb.Form_ID) -> bool {
	_, ok := find(s, CELL, fid)
	return ok
}
