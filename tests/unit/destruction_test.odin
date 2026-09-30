package unit_tests

import "core:os"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"

// DEST and its DSTD stages decode with each stage's model (DMDL).
@(test)
test_destruction_decode :: proc(t: ^testing.T) {
	dstd := [20]u8{50, 0, 1, esm.DSTD_CAP_DAMAGE, 16, 0, 0, 0, 0xAA, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0}
	health, stages, ok := esm.destruction({{type = "DEST", data = {100, 0, 0, 0, 1, 0, 0, 0}}, {type = "DSTD", data = dstd[:]}, {type = "DMDL", data = transmute([]u8)string("a.nif\x00")}}, context.temp_allocator)
	testing.expect(t, ok && health == 100 && len(stages) == 1, "one stage")
	testing.expect(t, stages[0].health_pct == 50 && stages[0].self_dps == 16 && stages[0].explosion == 0xAA && stages[0].debris_count == 3, "DSTD")
	testing.expect_value(t, stages[0].model, "a.nif")
}

// Damage takes a ref through its stages, from high health percent to low: each change is an event,
// a Destroy stage marks it destroyed, a stage that ignores hits takes only a script's damage, a
// capping stage takes none, and a burning stage damages itself.
@(test)
test_destruction_stages :: proc(t: ^testing.T) {
	POOL, BASE :: gamedb.Form_ID(0xA1), gamedb.Form_ID(0xB1)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	db.ref_by_id[POOL] = {form_id = POOL, base = BASE}
	db.destructibles = make(map[gamedb.Form_ID]gamedb.Destructible, context.temp_allocator)
	db.destructibles[BASE] = {100, {
		{health_pct = 99, index = 0, flags = esm.DSTD_IGNORE_EXTERNAL, self_dps = 10},
		{health_pct = 50, index = 1, flags = esm.DSTD_DESTROY},
		{health_pct = 10, index = 2, flags = esm.DSTD_CAP_DAMAGE},
	}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	stage :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB) -> i32 {s, _ := worldstate.destruction_stage(ws, db, 0xA1); return s}

	testing.expect_value(t, stage(&ws, &db), -1)
	worldstate.damage_object(&ws, &db, POOL, 5, true)
	testing.expect_value(t, stage(&ws, &db), 0)
	worldstate.damage_object(&ws, &db, POOL, 30, true) // stage 0 ignores hits
	testing.expect_value(t, ws.destruction[POOL], 5)
	worldstate.tick_destruction(&ws, &db, 5) // it burns 10 a second
	testing.expect_value(t, stage(&ws, &db), 1)
	testing.expect(t, worldstate.is_destroyed(&ws, POOL), "the Destroy stage")
	testing.expect_value(t, ws.destruction_changes[1], worldstate.Destruction_Change{POOL, 0, 1})

	path := "test_destruction.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok && ws.destruction[POOL] == 55, "saved")

	worldstate.damage_object(&ws, &db, POOL, 100, false)
	testing.expect_value(t, stage(&ws, &db), 2)
	worldstate.damage_object(&ws, &db, POOL, 5, false)
	testing.expect_value(t, ws.destruction[POOL], 100) // capped
	worldstate.destroy_object(&ws, &db, POOL, false)
	testing.expect(t, stage(&ws, &db) == -1 && !worldstate.is_destroyed(&ws, POOL), "made whole")
}
