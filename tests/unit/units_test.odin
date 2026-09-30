package unit_tests

import "core:os"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

// An item with data keeps its ID: a scripted amulet taken from the world is a unit that follows moves
// by base, survives a save, and drops back as itself, placed where it lands. A plain placed stack
// becomes a count and leaves the world; plain items dropped become one new ref holding their count.
@(test)
test_item_units :: proc(t: ^testing.T) {
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
	db.form_scripts = make(map[gamedb.Form_ID]esm.Form_Scripts, context.temp_allocator)
	db.form_scripts[AMULET] = {scripts = []esm.Script_Attach{{name = "Amulet"}}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	c := script.Call{ws = &ws, db = &db}

	script.take(&c, QUEST_ITEM, AMULET, ACTOR)
	script.take(&c, STACK, ARROWS, ACTOR)
	testing.expect_value(t, ws.units[QUEST_ITEM].holder, ACTOR)
	testing.expect(t, .Held in ws.ref_deltas[QUEST_ITEM].live, "held, it is out of the world")
	testing.expect(t, worldstate.is_deleted(&ws, STACK) && STACK not_in ws.units, "a plain stack leaves the world")
	testing.expect_value(t, worldstate.plain_count(&ws, &db, ACTOR, ARROWS), 12)

	script.move_items(&c, {base = AMULET, from = ACTOR, to = CHEST, count = 1})
	testing.expect_value(t, ws.units[QUEST_ITEM].holder, CHEST)
	testing.expect(t, worldstate.held_units(&ws, ACTOR) == nil || len(worldstate.held_units(&ws, ACTOR)) == 0, "the actor holds it no more")

	path := "test_units.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect_value(t, ws.units[QUEST_ITEM].holder, CHEST)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, CHEST, AMULET), 1)

	script.move_items(&c, {base = AMULET, from = CHEST, to = ACTOR, count = 1})
	testing.expect_value(t, script.drop_object(&c, ACTOR, AMULET, 0, 1), QUEST_ITEM)
	testing.expect(t, ws.units[QUEST_ITEM].holder == 0 && .Held not_in ws.ref_deltas[QUEST_ITEM].live, "dropped, it is in the world")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, ACTOR, AMULET), 0)

	// a worn unit that leaves comes off; a dropped created unit a cell reset removes leaves no data
	worldstate.inv_add(&ws, CHEST, AMULET, 1)
	script.move_items(&c, {base = AMULET, from = CHEST, to = ACTOR, count = 1}) // scripted: a new unit
	worn := worldstate.held_units(&ws, ACTOR, AMULET)[0]
	worldstate.equipment(&ws, &db, ACTOR).worn = make([dynamic]worldstate.Worn, context.temp_allocator)
	append(&worldstate.equipment(&ws, &db, ACTOR).worn, worldstate.Worn{item = AMULET})
	script.move_items(&c, {base = AMULET, from = ACTOR, to = CHEST, count = 1})
	testing.expect(t, !worldstate.is_equipped(&ws, &db, ACTOR, AMULET), "the last one left, so it is off")
	script.move_items(&c, {base = AMULET, from = CHEST, to = ACTOR, count = 1})
	script.drop_object(&c, ACTOR, AMULET, worn, 1)
	worldstate.remove_created(&ws, worn)
	testing.expect(t, worn not_in ws.units, "removed with its ref")

	fresh := script.drop_object(&c, ACTOR, ARROWS, 0, 2)
	testing.expect(t, fresh != 0 && fresh not_in ws.units, "plain arrows drop as a new ref")
	testing.expect_value(t, worldstate.stack_count(&ws, &db, fresh), 2)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, ACTOR, ARROWS), 10)
}
