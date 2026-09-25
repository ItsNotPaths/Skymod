package unit_tests

// World-state overlay save/load round-trip (ROADMAP Phase 3d). Hermetic: build an overlay with a
// couple of Moved deltas, write a .skysave to a temp path, load it into a FRESH overlay, and assert
// every field (transform/pos/live/cell + the by_cell index) survives. Guards the CBOR schema +
// container framing + CRC against silent drift.

import "core:os"
import "core:testing"
import "../../src/formid"
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
	ws.set_activation_blocked(&src, 0x000C0FFE, 0x0002BEEF, true) // the 9th field: live is wider than a byte
	ws.register_update(&src.updates, 0x000C0DE0, 2.5, false)
	ws.register_update(&src.updates, 0x000C0DE0, 4, true)
	ws.register_update(&src.game_updates, 0x000C0DE0, 24, false)
	ws.add_item_filter(&src, 0x000C0DE0, 0xF)
	ws.add_to_list(&src, 0x000F1570, 0x000ABCDE)
	src.keyword_data[{0x0001C0C0, 0x000CEEEE}] = 2
	src.pending_moves[0x000A0001] = {0x000A0002, {0, 0, 50}}
	fx := ws.start_effect(&src, {effect = 0x000A0003, spell = 0x000A0004, target = 0x000A0001, duration = 5, elapsed = 2})
	alias, _ := formid.alias_handle(0x000C0DE0, 3)
	ws.fill_alias(&src, alias, 0x000ABCDE)
	// A runtime-created ref (0xFF space): separate from ref_deltas, with its own allocator + index.
	new_id := ws.create_ref(&src, 0x000DEAD0, 0x0003CAFE, {10, 20, 30}, {0, 1, 0}, 1.5)
	testing.expect_value(t, new_id, formid.CREATED_FORM_BASE)
	// Coarse singletons.
	ws.set_global(&src, 0x00000005, 42.5)
	ws.start_clock(&src, 201, 7, 17, 8, 1)
	ws.leave_cell(&src, 0x0001A26F)
	ws.ask_reset(&src, 0x0001A26F)
	src.cleared[0x0001C0C0] = true
	src.restocks[0x000C0DE0] = 12
	ws.skip_game_time(&src, 2.5)
	// A Dead delta (the new actor life-state field) on its own ref/cell.
	ws.set_dead(&src, 0x000A11FE, 0x0004DEAD, true)
	// Quest store: a stage (marks it done + running), a couple of objectives with distinct flags,
	// and the active/completed bits — exercises the nested done-set + objective-map round-trip.
	ws.quest_set_running(&src, 0x000C0DE0, true) // explicit Start (SetStage no longer implies running)
	ws.quest_set_stage(&src, 0x000C0DE0, 40)
	ws.quest_set_objective(&src, 0x000C0DE0, 10, .Displayed, true)
	ws.quest_set_objective(&src, 0x000C0DE0, 10, .Completed, true)
	ws.quest_set_objective(&src, 0x000C0DE0, 20, .Failed, true)
	ws.quest_set_active(&src, 0x000C0DE0, true)
	// The three Wave-1 stores: inventory (two items on one owner), actor values (case-folded key),
	// faction rank, relationship rank — exercises each map-of-maps CBOR round-trip.
	ws.inv_add(&src, 0x000B0B00, 0x0000000F, 250) // gold
	ws.inv_add(&src, 0x000B0B00, 0x0001A11E, 3)
	ws.av_set(&src, 0x000AC701, "Health", 87.5)
	ws.faction_set_rank(&src, 0x000AC701, 0x000FAC70, 4)
	ws.rel_set(&src, 0x000AC701, 0x000F00D5, 3)
	ws.perk_add(&src, 0x000AC701, 0x000BABE0)

	path := "test_quicksave.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&src, path, ws.Save_Manifest{save_number = 7, game_cell = 0x0001A26F}), "save failed")

	// Partial load: manifest only.
	man, mok := ws.read_manifest(path)
	testing.expect(t, mok, "manifest read failed")
	testing.expect_value(t, man.save_number, u32(7))
	testing.expect_value(t, man.delta_count, u32(4))

	// Full load into a fresh overlay.
	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	_, lok := ws.load_from_file(&dst, path)
	testing.expect(t, lok, "load failed")
	testing.expect_value(t, ws.count(&dst), 4)

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
	testing.expect(t, ws.activation_blocked(&dst, 0x000C0FFE), "Activation_Blocked flag lost")
	testing.expect_value(t, dst.updates[0x000C0DE0], ws.Update_Timers{single = 2.5, repeat = 4, interval = 4, single_on = true, repeat_on = true})
	testing.expect_value(t, dst.game_updates[0x000C0DE0], ws.Update_Timers{single = 24, single_on = true})
	testing.expect_value(t, dst.item_filters[0x000C0DE0][0], 0xF)
	testing.expect_value(t, ws.list_added(&dst, 0x000F1570)[0], 0x000ABCDE)
	testing.expect_value(t, dst.keyword_data[{0x0001C0C0, 0x000CEEEE}], 2)
	testing.expect_value(t, dst.pending_moves[0x000A0001], ws.Pending_Move{0x000A0002, {0, 0, 50}})
	testing.expect_value(t, dst.effects[fx].elapsed, 2)
	testing.expect_value(t, dst.next_effect, src.next_effect)
	testing.expect_value(t, len(ws.effects_on(&dst, 0x000A0001)), 1)
	testing.expect_value(t, dst.aliases[alias], 0x000ABCDE)
	testing.expect_value(t, dst.alias_holders[0x000ABCDE][0], alias)
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
	testing.expect_value(t, dst.next_created, formid.CREATED_FORM_BASE + 1)

	// Coarse singletons survive.
	gv, gok := ws.get_global(&dst, 0x00000005)
	testing.expect(t, gok, "global missing after load")
	testing.expectf(t, abs(gv - 42.5) < 1e-5, "global value mismatch: %v", gv)
	testing.expect_value(t, dst.clock, src.clock)
	testing.expect_value(t, dst.cells[0x0001A26F], src.cells[0x0001A26F])
	testing.expect(t, dst.cleared[0x0001C0C0], "cleared location lost")
	testing.expect_value(t, dst.restocks[0x000C0DE0], 12)

	// Dead delta survives.
	deadd, deadok := ws.get(&dst, 0x000A11FE)
	testing.expect(t, deadok, "dead delta missing after load")
	testing.expect(t, .Dead in deadd.live, "Dead flag lost")
	testing.expect(t, deadd.dead, "dead value lost")

	// Quest store survives: stage (running + done), the two objectives' distinct flags, active bit.
	q, qok := ws.quest_get(&dst, 0x000C0DE0)
	testing.expect(t, qok, "quest state missing after load")
	testing.expect_value(t, q.stage, u16(40))
	testing.expect(t, q.running && q.running_set, "quest running/running_set lost")
	testing.expect(t, q.active, "quest active bit lost")
	testing.expect(t, ws.quest_is_stage_done(&dst, 0x000C0DE0, 40), "stage 40 not marked done")
	testing.expect(t, !ws.quest_is_stage_done(&dst, 0x000C0DE0, 41), "spurious done stage")
	o10 := ws.quest_objective(&dst, 0x000C0DE0, 10)
	testing.expect(t, .Displayed in o10 && .Completed in o10 && .Failed not_in o10, "objective 10 flags wrong")
	o20 := ws.quest_objective(&dst, 0x000C0DE0, 20)
	testing.expect(t, .Failed in o20 && .Displayed not_in o20, "objective 20 flags wrong")

	// The three Wave-1 stores survive.
	testing.expect_value(t, ws.inv_count(&dst, 0x000B0B00, 0x0000000F), i32(250))
	testing.expect_value(t, ws.inv_count(&dst, 0x000B0B00, 0x0001A11E), i32(3))
	hv, hok := ws.av_get(&dst, 0x000AC701, "health") // case-folded lookup hits the stored key
	testing.expect(t, hok, "actor value missing after load")
	testing.expectf(t, abs(hv - 87.5) < 1e-5, "AV mismatch: %v", hv)
	fr, fok := ws.faction_rank(&dst, 0x000AC701, 0x000FAC70)
	testing.expect(t, fok && fr == 4, "faction rank lost")
	testing.expect_value(t, ws.rel_rank(&dst, 0x000AC701, 0x000F00D5), i32(3))
	testing.expect_value(t, ws.rel_rank(&dst, 0x000F00D5, 0x000AC701), i32(3)) // symmetric mirror
	testing.expect(t, ws.perk_has(&dst, 0x000AC701, 0x000BABE0), "perk lost")
}

@(test)
test_worldstate_load_missing :: proc(t: ^testing.T) {
	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	_, ok := ws.load_from_file(&dst, "does_not_exist_42.skysave")
	testing.expect(t, !ok, "loading a missing file should fail cleanly")
}
