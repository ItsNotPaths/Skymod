package unit_tests

// Save identity-remap test (docs/saves.md §4.4.1): a save embeds a form-table bridge tagging the
// stable slots its Form_IDs use; on load, a bridge that resolves those identities to DIFFERENT slots
// (another install / a reorder) must rewrite every Form_ID's slot half — so a moved object is still
// the right object. Also checks the drop rule: a saved identity that won't resolve is discarded.

import "core:os"
import "core:testing"
import smath "../../src/math"
import "../../src/formid"
import "../../src/mods"
import ws "../../src/worldstate"

// The test "install A" gave Cool.esp slot 0x10; "install B" gives it 0x20. Missing.esp (slot 0x30)
// isn't present on B at all. The bridges below are pure (no captured state), keyed on these constants.
@(private = "file")
SLOT_A :: u32(0x10)
@(private = "file")
SLOT_B :: u32(0x20)
@(private = "file")
SLOT_MISSING :: u32(0x30)

@(private = "file")
save_identify :: proc(user: rawptr, slot: u32) -> (uuid: string, filename: string, ok: bool) {
	switch slot {
	case SLOT_A:
		return "uuid-cool", "Cool.esp", true
	case SLOT_MISSING:
		return "uuid-gone", "Missing.esp", true
	}
	return "", "", false
}

@(private = "file")
load_resolve :: proc(user: rawptr, uuid: string, filename: string) -> (slot: u32, ok: bool) {
	if uuid == "uuid-cool" && filename == "Cool.esp" {return SLOT_B, true} // moved 0x10 → 0x20
	return 0, false // Missing.esp is absent on install B
}

@(test)
test_save_remap_cross_install :: proc(t: ^testing.T) {
	fid :: proc(slot: u32, local: u64) -> ws.Form_ID {return (ws.Form_ID(slot) << 32) | local}

	src: ws.World_State
	ws.init(&src)
	defer ws.destroy(&src)

	// A moved object owned by Cool.esp (slot A), plus a delta owned by the soon-to-be-missing mod.
	m := smath.trs({10, 20, 30}, {0, 0, 0}, 1.0)
	ws.set_moved(&src, fid(SLOT_A, 0xABCD), fid(SLOT_A, 0x1A26F), m, {10, 20, 30})
	ws.set_disabled(&src, fid(SLOT_MISSING, 0x77), fid(SLOT_MISSING, 0x1A26F), true)
	// A quest alias of Cool.esp holding a Cool.esp ref: the handle carries the quest's slot.
	alias_a, _ := formid.alias_handle(fid(SLOT_A, 0x5000), 7)
	ws.fill_alias(&src, alias_a, fid(SLOT_A, 0xABCD))

	save_br := ws.Form_Bridge{identify = save_identify}
	path := "/tmp/skymod_save_remap_test.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&src, path, ws.Save_Manifest{save_number = 1}, &save_br), "save with bridge")

	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	load_br := ws.Form_Bridge{resolve = load_resolve}
	_, ok := ws.load_from_file(&dst, path, &load_br)
	testing.expect(t, ok, "load with bridge")

	// The moved delta is now keyed under slot B (remapped), NOT slot A (its saved slot).
	if _, has := ws.get(&dst, fid(SLOT_A, 0xABCD)); has {
		testing.expect(t, false, "old-slot key must not survive the remap")
	}
	d, has := ws.get(&dst, fid(SLOT_B, 0xABCD))
	testing.expect(t, has, "moved delta remapped to the new slot")
	if has {
		testing.expect(t, d.cell == fid(SLOT_B, 0x1A26F), "the delta's cell ref is remapped too")
		testing.expect(t, d.pos == [3]f32{10, 20, 30}, "payload survives the remap")
	}

	// The delta owned by the missing mod was dropped (its identity didn't resolve on install B).
	if _, has := ws.get(&dst, fid(SLOT_MISSING, 0x77)); has {
		testing.expect(t, false, "a delta keyed on a missing mod must be dropped")
	}
	testing.expect(t, ws.count(&dst) == 1, "exactly the resolvable delta remains")

	alias_b, _ := formid.alias_handle(fid(SLOT_B, 0x5000), 7)
	testing.expect_value(t, dst.aliases[alias_b], fid(SLOT_B, 0xABCD))
	testing.expect_value(t, len(dst.aliases), 1)
}

