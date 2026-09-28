package unit_tests

// world.Space bookkeeping without a physics world: cells made live from render chunks, refs found
// through the resident index after removals, and the collision store's three answers.

import "core:testing"
import "../../src/assetdb"
import "../../src/world"

@(private = "file")
chunk_of :: proc(cell: world.Form_ID, forms: ..world.Form_ID) -> world.Chunk {
	c := world.Chunk{cell_form_id = cell}
	for f in forms {append(&c.instances, world.Instance{form_id = f, base = f + 1000, scale = 1})}
	append(&c.actors, cell + 500)
	return c
}

@(test)
test_space_refs :: proc(t: ^testing.T) {
	sp: world.Space
	world.space_init(&sp, nil, nil, nil, false)
	defer world.space_destroy(&sp)

	a := chunk_of(1, 10, 11, 12)
	defer delete(a.instances)
	world.add_cell(&sp, nil, &a)
	testing.expect(t, a.actors == nil, "the cell takes the chunk's actors")
	testing.expect_value(t, len(sp.cells[1].actors), 1)

	r, c, ok := world.find_ref(&sp, 11)
	testing.expect(t, ok && r.base == 1011 && c.cell == 1, "a ref is found in its cell")

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

	b := chunk_of(1, 20)
	defer delete(b.instances)
	world.rebuild_cell(&sp, &b)
	_, _, old := world.find_ref(&sp, 11)
	_, _, fresh := world.find_ref(&sp, 20)
	testing.expect(t, !old && fresh, "a rebuild replaces the cell's refs")

	world.remove_cell(&sp, 1)
	testing.expect(t, len(sp.cells) == 0 && len(sp.resident) == 0, "a removed cell leaves no index entries")
	_, _, ok = world.find_ref(&sp, 20)
	testing.expect(t, !ok, "nothing is found in a removed cell")
}

@(test)
test_collision_store_answers :: proc(t: ^testing.T) {
	store: assetdb.Collision_Store
	assetdb.collision_store_init(&store, nil)
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
}
