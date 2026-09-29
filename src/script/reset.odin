package script

// Cell reset (CK wiki, Cell Reset): a cell the player re-enters after iHoursToRespawnCell (720 hours
// when its location is cleared) resets, unless its encounter zone never resets. Cell.Reset asks
// for a reset at the next entry, whatever the zone, and drops the cell's created refs too.

import "../audio"
import "../formid"
import "../gamedb"
import "../worldstate"

register_reset :: proc(reg: ^Registry) {
	register(reg, "Cell", "Reset", n_cell_reset)
	register(reg, "ObjectReference", "Reset", n_ref_reset)
	register(reg, "Location", "SetCleared", n_location_set_cleared)
	register(reg, "Location", "IsCleared", n_location_is_cleared)
}

// enter_cell resets `cell` if its time has come. Entering restarts its clock.
enter_cell :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, cell: Form_ID) {
	s, left := ws.cells[cell]
	if !left {return}
	delete_key(&ws.cells, cell)
	if !s.reset_asked && !reset_due(db, ws, cell, s.left) {return}
	for list in ([2][]gamedb.Ref{gamedb.refs_of(db, cell), gamedb.actors_of(db, cell)}) {
		for r in list {
			if !gamedb.ref_respawns(db, r) {continue}
			reset_ref(db, ws, r)
			if !worldstate.is_dead(ws, db, r.form_id) {
				for loc in gamedb.special_ref_locations(db, r.form_id, formid.LOC_REF_BOSS) {delete_key(&ws.cleared, loc)} // it respawned (CK IsCleared)
			}
		}
	}
	if s.reset_asked {drop_created(db, ws, cell)}
	append(&ws.rebuild_cells, cell)
}

// reset_due: a timed reset needs a zone that resets and enough game hours since `left`.
@(private)
reset_due :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, cell: Form_ID, left: f64) -> bool {
	if gamedb.cell_never_resets(db, cell) {return false}
	hours := ws.clock.hours - left
	if location_cleared(db, ws, gamedb.cell_location(db, cell)) {
		return hours >= f64(gamedb.setting_int(db, "iHoursToRespawnCellCleared", 720))
	}
	return hours >= f64(gamedb.setting_int(db, "iHoursToRespawnCell", 240))
}

@(private)
location_cleared :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, loc: Form_ID) -> bool {
	if loc == 0 {return false}
	for l in ws.cleared {
		if gamedb.location_within(db, loc, l) {return true}
	}
	return false
}

// reset_ref puts one ref back to its baseline and restarts its scripts. A ref a quest alias holds,
// one that carries a Quest Object, or one a script deleted stays as it is.
@(private)
reset_ref :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, r: gamedb.Ref) {
	if kept(db, ws, r.form_id) || worldstate.is_deleted(ws, r.form_id) {return}
	_, is_actor := db.actors[r.base]
	worldstate.reset_ref_state(ws, r.form_id, is_actor || db.respawning_containers[r.base])
	worldstate.restart_scripts(ws, r.form_id)
}

// drop_created removes the refs made in `cell`, except kept ones.
@(private)
drop_created :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, cell: Form_ID) {
	gone := make([dynamic]Form_ID, context.temp_allocator)
	for id in worldstate.created_in(ws, cell) {
		if !kept(db, ws, id) {append(&gone, id)}
	}
	for id in gone {worldstate.remove_created(ws, id)}
}

// kept: a ref an alias holds, or a container with a Quest Object in it, never resets.
@(private)
kept :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, form: Form_ID) -> bool {
	return len(worldstate.aliases_of(ws, form)) > 0 || worldstate.holds_quest_object(ws, db, form)
}

// restock_vendors empties what the player changed in each merchant chest every iDaysToRespawnVendor
// days, whatever its cell does.
restock_vendors :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State) {
	every := f64(gamedb.setting_int(db, "iDaysToRespawnVendor", 2)) * 24
	now := ws.clock.hours
	for chest in db.vendor_chests {
		last, seen := ws.restocks[chest]
		if seen && now - last < every {continue}
		ws.restocks[chest] = now
		if seen {worldstate.drop_inventory(ws, chest)}
	}
}

// Cell.Reset: an exterior cannot be reset by a script (CK wiki).
n_cell_reset :: proc(c: ^Call, args: []Value) -> Value {
	if cell, ok := c.db.cells[c.self]; ok && cell.interior {worldstate.ask_reset(c.ws, c.self)}
	return nil
}

// ObjectReference.Reset(akTarget): the ref goes back to its baseline at once, at akTarget when given.
// A script asks for this ref, so the respawn flags do not apply. Its scripts keep running and get
// no OnReset: vanilla calls Reset from inside OnReset (dunRaldbtharPuzzleGearBlockerScript).
n_ref_reset :: proc(c: ^Call, args: []Value) -> Value {
	if c.self == c.ws.player {return nil}
	was := worldstate.ref_cell(c.ws, c.db, c.self)
	worldstate.reset_ref_state(c.ws, c.self, true)
	if target := arg_form(c, args, 0); target != 0 {move_to(c, c.self, target, {})}
	append(&c.ws.rebuild_cells, was)
	if now := worldstate.ref_cell(c.ws, c.db, c.self); now != was {append(&c.ws.rebuild_cells, now)}
	return nil
}

// boss_died clears each location whose Boss refs are all dead now (CK IsCleared: "whenever all
// enemies that have a Boss LocationRefType assigned to them is killed").
boss_died :: proc(c: ^Call, ref: Form_ID) {
	for loc in gamedb.special_ref_locations(c.db, ref, formid.LOC_REF_BOSS) {
		all_dead := true
		for boss in gamedb.location_special_refs(c.db, loc, formid.LOC_REF_BOSS) {
			if !worldstate.is_dead(c.ws, c.db, boss) {all_dead = false}
		}
		if !all_dead || c.ws.cleared[loc] {continue}
		c.ws.cleared[loc] = true
		if c.audio != nil {audio.music_add(c.audio, gamedb.default_object(c.db, "DCMS"))}
	}
}

n_location_set_cleared :: proc(c: ^Call, args: []Value) -> Value {
	if arg_bool(args, 0, true) {
		c.ws.cleared[c.self] = true
	} else {
		delete_key(&c.ws.cleared, c.self)
	}
	return nil
}

n_location_is_cleared :: proc(c: ^Call, args: []Value) -> Value {
	return c.ws.cleared[c.self]
}