// The bridge hooks the app's cell_load.form_bridge installs, replicated here over a REAL
// mods.Form_Table (user = ^Form_Table) — so this test exercises formtable_entry_by_slot (save) and
// formtable_resolve (load) exactly as the app does, not a hand-faked slot map.
@(private = "file")
ft_identify :: proc(user: rawptr, slot: u32) -> (uuid: string, filename: string, ok: bool) {
	if e, has := mods.formtable_entry_by_slot((^mods.Form_Table)(user), slot); has {
		return e.uuid, e.filename, true
	}
	return "", "", false
}
@(private = "file")
ft_resolve :: proc(user: rawptr, uuid: string, filename: string) -> (slot: u32, ok: bool) {
	return mods.formtable_resolve((^mods.Form_Table)(user), uuid, filename)
}

@(test)
test_save_remap_real_formtable :: proc(t: ^testing.T) {
	fid :: proc(slot: u32, local: u64) -> ws.Form_ID {return (ws.Form_ID(slot) << 32) | local}

	// Install A: Cool.esp is the first user plugin → slot 0x10. Save a moved object owned by it.
	ftA: mods.Form_Table
	mods.formtable_init(&ftA)
	defer mods.formtable_destroy(&ftA)
	sa := mods.formtable_intern(&ftA, "Cool.esp", "uuid-cool")

	src: ws.World_State
	ws.init(&src)
	defer ws.destroy(&src)
	ws.set_moved(&src, fid(sa, 0xABCD), fid(sa, 0x1A26F), smath.trs({5, 6, 7}, {0, 0, 0}, 1), {5, 6, 7})

	brA := ws.Form_Bridge{user = &ftA, identify = ft_identify}
	path := "/tmp/skymod_save_realft_test.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&src, path, ws.Save_Manifest{save_number = 1}, &brA), "save over real table A")

	// Install B: a different mod was installed first, so Cool.esp interns to a DIFFERENT slot (0x11).
	// The bridge over table B must remap the save's slot-0x10 forms onto 0x11 by matching identity.
	ftB: mods.Form_Table
	mods.formtable_init(&ftB)
	defer mods.formtable_destroy(&ftB)
	mods.formtable_intern(&ftB, "Other.esp", "uuid-other") // 0x10
	sb := mods.formtable_intern(&ftB, "Cool.esp", "uuid-cool") // 0x11 (≠ sa)
	testing.expect(t, sa != sb, "the same mod holds different slots across the two installs")

	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	brB := ws.Form_Bridge{user = &ftB, resolve = ft_resolve}
	_, ok := ws.load_from_file(&dst, path, &brB)
	testing.expect(t, ok, "load over real table B")

	if _, has := ws.get(&dst, fid(sa, 0xABCD)); has {
		testing.expect(t, false, "install-A slot must not survive")
	}
	d, has := ws.get(&dst, fid(sb, 0xABCD))
	testing.expect(t, has, "delta remapped onto install-B's slot via the real form-table")
	if has {testing.expect(t, d.cell == fid(sb, 0x1A26F), "cell ref remapped too")}
}

@(test)
test_save_no_bridge_is_verbatim :: proc(t: ^testing.T) {
	// No bridge ⇒ same-install identity: Form_IDs round-trip unchanged (the empty-form_table path).
	fid := (ws.Form_ID(SLOT_A) << 32) | 0xBEEF
	src: ws.World_State
	ws.init(&src)
	defer ws.destroy(&src)
	ws.set_disabled(&src, fid, (ws.Form_ID(SLOT_A) << 32) | 0x1A26F, true)

	path := "/tmp/skymod_save_nobridge_test.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&src, path, ws.Save_Manifest{save_number = 1}), "save without bridge")

	dst: ws.World_State
	ws.init(&dst)
	defer ws.destroy(&dst)
	_, ok := ws.load_from_file(&dst, path)
	testing.expect(t, ok, "load without bridge")
	_, has := ws.get(&dst, fid)
	testing.expect(t, has, "verbatim Form_ID survives when no bridge is used")
}
