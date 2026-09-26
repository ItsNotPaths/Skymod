package unit_tests

import "core:os"
import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

// A taken ref keeps its identity while its container holds it: it follows moves by base, survives a
// save and drops back as itself. A stack split by a partial move is carried no more, and a drop with
// no carried ref makes a new stack.
@(test)
test_carried_refs :: proc(t: ^testing.T) {
	ACTOR :: gamedb.Form_ID(0x14)
	CHEST :: gamedb.Form_ID(0x30)
	AMULET :: gamedb.Form_ID(0x40)
	ARROWS :: gamedb.Form_ID(0x41)
	QUEST_ITEM :: gamedb.Form_ID(0x50)
	STACK :: gamedb.Form_ID(0x51)
	CELL :: gamedb.Form_ID(0x60)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	db.ref_by_id[QUEST_ITEM] = {form_id = QUEST_ITEM, cell_form_id = CELL, base = AMULET, count = 1}
	db.ref_by_id[STACK] = {form_id = STACK, cell_form_id = CELL, base = ARROWS, count = 12}
	db.ref_by_id[ACTOR] = {form_id = ACTOR, cell_form_id = CELL, pos = {1, 2, 3}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	c := script.Call{ws = &ws, db = &db}

	for ref in ([]gamedb.Form_ID{QUEST_ITEM, STACK}) {
		script.move_items(&c, {base = worldstate.ref_base(&ws, &db, ref), ref = ref, to = ACTOR, count = worldstate.stack_count(&ws, &db, ref)})
	}
	testing.expect_value(t, worldstate.inv_count(&ws, &db, ACTOR, ARROWS), 12)
	script.move_items(&c, {base = ARROWS, from = ACTOR, count = 5})
	testing.expect(t, STACK not_in ws.carried, "a split stack is carried no more")

	script.move_items(&c, {base = AMULET, from = ACTOR, to = CHEST, count = 1})
	testing.expect_value(t, ws.carried[QUEST_ITEM], CHEST)

	path := "test_carried.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect_value(t, ws.carried[QUEST_ITEM], CHEST)

	script.move_items(&c, {base = AMULET, from = CHEST, to = ACTOR, count = 1})
	testing.expect_value(t, script.drop_object(&c, ACTOR, AMULET, 0, 1), QUEST_ITEM)
	testing.expect(t, QUEST_ITEM not_in ws.carried, "dropped ref is in the world")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, ACTOR, AMULET), 0)

	fresh := script.drop_object(&c, ACTOR, ARROWS, 0, 2)
	testing.expect(t, fresh != 0 && fresh != STACK, "a new stack")
	testing.expect_value(t, worldstate.stack_count(&ws, &db, fresh), 2)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, ACTOR, ARROWS), 5)
}
