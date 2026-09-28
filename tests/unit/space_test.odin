package unit_tests

// world.Space bookkeeping without a physics world: cells built from gamedb, refs found through the
// resident index after removals, and the collision store's three answers.

import "core:testing"
import "../../src/assetdb"
import "../../src/gamedb"
import "../../src/world"

@(private = "file")
SPACE_CELL :: gamedb.Form_ID(1)
@(private = "file")
ACTOR_BASE :: gamedb.Form_ID(7)

// space_db is a cell with placed refs `forms` (base = form + 1000, each with a model) and one actor.
@(private = "file")
space_db :: proc(forms: ..gamedb.Form_ID) -> (db: gamedb.DB) {
	db.base_models = make(map[gamedb.Form_ID]string)
	db.cell_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref)
	db.actor_refs = make(map[gamedb.Form_ID][dynamic]gamedb.Ref)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base)
	refs: [dynamic]gamedb.Ref
	for f in forms {
		db.base_models[f + 1000] = "clutter\\cup.nif"
		append(&refs, gamedb.Ref{form_id = f, cell_form_id = SPACE_CELL, base = f + 1000, scale = 1})
	}
	db.cell_refs[SPACE_CELL] = refs
	db.actors[ACTOR_BASE] = {}
	actors: [dynamic]gamedb.Ref
	append(&actors, gamedb.Ref{form_id = 500, cell_form_id = SPACE_CELL, base = ACTOR_BASE, scale = 1})
	db.actor_refs[SPACE_CELL] = actors
	return
}

@(private = "file")
space_db_destroy :: proc(db: ^gamedb.DB) {
	delete(db.base_models)
	for _, r in db.cell_refs {delete(r)}
	delete(db.cell_refs)
	for _, r in db.actor_refs {delete(r)}
	delete(db.actor_refs)
	delete(db.actors)
}

@(test)
test_space_refs :: proc(t: ^testing.T) {
	db := space_db(10, 11, 12)
	defer space_db_destroy(&db)
	sp: world.Space
	world.space_init(&sp, nil, nil, nil, false)
	defer world.space_destroy(&sp)

	c := world.add_cell(&sp, &db, SPACE_CELL)
	testing.expect_value(t, len(c.refs), 3)
	testing.expect(t, len(c.actors) == 1 && c.actors[0] == 500, "the cell keeps its actor")

	r, cell, ok := world.find_ref(&sp, 11)
	testing.expect(t, ok && r.base == 1011 && cell.cell == SPACE_CELL, "a ref is found in its cell")

	// Removing the first ref moves the last into its slot; the index must still find it.
	world.remove_ref(&sp, 10)
	_, _, gone := world.find_ref(&sp, 10)
	testing.expect(t, !gone, "a removed ref is gone")
	r, _, ok = world.find_ref(&sp, 12)
	testing.expect(t, ok && r.form_id == 12, "the moved ref is still found")

	world.set_ref_disabled(&sp, 12, true)
	r, _, _ = world.find_ref(&sp, 12)
	testing.expect(t, r.disabled && !r.phys_built, "disabled")
	world.place_ref(&sp, 12, {}, {5, 0, 0}, 2)
	testing.expect(t, r.pos.x == 5 && r.scale == 2, "placed")

	// A rebuild starts from gamedb again: the removed ref is back, the placement is the ESM one.
	_, rebuilt := world.rebuild_cell(&sp, &db, SPACE_CELL)
	testing.expect(t, rebuilt, "a live cell rebuilds")
	_, _, back := world.find_ref(&sp, 10)
	r, _, _ = world.find_ref(&sp, 12)
	testing.expect(t, back && r.pos.x == 0 && !r.disabled, "a rebuild restores the baseline")

	world.remove_cell(&sp, SPACE_CELL)
	testing.expect(t, len(sp.cells) == 0 && len(sp.resident) == 0, "a removed cell leaves no index entries")
	_, _, ok = world.find_ref(&sp, 11)
	testing.expect(t, !ok, "nothing is found in a removed cell")
}

