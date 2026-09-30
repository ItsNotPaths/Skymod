package unit_tests

// Form-table tests (mydocs/mods.md "Two tiers"; mydocs/saves.md §4.4). Hermetic: pure data ops plus one
// save/load round-trip to a /tmp file. Asserts the identity invariants the save-portability story
// depends on — monotonic interning, the tombstone (re-add returns the SAME slot), official pins
// (Skyrim.esm == 0), uuid-first resolve, and text persistence advancing next_user past loaded slots.

import "core:os"
import "core:testing"
import "../../src/mods"

@(test)
test_formtable_intern_and_tombstone :: proc(t: ^testing.T) {
	ft: mods.Form_Table
	mods.formtable_init(&ft)
	defer mods.formtable_destroy(&ft)

	// Official pins sit in the reserved low range; Skyrim.esm MUST be 0.
	mods.formtable_assign_official(&ft, "Skyrim.esm", 0)
	mods.formtable_assign_official(&ft, "Dawnguard.esm", 2)
	if s, ok := mods.formtable_slot(&ft, "skyrim.esm"); !ok || s != 0 {
		testing.expectf(t, false, "Skyrim.esm must resolve to slot 0 (case-insensitively), got %v ok=%v", s, ok)
	}

	// User plugins get monotonic slots from USER_SLOT_BASE, independent of the official pins.
	a := mods.formtable_intern(&ft, "AAA.esp", "uuid-a")
	b := mods.formtable_intern(&ft, "BBB.esp", "uuid-b")
	testing.expect(t, a == mods.USER_SLOT_BASE, "first user slot == USER_SLOT_BASE")
	testing.expect(t, b == mods.USER_SLOT_BASE + 1, "second user slot is +1")

	// Re-interning is idempotent (same slot), and case-insensitive on the filename.
	testing.expect(t, mods.formtable_intern(&ft, "aaa.esp", "uuid-a") == a, "re-intern returns same slot")

	// Tombstone: even after a fresh plugin claims the next slot, re-adding AAA returns its ORIGINAL
	// slot — the binding is never reused/renumbered.
	c := mods.formtable_intern(&ft, "CCC.esp", "uuid-c")
	testing.expect(t, c == mods.USER_SLOT_BASE + 2, "new plugin gets the next monotonic slot")
	testing.expect(t, mods.formtable_intern(&ft, "AAA.esp", "uuid-a") == a, "re-add maps back to original slot")
}

@(test)
test_formtable_resolve_by_uuid :: proc(t: ^testing.T) {
	ft: mods.Form_Table
	mods.formtable_init(&ft)
	defer mods.formtable_destroy(&ft)

	slot := mods.formtable_intern(&ft, "Cool.esp", "stable-uuid-123")

	// Resolve prefers the portable uuid (survives a filename rename across installs)...
	if s, ok := mods.formtable_resolve(&ft, "stable-uuid-123", "Renamed.esp"); !ok || s != slot {
		testing.expectf(t, false, "uuid resolve should find slot %v regardless of filename, got %v ok=%v", slot, s, ok)
	}
	// ...and falls back to the filename when the uuid is empty (legacy save).
	if s, ok := mods.formtable_resolve(&ft, "", "cool.esp"); !ok || s != slot {
		testing.expectf(t, false, "filename fallback should resolve slot %v, got %v ok=%v", slot, s, ok)
	}
	// A mod absent from this install is unresolvable → caller drops its deltas.
	if _, ok := mods.formtable_resolve(&ft, "missing-uuid", "Gone.esp"); ok {
		testing.expect(t, false, "an unknown identity must not resolve")
	}

	// entry_by_slot round-trips the identity the save bridge emits.
	if e, ok := mods.formtable_entry_by_slot(&ft, slot); !ok || e.uuid != "stable-uuid-123" {
		testing.expectf(t, false, "entry_by_slot(%v) should carry the uuid, got %v ok=%v", slot, e, ok)
	}
}

@(test)
test_formtable_save_load_roundtrip :: proc(t: ^testing.T) {
	path := "/tmp/skymod_formtable_test.txt"
	defer os.remove(path)

	{
		ft: mods.Form_Table
		mods.formtable_init(&ft)
		defer mods.formtable_destroy(&ft)
		mods.formtable_assign_official(&ft, "Skyrim.esm", 0)
		mods.formtable_intern(&ft, "First.esp", "uuid-1")
		mods.formtable_intern(&ft, "Second.esp", "uuid-2")
		testing.expect(t, mods.formtable_save(&ft, path), "save writes the table")
	}

	ft2: mods.Form_Table
	mods.formtable_init(&ft2)
	defer mods.formtable_destroy(&ft2)
	testing.expect(t, mods.formtable_load(&ft2, path), "load reads the table")

	// Every binding survives verbatim.
	if s, ok := mods.formtable_slot(&ft2, "skyrim.esm"); !ok || s != 0 {
		testing.expectf(t, false, "official pin lost on reload: %v ok=%v", s, ok)
	}
	if s, ok := mods.formtable_slot(&ft2, "second.esp"); !ok || s != mods.USER_SLOT_BASE + 1 {
		testing.expectf(t, false, "Second.esp slot lost on reload: %v ok=%v", s, ok)
	}
	// next_user advanced past the highest loaded user slot, so a fresh intern can't collide.
	fresh := mods.formtable_intern(&ft2, "Third.esp", "uuid-3")
	testing.expect(t, fresh == mods.USER_SLOT_BASE + 2, "post-load intern continues monotonically")
}
