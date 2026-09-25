package unit_tests

// Cell reset over a synthetic cell: the timer, the protections, Cell.Reset, cleared locations and
// merchant restocks.

import "core:testing"
import "../../src/formats/esm"
import "../../src/formid"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

@(private = "file")
F :: gamedb.Form_ID

@(private = "file")
CELL, ZONE, TOWN, HOUSE_LOC :: F(0x100), F(0x110), F(0x120), F(0x121)
@(private = "file")
PLAIN, NO_RESPAWN, BANDIT, UNIQUE, CHEST, SAFE, HELD :: F(0x201), F(0x202), F(0x203), F(0x204), F(0x205), F(0x206), F(0x207)
@(private = "file")
NPC_RESPAWN, NPC_UNIQUE, CONT_RESPAWN, CONT_SAFE, ITEM, QUEST :: F(0x301), F(0x302), F(0x303), F(0x304), F(0x305), F(0x400)

@(private = "file")
reset_db :: proc() -> gamedb.DB {
	a := context.temp_allocator
	db: gamedb.DB
	db.cells = make(map[F]gamedb.Cell, a)
	db.cells[CELL] = {form_id = CELL, interior = true, location = HOUSE_LOC}
	db.locations = make(map[F]gamedb.Location, a)
	db.locations[HOUSE_LOC] = {parent = TOWN}
	db.actors = make(map[F]gamedb.Actor_Base, a)
	db.actors[NPC_RESPAWN] = {flags = 0x8}
	db.actors[NPC_UNIQUE] = {}
	db.respawning_containers = make(map[F]bool, a)
	db.respawning_containers[CONT_RESPAWN] = true
	db.zones = make(map[F]gamedb.Zone, a)
	db.vendor_chests = make(map[F]bool, a)
	db.cell_refs = make(map[F][dynamic]gamedb.Ref, a)
	db.actor_refs = make(map[F][dynamic]gamedb.Ref, a)
	db.ref_by_id = make(map[F]gamedb.Ref, a)
	refs := []gamedb.Ref {
		{form_id = PLAIN, cell_form_id = CELL, base = ITEM},
		{form_id = NO_RESPAWN, cell_form_id = CELL, base = ITEM, no_respawn = true},
		{form_id = CHEST, cell_form_id = CELL, base = CONT_RESPAWN},
		{form_id = SAFE, cell_form_id = CELL, base = CONT_SAFE},
		{form_id = HELD, cell_form_id = CELL, base = ITEM},
	}
	actors := []gamedb.Ref{{form_id = BANDIT, cell_form_id = CELL, base = NPC_RESPAWN}, {form_id = UNIQUE, cell_form_id = CELL, base = NPC_UNIQUE}}
	db.cell_refs[CELL] = make([dynamic]gamedb.Ref, a)
	db.actor_refs[CELL] = make([dynamic]gamedb.Ref, a)
	for r in refs {append(&db.cell_refs[CELL], r);db.ref_by_id[r.form_id] = r}
	for r in actors {append(&db.actor_refs[CELL], r);db.ref_by_id[r.form_id] = r}
	return db
}

// dirty gives every ref in the cell state a reset would clear.
@(private = "file")
dirty :: proc(ws: ^worldstate.World_State) {
	for r in ([]F{PLAIN, NO_RESPAWN, HELD}) {worldstate.set_moved(ws, r, CELL, {}, {1, 2, 3})}
	worldstate.set_disabled(ws, PLAIN, CELL, true)
	for r in ([]F{BANDIT, UNIQUE}) {
		worldstate.set_dead(ws, r, CELL, true)
		worldstate.av_set_base(ws, r, "Health", 5)
	}
	for r in ([]F{CHEST, SAFE}) {worldstate.inv_add(ws, r, ITEM, 3)}
}

@(private = "file")
leave_for :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, hours: f64) {
	worldstate.leave_cell(ws, CELL)
	ws.clock.hours += hours
	script.enter_cell(db, ws, CELL)
}

@(test)
test_cell_reset_timer_and_protections :: proc(t: ^testing.T) {
	db := reset_db()
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	alias, _ := formid.alias_handle(QUEST, 0)
	worldstate.fill_alias(&ws, alias, HELD)
	dirty(&ws)

	leave_for(&db, &ws, 239)
	testing.expect(t, .Moved in ws.ref_deltas[PLAIN].live, "239 hours: no reset")
	testing.expect(t, CELL not_in ws.cells, "entering restarts the clock")

	leave_for(&db, &ws, 240)
	plain := ws.ref_deltas[PLAIN]
	testing.expect(t, .Moved not_in plain.live && .Disabled in plain.live, "moved resets, enable state stays")
	testing.expect(t, .Moved in ws.ref_deltas[NO_RESPAWN].live, "No Respawn keeps its state")
	testing.expect(t, .Moved in ws.ref_deltas[HELD].live, "an alias holder keeps its state")
	testing.expect(t, BANDIT not_in ws.ref_deltas && BANDIT not_in ws.actor_values, "a respawning actor lives again")
	testing.expect(t, .Dead in ws.ref_deltas[UNIQUE].live, "an actor without Respawn stays dead")
	testing.expect(t, CHEST not_in ws.inventories, "a Respawns container restocks")
	testing.expect_value(t, worldstate.inv_delta(&ws, SAFE, ITEM), 3)
	testing.expect_value(t, len(ws.rebuild_cells), 1)
}

