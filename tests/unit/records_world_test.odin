package unit_tests

import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/plugin"
import "../../src/worldhost"
import "../../src/worldstate"

@(test)
test_record_cell :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.cells)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.cells[0x3C] = {form_id = 0x3C, editor_id = "Riverwood", gx = 4, gy = -2, has_grid = true, music = 0x77}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	c: plugin.Cell
	testing.expect(t, plugin.record(&w, 0x3C, .Cell, &c), "found")
	testing.expect_value(t, string(plugin.items(c.editor_id)), "Riverwood")
	testing.expect_value(t, c.gy, -2)
	testing.expect_value(t, c.music, 0x77)
	testing.expect(t, !plugin.record(&w, 0x3D, .Cell, &c), "no such cell")
}

@(test)
test_record_location :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.locations)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	refs := []gamedb.Special_Ref{{ref_type = 0x10, ref = 0x20}}
	db.locations[0x50] = {parent = 0x51, special_refs = refs, crime_faction = 0x60}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	l: plugin.Location
	testing.expect(t, plugin.record(&w, 0x50, .Location, &l), "found")
	testing.expect_value(t, l.parent, 0x51)
	testing.expect_value(t, l.crime_faction, 0x60)
	s := plugin.items(l.special_refs)
	testing.expect_value(t, len(s), 1)
	testing.expect_value(t, s[0].ref, 0x20)
	testing.expect_value(t, l.master_refs.len, 0)
	testing.expect(t, !plugin.record(&w, 0x52, .Location, &l), "no such location")
}

@(test)
test_record_worldspace :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.worlds)
	defer delete(db.world_cells)
	defer delete(db.world_persist)
	defer delete(db.world_water)
	defer delete(db.world_music)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	cells: [dynamic]plugin.Form_ID
	defer delete(cells)
	append(&cells, 0xA1, 0xA2)
	db.worlds[0x3A] = "Tamriel"
	db.world_cells[0x3A] = cells
	db.world_persist[0x3A] = 0xA0
	db.world_water[0x3A] = -14000
	db.world_music[0x3A] = 0x99

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Worldspace
	testing.expect(t, plugin.record(&w, 0x3A, .Worldspace, &v), "found")
	testing.expect_value(t, string(plugin.items(v.editor_id)), "Tamriel")
	testing.expect_value(t, len(plugin.items(v.cells)), 2)
	testing.expect_value(t, plugin.items(v.cells)[1], 0xA2)
	testing.expect_value(t, v.persistent, 0xA0)
	testing.expect_value(t, v.water, -14000)
	testing.expect_value(t, v.music, 0x99)
	testing.expect_value(t, v.location, 0)
	testing.expect(t, !plugin.record(&w, 0x3B, .Worldspace, &v), "no such worldspace")
}

@(test)
test_record_weather :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.weathers)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	wt := gamedb.Weather{info = {wind_speed = 30}, has_fog = true, color_rows = 2}
	wt.fog.day_far = 5000
	wt.colors[1][2] = {1, 2, 3, 4}
	wt.imagespaces[3] = 0x44
	db.weathers[0x81] = wt

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Weather
	testing.expect(t, plugin.record(&w, 0x81, .Weather, &v), "found")
	testing.expect_value(t, v.info.wind_speed, 30)
	testing.expect_value(t, v.fog.day_far, 5000)
	testing.expect_value(t, v.colors[1][2][3], 4)
	testing.expect_value(t, v.color_rows, 2)
	testing.expect_value(t, v.imagespaces[3], 0x44)
	testing.expect(t, !plugin.record(&w, 0x82, .Weather, &v), "no such weather")
}

@(test)
test_record_placed_ref :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.ref_by_id)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.ref_by_id[0x900] = {form_id = 0x900, base = 0x12, pos = {1, 2, 3}, scale = 1.5, teleport = {door = 0x901}, has_tp = true, starts_dead = true}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	r: plugin.Placed_Ref
	testing.expect(t, plugin.record(&w, 0x900, .Placed_Ref, &r), "found")
	testing.expect_value(t, r.base, 0x12)
	testing.expect_value(t, r.pos.z, 3)
	testing.expect_value(t, r.scale, 1.5)
	testing.expect_value(t, r.teleport.door, 0x901)
	testing.expect(t, r.has_tp && r.starts_dead, "flags")
	testing.expect(t, !plugin.record(&w, 0x902, .Placed_Ref, &r), "no such ref")
}

