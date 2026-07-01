package unit_tests

// World-state overlay save/load round-trip (ROADMAP Phase 3d). Hermetic: build an overlay with a
// couple of Moved deltas, write a .skysave to a temp path, load it into a FRESH overlay, and assert
// every field (transform/pos/live/cell + the by_cell index) survives. Guards the CBOR schema +
// container framing + CRC against silent drift.

import "core:os"
import "core:testing"
import smath "../../src/math"
import ws "../../src/worldstate"

@(test)
test_worldstate_save_load :: proc(t: ^testing.T) {
	src: ws.World_State
	ws.init(&src)
	defer ws.destroy(&src)

	m1 := smath.trs({100, 200, 300}, {0.1, 0.2, 0.3}, 1.0)
	m2 := smath.trs({-50, 0, 12}, {0, 0, 1.57}, 2.0)
	ws.set_moved(&src, 0x000ABCDE, 0x0001A26F, m1, {100, 200, 300})
	ws.set_moved(&src, 0x000F00D5, 0x0001A26F, m2, {-50, 0, 12})
	// A second field on an existing delta (Moved+Scaled coexist) and a non-Moved verb (Disabled-only,
	// in a different cell) — exercises the Layer-1 verb family + multi-flag `live` round-trip.
	ws.set_scale(&src, 0x000ABCDE, 0x0001A26F, 3.5)
	ws.set_disabled(&src, 0x000C0FFE, 0x0002BEEF, true)
	// A runtime-created ref (0xFF space): separate from ref_deltas, with its own allocator + index.
	new_id := ws.create_ref(&src, 0x000DEAD0, 0x0003CAFE, {10, 20, 30}, {0, 1, 0}, 1.5)
	testing.expect_value(t, new_id, ws.CREATED_FORM_BASE)
	// Coarse singletons: globals + the player.
	ws.set_global(&src, 0x00000005, 42.5)
	ws.set_player(&src, 0, {7, 8, 9}, 1.2, -0.3)

	path := "test_quicksave.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&src, path, ws.Save_Manifest{save_number = 7, game_cell = 0x0001A26F}), "save failed")

	// Partial load: manifest only.
	man, mok := ws.read_manifest(path)
	testing.expect(t, mok, "manifest read failed")
	testing.expect_value(t, man.save_number, u32(7))
	testing.expect_value(t, man.delta_count, u32(3))

	// Full load into a fresh overlay.
	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	_, lok := ws.load_from_file(&dst, path)
	testing.expect(t, lok, "load failed")
	testing.expect_value(t, ws.count(&dst), 3)

	d, has := ws.get(&dst, 0x000ABCDE)
	testing.expect(t, has, "delta A missing after load")
	testing.expect_value(t, d.cell, u64(0x0001A26F))
	testing.expect(t, .Moved in d.live, "Moved flag lost")
	testing.expect(t, .Scaled in d.live, "Scaled flag lost")
	testing.expectf(t, abs(d.scale - 3.5) < 1e-5, "scale mismatch: %v", d.scale)
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {
			testing.expectf(t, abs(d.world[i, j] - m1[i, j]) < 1e-5, "world[%d,%d] mismatch: %v vs %v", i, j, d.world[i, j], m1[i, j])
		}
	}

	// Disabled-only delta survives with the right field and no spurious flags.
	dd, dhas := ws.get(&dst, 0x000C0FFE)
	testing.expect(t, dhas, "disabled delta missing after load")
	testing.expect(t, .Disabled in dd.live, "Disabled flag lost")
	testing.expect(t, .Moved not_in dd.live, "spurious Moved flag on a disabled-only delta")
	testing.expect(t, dd.disabled, "disabled value lost")
	testing.expect_value(t, dd.cell, u64(0x0002BEEF))

	// by_cell index rebuilt on load (the two cell-A refs together; the disabled ref in cell B).
	testing.expect_value(t, len(ws.refs_in(&dst, 0x0001A26F)), 2)
	testing.expect_value(t, len(ws.refs_in(&dst, 0x0002BEEF)), 1)

	// Created ref survives with its FormID, placement, and the allocator cursor.
	testing.expect_value(t, len(ws.created_in(&dst, 0x0003CAFE)), 1)
	cr, crok := ws.get_created(&dst, new_id)
	testing.expect(t, crok, "created ref missing after load")
	testing.expect_value(t, cr.base, u64(0x000DEAD0))
	testing.expect_value(t, cr.cell, u64(0x0003CAFE))
	testing.expectf(t, abs(cr.scale - 1.5) < 1e-5, "created scale mismatch: %v", cr.scale)
	testing.expect_value(t, dst.next_created, ws.CREATED_FORM_BASE + 1)

	// Globals + player singleton survive.
	gv, gok := ws.get_global(&dst, 0x00000005)
	testing.expect(t, gok, "global missing after load")
	testing.expectf(t, abs(gv - 42.5) < 1e-5, "global value mismatch: %v", gv)
	pl, pok := ws.get_player(&dst)
	testing.expect(t, pok, "player singleton missing after load")
	testing.expectf(t, abs(pl.pos.x - 7) < 1e-5 && abs(pl.yaw - 1.2) < 1e-5, "player pos/yaw mismatch: %v yaw %v", pl.pos, pl.yaw)
}

@(test)
test_worldstate_load_missing :: proc(t: ^testing.T) {
	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	_, ok := ws.load_from_file(&dst, "does_not_exist_42.skysave")
	testing.expect(t, !ok, "loading a missing file should fail cleanly")
}
