package unit_tests

import "core:os"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"

// A zone clamps the player's level to its band; Match PC Below Minimum keeps a lower player level.
@(test)
test_zone_level_from :: proc(t: ^testing.T) {
	band := gamedb.Zone{min_level = 5, max_level = 20}
	testing.expect_value(t, worldstate.zone_level_from(band, 1), 5)
	testing.expect_value(t, worldstate.zone_level_from(band, 30), 20)
	testing.expect_value(t, worldstate.zone_level_from({min_level = 5}, 30), 30) // max 0 = no cap
	testing.expect_value(t, worldstate.zone_level_from({min_level = 5, flags = esm.ECZN_MATCH_PC_BELOW_MIN}, 2), 2)
}

// Without All Levels only the highest level at or below the roll qualifies; Use All takes every
// entry; nested lists roll with the parent's count; chance none 100 yields nothing.
@(test)
test_leveled_roll :: proc(t: ^testing.T) {
	db: gamedb.DB
	db.leveled_lists = make(map[gamedb.Form_ID]gamedb.Leveled_List, context.temp_allocator)
	db.leveled_lists[0x10] = {entries = {{level = 1, form = 0xA, count = 1}, {level = 5, form = 0xB, count = 2}, {level = 10, form = 0xC, count = 1}}}
	db.leveled_lists[0x11] = {flags = esm.LVLI_USE_ALL, entries = {{level = 1, form = 0x10, count = 1}, {level = 1, form = 0xD, count = 3}}}
	db.leveled_lists[0x12] = {chance_none = 100, entries = {{level = 1, form = 0xA, count = 1}}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	out := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	worldstate.roll(&ws, &db, 0x10, 6, 3, &out)
	testing.expect(t, len(out) == 1 && out[0] == {0xB, 6}, "the level-5 entry, count x 3")
	clear(&out)
	worldstate.roll(&ws, &db, 0x11, 6, 1, &out)
	testing.expect(t, len(out) == 2 && out[0] == {0xB, 2} && out[1] == {0xD, 3}, "use all, nested")
	clear(&out)
	worldstate.roll(&ws, &db, 0x12, 6, 1, &out)
	testing.expect_value(t, len(out), 0)
}

// A container's leveled entries roll on the first read and stay, through a save; a reset rolls again.
@(test)
test_rolled_contents_stay :: proc(t: ^testing.T) {
	CHEST :: gamedb.Form_ID(0x20)
	db: gamedb.DB
	db.leveled_lists = make(map[gamedb.Form_ID]gamedb.Leveled_List, context.temp_allocator)
	db.leveled_lists[0x10] = {flags = esm.LVLI_CALC_FROM_ALL_LEVELS, entries = {{level = 1, form = 0xA, count = 1}, {level = 1, form = 0xB, count = 1}}}
	db.containers = make(map[gamedb.Form_ID][]gamedb.Content_Entry, context.temp_allocator)
	db.containers[CHEST] = {{0x10, 1}, {0xF, 25}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	first := worldstate.inv_start(&ws, &db, CHEST)[0]
	for _ in 0 ..< 20 {testing.expect_value(t, worldstate.inv_start(&ws, &db, CHEST)[0], first)}
	testing.expect_value(t, worldstate.inv_count(&ws, &db, CHEST, 0xF), 25)

	path := "test_rolled.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect_value(t, worldstate.inv_start(&ws, &db, CHEST)[0], first)

	worldstate.drop_inventory(&ws, CHEST)
	testing.expect(t, CHEST not_in ws.rolled, "a reset forgets the roll")
}
