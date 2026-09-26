package unit_tests

import "core:os"
import "core:slice"
import "core:testing"
import "../../src/gamedb"
import "../../src/worldstate"

// A spell list is the records' list with a saved delta: a mod update's changes show in an old save,
// a given spell outlives its seed and a removed one stays gone. A leveled list rolls the same way
// every read. rt.seed_spell edits act on the records' list.
@(test)
test_spell_list :: proc(t: ^testing.T) {
	NPC, RACE, LEVELED :: gamedb.Form_ID(0x500), gamedb.Form_ID(0x501), gamedb.Form_ID(0x502)
	RACIAL, OWN, TAUGHT, NEW, LOW, HIGH :: gamedb.Form_ID(0x600), gamedb.Form_ID(0x601), gamedb.Form_ID(0x602), gamedb.Form_ID(0x603), gamedb.Form_ID(0x604), gamedb.Form_ID(0x605)
	db: gamedb.DB
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[NPC] = {race = RACE, level = 10, spells = {OWN, LEVELED}}
	db.races = make(map[gamedb.Form_ID]gamedb.Race, context.temp_allocator)
	db.races[RACE] = {spells = {RACIAL}}
	db.leveled_lists = make(map[gamedb.Form_ID]gamedb.Leveled_List, context.temp_allocator)
	db.leveled_lists[LEVELED] = {entries = {{level = 1, form = LOW, count = 1}, {level = 20, form = HIGH, count = 1}}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	testing.expect(t, slice.equal(worldstate.spell_list(&ws, &db, NPC), []gamedb.Form_ID{RACIAL, OWN, LOW}), "race, NPC_, leveled at level 10")
	db.leveled_lists[LEVELED] = {entries = {{level = 1, form = LOW, count = 1}, {level = 1, form = HIGH, count = 1}}}
	first := slice.clone(worldstate.spell_list(&ws, &db, NPC), context.temp_allocator)
	for _ in 0 ..< 8 {testing.expect(t, slice.equal(worldstate.spell_list(&ws, &db, NPC), first), "a tie picks the same every read")}
	db.leveled_lists[LEVELED] = {entries = {{level = 1, form = LOW, count = 1}, {level = 20, form = HIGH, count = 1}}}
	testing.expect(t, !worldstate.give_spell(&ws, &db, NPC, OWN), "already known")
	testing.expect(t, worldstate.give_spell(&ws, &db, NPC, TAUGHT), "learned")
	testing.expect(t, worldstate.remove_spell(&ws, &db, NPC, RACIAL), "forgotten")
	testing.expect(t, !worldstate.remove_spell(&ws, &db, NPC, NEW), "never known")

	path := "test_spell_list.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")

	db.actors[NPC] = {race = RACE, level = 10, spells = {NEW}} // a mod update
	testing.expect(t, slice.equal(worldstate.spell_list(&ws, &db, NPC), []gamedb.Form_ID{NEW, OWN, TAUGHT}), "the update shows; given stays, removed stays gone")

	worldstate.seed_spell(&ws, RACE, LOW, worldstate.GIVEN) // rt.seed_spell
	worldstate.seed_spell(&ws, RACE, RACIAL, worldstate.GIVEN)
	worldstate.seed_spell(&ws, NPC, NEW, worldstate.REMOVED) // rt.unseed_spell
	testing.expect(t, slice.equal(worldstate.spell_list(&ws, &db, NPC), []gamedb.Form_ID{LOW, OWN, TAUGHT}), "seed edits act as record edits; the actor's own removal still wins")
}
