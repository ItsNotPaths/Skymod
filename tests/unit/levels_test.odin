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

// A leveled actor's template chain goes on from the NPC_ its LVLN rolled: the pick supplies the
// templated parts (here the inventory), stays until the actor resets, and answers GetLeveledActorBase.
@(test)
test_leveled_actor_pick :: proc(t: ^testing.T) {
	REF :: gamedb.Form_ID(0x30)
	BASE :: gamedb.Form_ID(0x31)
	LIST :: gamedb.Form_ID(0x32)
	PICK :: gamedb.Form_ID(0x33)
	db: gamedb.DB
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[BASE] = {template = LIST, template_flags = esm.ACBS_TEMPLATE_INVENTORY}
	db.actors[PICK] = {inventory = {{0xF, 3}}}
	db.leveled_lists = make(map[gamedb.Form_ID]gamedb.Leveled_List, context.temp_allocator)
	db.leveled_lists[LIST] = {entries = {{level = 1, form = PICK, count = 1}}}
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	db.ref_by_id[REF] = {form_id = REF, base = BASE}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	testing.expect_value(t, worldstate.actor_pick(&ws, &db, REF), PICK)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, REF, 0xF), 3)
	worldstate.reset_ref_state(&ws, REF, true)
	testing.expect(t, REF not_in ws.actor_picks, "a reset forgets the pick")
}

// Skill XP buys levels at the SkillXPToNext cost, never past the cap; raised skills give the actor XP;
// a ready level-up spends it with a choice onto a capacity, and a mod's choice can replace vanilla's.
@(test)
test_leveling :: proc(t: ^testing.T) {
	A :: gamedb.Form_ID(0xA1)
	AVIF :: gamedb.Form_ID(0x44C)
	db: gamedb.DB
	db.actor_value_info = make(map[gamedb.Form_ID]gamedb.Actor_Value_Info, context.temp_allocator)
	db.actor_value_info[AVIF] = {skill = {use_mult = 6.3, improve_mult = 2}, has_skill = true}
	db.actor_value_by_index = make(map[i32]gamedb.Form_ID, context.temp_allocator)
	db.actor_value_by_index[6] = AVIF // OneHanded
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.av_set_base(&ws, A, "OneHanded", 15)
	worldstate.advance_skill(&ws, &db, A, "OneHanded", 70) // 441 XP; 15 -> 16 costs 2 * 15^1.95
	testing.expect_value(t, worldstate.av_current(&ws, &db, A, "OneHanded"), 16)
	testing.expect_value(t, ws.levels[A].xp, 16)

	worldstate.av_set_base(&ws, A, "OneHanded", 98)
	testing.expect_value(t, worldstate.raise_skill(&ws, &db, A, "OneHanded", 5), 2) // 16 + 99 + 100 XP
	testing.expect(t, !worldstate.level_up(&ws, &db, A, "Luck"), "no such choice")

	worldstate.av_set_base(&ws, A, "Health", 100)
	testing.expect(t, worldstate.level_up(&ws, &db, A, "health"), "any case names the choice")
	testing.expect_value(t, worldstate.actor_level(&ws, &db, A), 2)
	testing.expect_value(t, worldstate.av_max(&ws, &db, A, "Health"), 110)
	testing.expect_value(t, ws.levels[A].perk_points, 1)
	testing.expect_value(t, len(ws.level_ups), 1)

	changes := make(map[string]string, context.temp_allocator)
	changes["Magicka"] = "5 * level"
	testing.expect(t, worldstate.set_level_choice(&ws, "Magicka", changes), "replace a choice")
	worldstate.raise_skill(&ws, &db, A, "TwoHanded", 20)
	testing.expect(t, worldstate.level_up(&ws, &db, A, "Magicka"), "second level-up")
	testing.expect_value(t, worldstate.av_max(&ws, &db, A, "Magicka"), 15)
}

// A skill at its cap resets to 15, refunds every rank held in its tree, and keeps level and XP.
@(test)
test_make_legendary :: proc(t: ^testing.T) {
	A :: gamedb.Form_ID(0xA1)
	AVIF :: gamedb.Form_ID(0x44C)
	RANK1 :: gamedb.Form_ID(0x100)
	RANK2 :: gamedb.Form_ID(0x101)
	OTHER :: gamedb.Form_ID(0x200)
	db: gamedb.DB
	db.actor_value_by_index = make(map[i32]gamedb.Form_ID, context.temp_allocator)
	db.actor_value_by_index[6] = AVIF // OneHanded
	db.perks = make(map[gamedb.Form_ID]gamedb.Perk, context.temp_allocator)
	db.perks[RANK1] = {next_rank = RANK2}
	db.perks[RANK2] = {}
	db.perk_trees = make(map[gamedb.Form_ID][]gamedb.Perk_Node, context.temp_allocator)
	db.perk_trees[AVIF] = {{perk = 0}, {perk = RANK1}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.av_set_base(&ws, A, "OneHanded", 99)
	testing.expect(t, !worldstate.make_legendary(&ws, &db, A, "OneHanded"), "below the cap")

	worldstate.av_set_base(&ws, A, "OneHanded", 100)
	worldstate.perk_add(&ws, A, RANK1)
	worldstate.perk_add(&ws, A, RANK2)
	worldstate.perk_add(&ws, A, OTHER)
	testing.expect(t, worldstate.make_legendary(&ws, &db, A, "OneHanded"), "at the cap")
	testing.expect_value(t, worldstate.av_base(&ws, &db, A, "OneHanded"), 15)
	testing.expect_value(t, ws.levels[A].perk_points, 2)
	testing.expect_value(t, ws.levels[A].legendary[0], 1)
	testing.expect(t, !worldstate.perk_has(&ws, &db, A, RANK2), "both ranks refunded")
	testing.expect(t, worldstate.perk_has(&ws, &db, A, OTHER), "other trees keep their perks")
}

// A skill book raises its skill once; a spell tome teaches its spell and is used up only then.
@(test)
test_read_book :: proc(t: ^testing.T) {
	A :: gamedb.Form_ID(0xA1)
	SKILL_BOOK :: gamedb.Form_ID(0x500)
	TOME :: gamedb.Form_ID(0x501)
	SPELL :: gamedb.Form_ID(0x502)
	db: gamedb.DB
	db.books = make(map[gamedb.Form_ID]gamedb.Book, context.temp_allocator)
	db.books[SKILL_BOOK] = {skill = 9} // Block
	db.books[TOME] = {skill = -1, spell = SPELL}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.av_set_base(&ws, A, "Block", 20)
	testing.expect(t, !worldstate.read_book(&ws, &db, A, SKILL_BOOK), "a skill book stays")
	testing.expect_value(t, worldstate.av_base(&ws, &db, A, "Block"), 21)
	worldstate.read_book(&ws, &db, A, SKILL_BOOK)
	testing.expect_value(t, worldstate.av_base(&ws, &db, A, "Block"), 21)

	testing.expect(t, worldstate.read_book(&ws, &db, A, TOME), "a new spell uses the tome up")
	testing.expect(t, worldstate.has_spell(&ws, &db, A, SPELL), "spell learned")
	testing.expect(t, !worldstate.read_book(&ws, &db, A, TOME), "a known spell leaves the tome")
}