@(test)
test_collision_store_answers :: proc(t: ^testing.T) {
	store: assetdb.Collision_Store
	defer assetdb.collision_store_destroy(&store)
	cache := assetdb.cache_init(nil, nil, &store)
	defer assetdb.cache_destroy(&cache)

	_, known := assetdb.collision_of(&store, "a.nif")
	testing.expect(t, !known, "a model not decoded yet is unknown")
	assetdb.mark_failed(&cache, "A.NIF")
	m, failed := assetdb.collision_of(&store, "a.nif")
	testing.expect(t, failed && m == nil, "a model that decoded to nothing is known, with no collision")
	m, known = assetdb.collision_of(nil, "b.nif")
	testing.expect(t, known && m == nil, "without a store every model is known to have none")

	// A read before the decode lands is a request, made once; a model a loader has in hand is not.
	wanted: [dynamic]string
	defer delete(wanted)
	assetdb.take_wanted(&store, &wanted)
	testing.expect(t, len(wanted) == 1 && wanted[0] == "a.nif", "the first read asked for a.nif")
	assetdb.note_asked(&store, "c.nif")
	assetdb.collision_of(&store, "D.nif")
	assetdb.collision_of(&store, "d.nif")
	assetdb.collision_of(&store, "c.nif")
	assetdb.take_wanted(&store, &wanted)
	testing.expect(t, len(wanted) == 1 && wanted[0] == "d.nif", "one request, for the model nobody asked for")
	assetdb.take_wanted(&store, &wanted)
	testing.expect_value(t, len(wanted), 0)
}

@(private = "file")
WINDOW_WORLD :: gamedb.Form_ID(900)

// window_db is a row of grid cells at gx 0..4, gy 0; cell form = 100 + gx.
@(private = "file")
window_db :: proc() -> (db: gamedb.DB) {
	db.cells = make(map[gamedb.Form_ID]gamedb.Cell)
	db.cell_at_grid = make(map[gamedb.Grid_Key]gamedb.Form_ID)
	for gx in i32(0) ..< 5 {
		id := gamedb.Form_ID(100 + gx)
		db.cells[id] = {form_id = id, world_form_id = WINDOW_WORLD, gx = gx, has_grid = true}
		db.cell_at_grid[{WINDOW_WORLD, gx, 0}] = id
	}
	return
}

@(private = "file")
live_set :: proc(sp: ^world.Space) -> (set: bit_set[0 ..< 5]) {
	for cell in sp.cells {set += {int(cell - 100)}}
	return
}

@(test)
test_window_follows_the_player :: proc(t: ^testing.T) {
	db := window_db()
	defer {delete(db.cells); delete(db.cell_at_grid)}
	sp: world.Space
	world.space_init(&sp, nil, nil, nil, false)
	defer world.space_destroy(&sp)
	world.set_world(&sp, &db, WINDOW_WORLD, 1)

	at :: proc(gx: f32) -> [3]f32 {return {(gx + 0.5) * world.CELL_SIZE, 0.5 * world.CELL_SIZE, 0}}
	world.window_update(&sp, &db, at(0), budget = max(int))
	testing.expect_value(t, live_set(&sp), bit_set[0 ..< 5]{0, 1})
	testing.expect_value(t, len(sp.loaded), 2)

	// A crossing retires what left at once and fills the rest nearest first, a budget per tick.
	for e in sp.changes {world.ref_event_destroy(e)}
	clear(&sp.changes)
	world.window_update(&sp, &db, at(3), budget = 1)
	testing.expect_value(t, live_set(&sp), bit_set[0 ..< 5]{3})
	testing.expect_value(t, len(sp.changes), 3)
	_, removed := sp.changes[0].(world.Cell_Removed)
	added, is_added := sp.changes[2].(world.Cell_Added)
	testing.expect(t, removed && is_added && added.cell == 103, "removals first, then the player's own cell")
	world.window_update(&sp, &db, at(3), budget = max(int))
	testing.expect_value(t, live_set(&sp), bit_set[0 ..< 5]{2, 3, 4})
	testing.expect(t, world.window_ready(&sp, &db, at(4)), "a live cell is ready")

	// A new worldspace retires every live cell, and main hears of each.
	for e in sp.changes {world.ref_event_destroy(e)}
	clear(&sp.changes)
	world.set_world(&sp, &db, WINDOW_WORLD + 1, 1)
	testing.expect_value(t, len(sp.cells), 0)
	testing.expect_value(t, len(sp.changes), 3)
	world.window_update(&sp, &db, at(3))
	testing.expect_value(t, len(sp.cells), 0) // the new worldspace has no grid cells here
}
