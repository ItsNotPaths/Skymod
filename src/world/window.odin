package world

// The sim's live window: the grid cells within `radius` of the player's cell are live, nearest made
// live first. Main hears of each change as a Cell_Added or Cell_Removed ref event.

import "core:log"
import "core:math"
import "core:slice"

import "../gamedb"
import smath "../math"

// WINDOW_BUDGET is how many cells one tick makes live, so a crossing fills over a few ticks.
WINDOW_BUDGET :: 2

Window :: struct {
	world_fid:  Form_ID, // the worldspace of the live grid cells; 0 = none
	radius:     int, // half-size in cells
	center:     Maybe([2]i32), // nil until the first update
	pending:    [dynamic]Form_ID, // cells to make live, nearest last
}

// set_world points the space at a worldspace: every live cell goes, and the worldspace's persistent
// refs are bucketed by grid cell.
set_world :: proc(sp: ^Space, db: ^gamedb.DB, world_fid: Form_ID, radius: int) {
	cells := make([dynamic]Form_ID, 0, len(sp.cells), context.temp_allocator)
	for cell in sp.cells {append(&cells, cell)}
	for cell in cells {drop_cell(sp, cell)}
	pending := sp.window.pending
	clear(&pending)
	sp.window = {world_fid = world_fid, radius = radius, pending = pending}
	n := index_persistent(sp, db, world_fid)
	log.infof("window: indexed %d persistent refs across %d grid cells", n, len(sp.persistent))
}

// window_update moves the window to the grid cell under `feet` and makes up to `budget` cells live.
window_update :: proc(sp: ^Space, db: ^gamedb.DB, feet: smath.Vec3, budget := WINDOW_BUDGET) {
	w := &sp.window
	if w.world_fid == 0 {return}
	if at := grid_of(feet); w.center != at {
		w.center = at
		replan(sp, db, at)
	}
	for n := 0; n < budget && len(w.pending) > 0; n += 1 {
		cell := pop(&w.pending)
		append(&sp.changes, Cell_Added{cell, placements(add_cell(sp, db, cell))})
	}
}

// window_ready is whether the grid cell under `pos` is live.
window_ready :: proc(sp: ^Space, db: ^gamedb.DB, pos: smath.Vec3) -> bool {
	return gamedb.cell_under(db, sp.window.world_fid, pos) in sp.cells
}

grid_of :: proc(pos: smath.Vec3) -> [2]i32 {
	return {i32(math.floor(pos.x / CELL_SIZE)), i32(math.floor(pos.y / CELL_SIZE))}
}

// replan drops the live grid cells outside the window and queues the missing ones, nearest last.
@(private = "file")
replan :: proc(sp: ^Space, db: ^gamedb.DB, center: [2]i32) {
	w := &sp.window
	r := i32(w.radius)
	gone := make([dynamic]Form_ID, 0, 16, context.temp_allocator)
	for cell, c in sp.cells {
		if c.has_grid && max(abs(c.gx - center.x), abs(c.gy - center.y)) > r {append(&gone, cell)}
	}
	for cell in gone {drop_cell(sp, cell)}

	Want :: struct {
		cell: Form_ID,
		dist: i32,
	}
	want := make([dynamic]Want, 0, (2 * r + 1) * (2 * r + 1), context.temp_allocator)
	for dy in -r ..= r {
		for dx in -r ..= r {
			cell, ok := gamedb.cell_at(db, w.world_fid, center.x + dx, center.y + dy)
			if ok && cell not_in sp.cells {append(&want, Want{cell, max(abs(dx), abs(dy))})}
		}
	}
	slice.sort_by(want[:], proc(a, b: Want) -> bool {return a.dist > b.dist})
	clear(&w.pending)
	for x in want {append(&w.pending, x.cell)}
}

// drop_cell retires a live cell and tells main.
@(private = "file")
drop_cell :: proc(sp: ^Space, cell: Form_ID) {
	remove_cell(sp, cell)
	append(&sp.changes, Cell_Removed{cell})
}