@(test)
test_record_lock :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.locks)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.locks[0x900] = {level = 75, key = 0x33}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	l: plugin.Lock
	testing.expect(t, plugin.record(&w, 0x900, .Lock, &l), "found")
	testing.expect_value(t, l.level, 75)
	testing.expect_value(t, l.key, 0x33)
	testing.expect(t, !plugin.record(&w, 0x901, .Lock, &l), "no such lock")
}

@(test)
test_record_trigger :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.triggers)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.triggers[0x900] = {half = {10, 20, 30}, kind = .Sphere}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	p: plugin.Trigger
	testing.expect(t, plugin.record(&w, 0x900, .Trigger, &p), "found")
	testing.expect_value(t, p.kind, esm.Primitive_Kind.Sphere)
	testing.expect_value(t, p.half.y, 20)
	testing.expect(t, !plugin.record(&w, 0x901, .Trigger, &p), "no such trigger")
}

@(test)
test_record_linked_refs :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.linked_refs)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	links := []gamedb.Linked_Ref{{keyword = 0, ref = 0x901}, {keyword = 0x55, ref = 0x902}}
	db.linked_refs[0x900] = links

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	l: plugin.Linked_Refs
	testing.expect(t, plugin.record(&w, 0x900, .Linked_Refs, &l), "found")
	s := plugin.items(l.links)
	testing.expect_value(t, len(s), 2)
	testing.expect_value(t, s[1].keyword, 0x55)
	testing.expect_value(t, s[1].ref, 0x902)
	testing.expect(t, !plugin.record(&w, 0x901, .Linked_Refs, &l), "no links")
}

@(test)
test_record_form_scripts :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.form_scripts)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	props := []esm.Script_Prop {
		{name = "Count", kind = .Int, status = 1, value = i32(7)},
		{name = "Names", kind = .String_Array, status = 1, value = []string{"a", "bc"}},
		{name = "Target", kind = .Object, status = 1, value = esm.Prop_Object{form = 0x14, alias = -1}},
	}
	scripts := []esm.Script_Attach{{name = "DoorScript", props = props}}
	frags := []esm.Script_Fragment{{index = 10, script = "QF_Foo", function = "Fragment_0"}}
	aliases := []esm.Script_Attach{{name = "AliasScript"}}
	alias := []esm.Alias_Scripts{{owner = {form = 0x70, alias = 3}, scripts = aliases}}
	db.form_scripts[0x70] = {scripts = scripts, frag_file = "QF_Foo", fragments = frags, aliases = alias}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	f: plugin.Form_Scripts
	testing.expect(t, plugin.record(&w, 0x70, .Form_Scripts, &f), "found")
	s := plugin.items(f.scripts)
	testing.expect_value(t, len(s), 1)
	testing.expect_value(t, string(plugin.items(s[0].name)), "DoorScript")
	p := plugin.items(s[0].props)
	testing.expect_value(t, len(p), 3)
	testing.expect_value(t, p[0].int_value, 7)
	testing.expect_value(t, string(plugin.items(plugin.items(p[1].texts)[1])), "bc")
	testing.expect_value(t, p[2].object.form, 0x14)
	testing.expect_value(t, string(plugin.items(f.frag_file)), "QF_Foo")
	testing.expect_value(t, plugin.items(f.fragments)[0].index, 10)
	a := plugin.items(f.aliases)
	testing.expect_value(t, a[0].owner.alias, 3)
	testing.expect_value(t, string(plugin.items(plugin.items(a[0].scripts)[0].name)), "AliasScript")
	testing.expect(t, !plugin.record(&w, 0x71, .Form_Scripts, &f), "no scripts")
}
