package script

// Game.FindClosest* and FindRandom*: a search of the loaded refs around a point. A loaded ref is
// enabled, not carried, and in a cell attached to the player's scene. Dead actors and the player
// count (CK wiki, build/out/wsQ/wiki/Find*).

import "core:math/rand"
import "../gamedb"
import smath "../math"
import "../worldstate"

register_find :: proc(reg: ^Registry) {
	register(reg, "Game", "FindClosestReferenceOfType", n_find_closest_of_type)
	register(reg, "Game", "FindRandomReferenceOfType", n_find_random_of_type)
	register(reg, "Game", "FindClosestReferenceOfAnyTypeInList", n_find_closest_in_list)
	register(reg, "Game", "FindRandomReferenceOfAnyTypeInList", n_find_random_in_list)
	register(reg, "Game", "FindClosestActor", n_find_closest_actor)
	register(reg, "Game", "FindRandomActor", n_find_random_actor)
}

n_find_closest_of_type :: proc(c: ^Call, args: []Value) -> Value {return find(c, args, is_base, false)}
n_find_random_of_type :: proc(c: ^Call, args: []Value) -> Value {return find(c, args, is_base, true)}
n_find_closest_in_list :: proc(c: ^Call, args: []Value) -> Value {return find(c, args, in_list, false)}
n_find_random_in_list :: proc(c: ^Call, args: []Value) -> Value {return find(c, args, in_list, true)}
n_find_closest_actor :: proc(c: ^Call, args: []Value) -> Value {return find(c, args, is_actor, false)}
n_find_random_actor :: proc(c: ^Call, args: []Value) -> Value {return find(c, args, is_actor, true)}

@(private = "file")
Match :: #type proc(c: ^Call, want, base: Form_ID) -> bool

@(private = "file")
is_base :: proc(c: ^Call, want, base: Form_ID) -> bool {return base == want}
@(private = "file")
in_list :: proc(c: ^Call, want, base: Form_ID) -> bool {return worldstate.list_has(c.ws, c.db, want, base)}
@(private = "file")
is_actor :: proc(c: ^Call, want, base: Form_ID) -> bool {return gamedb.is_actor(c.db, base)}

@(private = "file")
Search :: struct {
	match:  Match,
	want:   Form_ID,
	center: smath.Vec3,
	radius: f32,
	random: bool,
	found:  Form_ID,
	best:   f32,
	seen:   int,
}

// find reads (form, x, y, z, radius), or (x, y, z, radius) for actors. It visits the attached
// cells' placed refs, the persistent refs of their worldspace, the overlay's refs and the created
// refs; consider drops what is not loaded.
@(private = "file")
find :: proc(c: ^Call, args: []Value, match: Match, random: bool) -> Value {
	at := 0 if match == is_actor else 1
	s := Search {
		match  = match,
		want   = arg_form(args, 0),
		center = {arg_f32(args, at, 0), arg_f32(args, at + 1, 0), arg_f32(args, at + 2, 0)},
		radius = arg_f32(args, at + 3, 0),
		random = random,
		best   = max(f32),
	}
	world: Form_ID
	for cell in c.ws.attached {
		consider_placed(c, &s, cell)
		if info, ok := gamedb.cell_by_formid(c.db, cell); ok && !info.interior {world = info.world_form_id}
	}
	if pcell, ok := gamedb.world_persistent_cell(c.db, world); ok {consider_placed(c, &s, pcell)}
	for id in c.ws.ref_deltas {consider(c, &s, id)}
	for id in c.ws.created {
		if id not_in c.ws.ref_deltas {consider(c, &s, id)}
	}
	return form_or_none(s.found)
}

// consider_placed visits a cell's baseline refs and actors; one with a delta is visited from the overlay.
@(private = "file")
consider_placed :: proc(c: ^Call, s: ^Search, cell: Form_ID) {
	for list in ([2][]gamedb.Ref{gamedb.refs_of(c.db, cell), gamedb.actors_of(c.db, cell)}) {
		for r in list {
			if r.form_id not_in c.ws.ref_deltas {consider(c, s, r.form_id)}
		}
	}
}

// consider keeps a loaded match in range: the closest, or one picked uniformly (reservoir sampling).
@(private = "file")
consider :: proc(c: ^Call, s: ^Search, id: Form_ID) {
	if !s.match(c, s.want, worldstate.ref_base(c.ws, c.db, id)) {return}
	d := smath.length3(worldstate.ref_pos(c.ws, c.db, id) - s.center)
	if d > s.radius || worldstate.ref_grid_cell(c.ws, c.db, id) not_in c.ws.attached {return}
	if id in c.ws.carried || worldstate.is_deleted(c.ws, id) || !worldstate.ref_enabled(c.ws, c.db, id) {return}
	s.seen += 1
	keep := rand.int_max(s.seen) == 0 if s.random else d < s.best
	if keep {s.found, s.best = id, d}
}
