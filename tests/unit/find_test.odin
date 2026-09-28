package unit_tests

import "core:testing"
import "../../src/formid"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

// Game.Find*: loaded refs only (attached cell, enabled), the persistent refs over an attached
// cell and the created ones included; the player is an actor.
@(test)
test_find_refs :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	F :: script.Form_ID
	WORLD, PERSIST, GRID, FAR_GRID :: F(0x200), F(0x201), F(0x202), F(0x203)
	GEM, NPC, LIST :: F(0x300), F(0x301), F(0x302)
	NEAR, MID, PERSISTENT, FAR, ACTOR :: F(0x500), F(0x501), F(0x502), F(0x503), F(0x504)

	db: gamedb.DB
	defer {
		delete(db.cells);delete(db.cell_at_grid);delete(db.world_persist);delete(db.ref_by_id)
		delete(db.actors);delete(db.form_lists)
		for _, l in db.cell_refs {delete(l)}
		for _, l in db.actor_refs {delete(l)}
		delete(db.cell_refs);delete(db.actor_refs)
	}
	db.cells[PERSIST] = {form_id = PERSIST, world_form_id = WORLD}
	db.cells[GRID] = {form_id = GRID, world_form_id = WORLD, has_grid = true}
	db.cells[FAR_GRID] = {form_id = FAR_GRID, world_form_id = WORLD, has_grid = true}
	db.cell_at_grid[{WORLD, 0, 0}] = GRID
	db.cell_at_grid[{WORLD, 1, 0}] = FAR_GRID
	db.world_persist[WORLD] = PERSIST
	db.actors[NPC] = {}
	db.actors[formid.PLAYER_BASE] = {}
	members := []F{GEM}
	db.form_lists[LIST] = members
	place :: proc(db: ^gamedb.DB, list: ^map[F][dynamic]gamedb.Ref, id, cell, base: F, x: f32) {
		r := gamedb.Ref{form_id = id, cell_form_id = cell, base = base, pos = {x, 0, 0}}
		db.ref_by_id[id] = r
		if cell not_in list {list[cell] = make([dynamic]gamedb.Ref)}
		append(&list[cell], r)
	}
	place(&db, &db.cell_refs, NEAR, GRID, GEM, 10)
	place(&db, &db.cell_refs, MID, GRID, GEM, 50)
	place(&db, &db.cell_refs, PERSISTENT, PERSIST, GEM, 20)
	place(&db, &db.cell_refs, FAR, FAR_GRID, GEM, 4100)
	place(&db, &db.actor_refs, ACTOR, GRID, NPC, 30)
	db.ref_by_id[ws.player] = {form_id = ws.player, base = formid.PLAYER_BASE}
	created := worldstate.create_ref(&ws, GEM, GRID, {5, 0, 0}, {}, 1)

	c := script.Call{ws = &ws, db = &db}
	find :: proc(reg: ^script.Registry, c: ^script.Call, fn: string, args: ..script.Value) -> script.Value {
		return script.call(reg, "Game", fn, c, args)
	}
	x, r :: f32(0), f32(100)

	testing.expect(t, find(&reg, &c, "FindClosestReferenceOfType", GEM, x, x, x, r) == nil, "nothing attached")
	ws.attached[GRID] = make([dynamic]F)
	testing.expect_value(t, find(&reg, &c, "FindClosestReferenceOfType", GEM, x, x, x, r).(F), created)
	worldstate.set_disabled(&ws, created, GRID, true)
	testing.expect_value(t, find(&reg, &c, "FindClosestReferenceOfType", GEM, x, x, x, r).(F), NEAR)
	worldstate.set_disabled(&ws, NEAR, GRID, true)
	testing.expect_value(t, find(&reg, &c, "FindClosestReferenceOfAnyTypeInList", LIST, x, x, x, r).(F), PERSISTENT)
	testing.expect(t, find(&reg, &c, "FindClosestReferenceOfType", GEM, x, x, x, f32(15)) == nil, "out of range")
	testing.expect(t, find(&reg, &c, "FindRandomReferenceOfType", GEM, f32(4100), x, x, f32(10)) == nil, "unattached cell")
	testing.expect_value(t, find(&reg, &c, "FindRandomReferenceOfType", GEM, f32(50), x, x, f32(1)).(F), MID)

	testing.expect_value(t, find(&reg, &c, "FindClosestActor", x, x, x, r).(F), ACTOR)
	worldstate.set_moved(&ws, ws.player, GRID, {}, {1, 0, 0})
	testing.expect_value(t, find(&reg, &c, "FindClosestActor", x, x, x, r).(F), ws.player)
	got := find(&reg, &c, "FindRandomActor", x, x, x, r).(F)
	testing.expect(t, got == ACTOR || got == ws.player, "a random actor in range")
}