@(test)
test_cell_reset_never_resets_and_cleared :: proc(t: ^testing.T) {
	db := reset_db()
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	// The cell's own zone (a player home), or a zone that names a parent location, protects it.
	(&db.cells[CELL]).zone = ZONE
	db.zones[ZONE] = {flags = esm.ECZN_NEVER_RESETS}
	dirty(&ws)
	leave_for(&db, &ws, 1000)
	testing.expect(t, .Moved in ws.ref_deltas[PLAIN].live, "a Never Resets zone")
	db.zones[ZONE] = {location = TOWN, flags = esm.ECZN_NEVER_RESETS}
	(&db.cells[CELL]).zone = 0
	leave_for(&db, &ws, 1000)
	testing.expect(t, .Moved in ws.ref_deltas[PLAIN].live, "a Never Resets parent location")

	// Cell.Reset overrides the zone and drops created refs, except one an alias holds.
	made := worldstate.create_ref(&ws, ITEM, CELL, {}, {}, 1)
	kept := worldstate.create_ref(&ws, ITEM, CELL, {}, {}, 1)
	alias, _ := formid.alias_handle(QUEST, 0)
	worldstate.fill_alias(&ws, alias, kept)
	c := script.Call{self = CELL, ws = &ws, db = &db}
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	script.call(&reg, "Cell", "Reset", &c, nil)
	leave_for(&db, &ws, 1)
	testing.expect(t, .Moved not_in ws.ref_deltas[PLAIN].live, "a scripted reset resets")
	testing.expect(t, made not_in ws.created && kept in ws.created, "created refs go, alias holders stay")

	// A cleared location waits 720 hours.
	delete_key(&db.zones, ZONE)
	c.self = TOWN
	script.call(&reg, "Location", "SetCleared", &c, nil)
	testing.expect(t, script.call(&reg, "Location", "IsCleared", &c, nil).(bool), "IsCleared reads SetCleared")
	dirty(&ws)
	leave_for(&db, &ws, 700)
	testing.expect(t, .Moved in ws.ref_deltas[PLAIN].live, "cleared: 700 hours is not enough")
	leave_for(&db, &ws, 720)
	testing.expect(t, .Moved not_in ws.ref_deltas[PLAIN].live, "cleared: 720 hours resets")
}

@(test)
test_vendor_restock :: proc(t: ^testing.T) {
	db := reset_db()
	db.vendor_chests[SAFE] = true
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	script.restock_vendors(&db, &ws)
	worldstate.inv_add(&ws, SAFE, ITEM, 3)
	ws.clock.hours = 47
	script.restock_vendors(&db, &ws)
	testing.expect_value(t, worldstate.inv_delta(&ws, SAFE, ITEM), 3)
	ws.clock.hours = 48
	script.restock_vendors(&db, &ws)
	testing.expect_value(t, worldstate.inv_delta(&ws, SAFE, ITEM), 0)
}

// ObjectReference.Reset resets the ref's state but not its scripts: vanilla calls it from inside
// OnReset, so restarting the caller would loop.
@(test)
test_ref_reset_keeps_scripts :: proc(t: ^testing.T) {
	db := reset_db()
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)

	dirty(&ws)
	c := script.Call{self = BANDIT, ws = &ws, db = &db}
	script.call(&reg, "ObjectReference", "Reset", &c, nil)
	testing.expect(t, BANDIT not_in ws.ref_deltas && BANDIT not_in ws.actor_values, "the actor is back to its baseline")
	testing.expect_value(t, len(ws.reset_refs), 0)
}

// The record flags sit at fixed DATA offsets: ECZN flags at byte 10 after owner and location, CONT
// flags at byte 0.
@(test)
test_reset_record_flags :: proc(t: ^testing.T) {
	eczn := []u8{0, 0, 0, 0, 0x21, 0x43, 0x01, 0x00, 0, 6, esm.ECZN_NEVER_RESETS, 30}
	z, ok := esm.encounter_zone([]esm.Field{{type = "DATA", data = eczn}})
	testing.expect(t, ok && z.flags == esm.ECZN_NEVER_RESETS && z.location == 0x14321, "ECZN location and Never Resets")
	testing.expect(t, z.min_level == 6 && z.max_level == 30, "ECZN levels")
	_, short := esm.encounter_zone([]esm.Field{{type = "DATA", data = eczn[:11]}})
	testing.expect(t, !short, "a short ECZN DATA is not read")
	testing.expect(t, esm.container_respawns([]esm.Field{{type = "DATA", data = {esm.CONT_RESPAWNS}}}), "CONT Respawns")
	testing.expect(t, !esm.container_respawns([]esm.Field{{type = "DATA", data = {0x01}}}), "CONT without Respawns")
}
