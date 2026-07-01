package unit_tests

// Mod-profile data-model tests (task #4). Hermetic: pure data ops + one save/load round-trip to
// a /tmp file. Asserts the MO2-style invariants — locked base pinned at the top, reconcile
// add/drop, enable/move rules, separators — and persistence.

import "core:os"
import "core:testing"
import "../../src/mods"

@(test)
test_mods_reconcile_and_base :: proc(t: ^testing.T) {
	p: mods.Profile
	mods.profile_init(&p)
	defer mods.profile_destroy(&p)

	mods.profile_reconcile(&p, {"ModA", "ModB"})
	testing.expect(t, len(p.mods) == 3, "base + 2 discovered")
	testing.expect(t, p.mods[0].locked && p.mods[0].enabled, "base locked + enabled at top")
	testing.expect(t, mods.profile_index(&p, "ModA") > 0, "ModA present")
	testing.expect(t, mods.profile_index(&p, "ModB") > 0, "ModB present")

	// Second pass: ModA's folder vanished → dropped; base + ModB stay.
	mods.profile_reconcile(&p, {"ModB"})
	testing.expect(t, mods.profile_index(&p, "ModA") < 0, "ModA dropped when folder gone")
	testing.expect(t, mods.profile_index(&p, "ModB") > 0, "ModB kept")
	testing.expect(t, p.mods[0].locked, "base still pinned at top")
}

@(test)
test_mods_toggle_and_move :: proc(t: ^testing.T) {
	p: mods.Profile
	mods.profile_init(&p)
	defer mods.profile_destroy(&p)
	mods.profile_reconcile(&p, {"ModA", "ModB"}) // [base, ModA, ModB]

	a := mods.profile_index(&p, "ModA")
	mods.profile_toggle(&p, a)
	testing.expect(t, !p.mods[a].enabled, "ModA disabled")

	// The locked base can't be disabled.
	mods.profile_toggle(&p, 0)
	testing.expect(t, p.mods[0].enabled, "base stays enabled")

	// Move ModB (idx 2) up → swaps with ModA (idx 1).
	mods.profile_move(&p, 2, -1)
	testing.expect(t, p.mods[1].name == "ModB" && p.mods[2].name == "ModA", "ModB moved above ModA")
	// Nothing slides above the base.
	mods.profile_move(&p, 1, -1)
	testing.expect(t, p.mods[0].locked, "base still at index 0")
}

@(test)
test_mods_move_to :: proc(t: ^testing.T) {
	p: mods.Profile
	mods.profile_init(&p)
	defer mods.profile_destroy(&p)
	mods.profile_reconcile(&p, {"A", "B", "C"}) // [base, A, B, C]

	// Drag C (idx 3) up onto A (idx 1) → inserts before A: [base, C, A, B].
	mods.profile_move_to(&p, 3, 1)
	testing.expect(t, p.mods[1].name == "C" && p.mods[2].name == "A" && p.mods[3].name == "B", "C moved above A")

	// Drag A (idx 2) down onto B (idx 3) → inserts after B: [base, C, B, A].
	mods.profile_move_to(&p, 2, 3)
	testing.expect(t, p.mods[1].name == "C" && p.mods[2].name == "B" && p.mods[3].name == "A", "A moved below B")

	// The locked base can't be dragged, and nothing lands above it.
	mods.profile_move_to(&p, 0, 3)
	testing.expect(t, p.mods[0].locked, "locked base can't move")
	mods.profile_move_to(&p, 1, 0) // to=0 clamps to the first movable slot (== source) → no-op
	testing.expect(t, p.mods[0].locked && p.mods[1].name == "C", "nothing slides above the locked prefix")
}

@(test)
test_mods_set_system :: proc(t: ^testing.T) {
	p: mods.Profile
	mods.profile_init(&p)
	defer mods.profile_destroy(&p)

	mods.profile_set_system(&p, {"Skyrim", "Update"})
	testing.expect(t, len(p.mods) == 2, "two locked system rows")
	testing.expect(t, p.mods[0].name == "Skyrim" && p.mods[0].locked, "Skyrim locked at top")
	testing.expect(t, p.mods[1].name == "Update" && p.mods[1].locked, "Update locked below")

	mods.profile_add(&p, "UserMod")
	testing.expect(t, len(p.mods) == 3 && p.mods[2].name == "UserMod" && !p.mods[2].locked, "user mod appended, unlocked")

	// Re-sync with an added DLC → locked prefix replaced in order, the user mod preserved below.
	mods.profile_set_system(&p, {"Skyrim", "Update", "Dragonborn"})
	testing.expect(t, len(p.mods) == 4, "prefix grew by one")
	testing.expect(t, p.mods[2].name == "Dragonborn" && p.mods[2].locked, "Dragonborn inserted in the locked prefix")
	testing.expect(t, p.mods[3].name == "UserMod" && !p.mods[3].locked, "user mod still below, intact")

	// enabled-mods (the folder-mount set) excludes every locked system row.
	en := mods.profile_enabled_mods(&p, context.allocator)
	defer delete(en)
	testing.expect(t, len(en) == 1 && en[0] == "UserMod", "only the user mod is a mountable folder")
}

@(test)
test_mods_separator :: proc(t: ^testing.T) {
	p: mods.Profile
	mods.profile_init(&p)
	defer mods.profile_destroy(&p)
	mods.profile_add_separator(&p, "Visuals")
	i := len(p.mods) - 1
	testing.expect(t, p.mods[i].kind == .Separator, "separator added")
	// Toggling a separator is a no-op.
	mods.profile_toggle(&p, i)
	testing.expect(t, !p.mods[i].enabled, "separator has no enabled state")
}

@(test)
test_mods_save_load_roundtrip :: proc(t: ^testing.T) {
	dir := "/tmp/skymod_mods_test"
	_ = os.make_directory(dir)
	path := "/tmp/skymod_mods_test/modlist.txt"

	p: mods.Profile
	mods.profile_init(&p)
	mods.profile_reconcile(&p, {}) // just the base
	mods.profile_add_separator(&p, "Gameplay")
	mods.profile_add(&p, "ModA", enabled = true)
	mods.profile_add(&p, "ModB", enabled = false)
	testing.expect(t, mods.profile_save(&p, path), "save ok")
	mods.profile_destroy(&p)

	q: mods.Profile
	mods.profile_init(&q)
	defer mods.profile_destroy(&q)
	testing.expect(t, mods.profile_load(&q, path), "load ok")
	// Base is implicit (not written), so the loaded list is the user entries in order.
	testing.expect(t, len(q.mods) == 3, "separator + 2 mods restored")
	testing.expect(t, q.mods[0].kind == .Separator && q.mods[0].name == "Gameplay", "separator order/label")
	testing.expect(t, q.mods[1].name == "ModA" && q.mods[1].enabled, "ModA enabled")
	testing.expect(t, q.mods[2].name == "ModB" && !q.mods[2].enabled, "ModB disabled")
}
