package unit_tests

import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/plugin"
import "../../src/worldhost"
import "../../src/worldstate"

@(test)
test_record_actor_base :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.actors)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	spells := []gamedb.Form_ID{0x5A, 0x5B}
	inv := []gamedb.Content_Entry{{item = 0xF, count = 100}}
	facs := []gamedb.Faction_Membership{{faction = 0x13, rank = -1}}
	db.actors[0x7] = {level = 3, race = 0x13746, spells = spells, overrides = {guard_warn = 0x99}, inventory = inv, factions = facs, crime_faction = 0x28}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	a: plugin.Actor_Base
	testing.expect(t, plugin.record(&w, 0x7, .Actor_Base, &a), "found")
	testing.expect_value(t, a.level, 3)
	testing.expect_value(t, a.race, 0x13746)
	testing.expect_value(t, len(plugin.items(a.spells)), 2)
	testing.expect_value(t, a.overrides.guard_warn, 0x99)
	testing.expect_value(t, plugin.items(a.inventory)[0].count, 100)
	testing.expect_value(t, plugin.items(a.factions)[0].rank, -1)
	testing.expect_value(t, a.crime_faction, 0x28)
	testing.expect(t, !plugin.record(&w, 0x8, .Actor_Base, &a), "no such actor")
}

@(test)
test_record_race :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.races)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.races[0x13746] = {info = {health = 50}, description = "Nords", spells = []gamedb.Form_ID{0x1}, skeletons = {"m.nif", "f.nif"}, voices = {0x2, 0x3}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	r: plugin.Race
	testing.expect(t, plugin.record(&w, 0x13746, .Race, &r), "found")
	testing.expect_value(t, r.info.health, 50)
	testing.expect_value(t, string(plugin.items(r.description)), "Nords")
	testing.expect_value(t, string(plugin.items(r.skeletons[1])), "f.nif")
	testing.expect_value(t, plugin.items(r.spells)[0], 0x1)
	testing.expect_value(t, r.voices[1], 0x3)
	testing.expect(t, !plugin.record(&w, 0x13747, .Race, &r), "no such race")
}

@(test)
test_record_class :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.classes)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.classes[0x10] = {info = {training_level = 50}, description = "warrior"}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	c: plugin.Class
	testing.expect(t, plugin.record(&w, 0x10, .Class, &c), "found")
	testing.expect_value(t, c.info.training_level, 50)
	testing.expect_value(t, string(plugin.items(c.description)), "warrior")
	testing.expect(t, !plugin.record(&w, 0x11, .Class, &c), "no such class")
}

@(test)
test_record_faction :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.factions)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	rel := []gamedb.Faction_Relation{{faction = 0x20, modifier = -10, combat = .Enemy}}
	ranks := []gamedb.Faction_Rank{{index = 0, male_title = "Thane", female_title = "Thane"}}
	cond := []gamedb.Condition{{function = 72}}
	db.factions[0x13] = {flags = 1, relations = rel, ranks = ranks, crime = {murder = 1000}, has_crime = true, vendor = {start = 8, end = 20, conditions = cond}, jail = 0x40}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	f: plugin.Faction
	testing.expect(t, plugin.record(&w, 0x13, .Faction, &f), "found")
	testing.expect_value(t, plugin.items(f.relations)[0].combat, esm.Combat_Reaction.Enemy)
	testing.expect_value(t, string(plugin.items(plugin.items(f.ranks)[0].male_title)), "Thane")
	testing.expect_value(t, f.crime.murder, 1000)
	testing.expect_value(t, f.vendor.end, 20)
	testing.expect_value(t, plugin.items(f.vendor.conditions)[0].function, 72)
	testing.expect_value(t, f.jail, 0x40)
	testing.expect(t, !plugin.record(&w, 0x14, .Faction, &f), "no such faction")
}

@(test)
test_record_actor_value_info :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.actor_value_info)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.actor_value_info[0x44C] = {index = 10, has_index = true, editor_id = "AVOneHanded", skill = {use_mult = 6.3}, has_skill = true}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	a: plugin.Actor_Value_Info
	testing.expect(t, plugin.record(&w, 0x44C, .Actor_Value_Info, &a), "found")
	testing.expect_value(t, a.index, 10)
	testing.expect_value(t, string(plugin.items(a.editor_id)), "AVOneHanded")
	testing.expect_value(t, a.skill.use_mult, 6.3)
	testing.expect(t, !plugin.record(&w, 0x44D, .Actor_Value_Info, &a), "no such actor value")
}

@(test)
test_record_perk :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.perks)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	take := []gamedb.Condition{{function = 370, value = 30}}
	tabs := []gamedb.Perk_Tab{{tab = 1, conditions = take}}
	entries := []gamedb.Perk_Entry{{kind = .Entry_Point, point = .Mod_Buy_Prices, function = .Multiply_Value, values = {0.9, 0}, tabs = tabs}}
	db.perks[0xBE128] = {name = "Haggling", next_rank = 0xC07CE, playable = true, take_conditions = take, entries = entries}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	p: plugin.Perk
	testing.expect(t, plugin.record(&w, 0xBE128, .Perk, &p), "found")
	testing.expect_value(t, string(plugin.items(p.name)), "Haggling")
	testing.expect_value(t, p.next_rank, 0xC07CE)
	testing.expect_value(t, plugin.items(p.take_conditions)[0].value, 30)
	e := plugin.items(p.entries)
	testing.expect_value(t, len(e), 1)
	testing.expect_value(t, e[0].point, u8(gamedb.Entry_Point.Mod_Buy_Prices))
	testing.expect_value(t, e[0].values[0], 0.9)
	testing.expect_value(t, plugin.items(e[0].tabs)[0].tab, 1)
	testing.expect(t, !plugin.record(&w, 0xBE129, .Perk, &p), "no such perk")
}

@(test)
test_record_perk_tree :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.perk_trees)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	links := []u32{1}
	db.perk_trees[0x44C] = []gamedb.Perk_Node{{index = 0, connections = links}, {perk = 0xBABE4, index = 1, grid = {2, 3}}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	p: plugin.Perk_Tree
	testing.expect(t, plugin.record(&w, 0x44C, .Perk_Tree, &p), "found")
	n := plugin.items(p.nodes)
	testing.expect_value(t, len(n), 2)
	testing.expect_value(t, plugin.items(n[0].connections)[0], 1)
	testing.expect_value(t, n[1].perk, 0xBABE4)
	testing.expect_value(t, n[1].grid[1], 3)
	testing.expect(t, !plugin.record(&w, 0x44D, .Perk_Tree, &p), "no such tree")
}

@(test)
test_record_package :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.packages)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	inputs := []gamedb.Package_Input{
		{index = 0, kind = .Float, value = f32(350)},
		{index = 1, kind = .Location, value = gamedb.Package_Location{kind = .NearRef, form = 0x50, radius = 256}},
	}
	tree := []gamedb.Package_Node{{branch = .Procedure, procedure = "Sandbox", end = 1, inputs = []u8{1}, override = gamedb.Package_Flag_Override{set_flags = 4}}}
	db.packages[0x60] = {type = 19, speed = .Run, schedule = {hour = 8, duration = 120}, idle = {idles = []gamedb.Form_ID{0x70}}, inputs = inputs, tree = tree}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	p: plugin.Package
	testing.expect(t, plugin.record(&w, 0x60, .Package, &p), "found")
	testing.expect_value(t, p.speed, u8(gamedb.Package_Speed.Run))
	testing.expect_value(t, p.schedule.duration, 120)
	testing.expect_value(t, plugin.items(p.idle.idles)[0], 0x70)
	in_ := plugin.items(p.inputs)
	testing.expect_value(t, in_[0].float_value, 350)
	testing.expect_value(t, in_[1].location.form, 0x50)
	testing.expect_value(t, in_[1].location.radius, 256)
	n := plugin.items(p.tree)[0]
	testing.expect_value(t, string(plugin.items(n.procedure)), "Sandbox")
	testing.expect(t, n.has_override, "override")
	testing.expect_value(t, n.override.set_flags, 4)
	testing.expect(t, !plugin.record(&w, 0x61, .Package, &p), "no such package")
}

@(test)
test_record_zone :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.zones)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.zones[0x80] = {location = 0x81, min_level = 5, max_level = 20, flags = 2}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	z: plugin.Zone
	testing.expect(t, plugin.record(&w, 0x80, .Zone, &z), "found")
	testing.expect_value(t, z.location, 0x81)
	testing.expect_value(t, z.max_level, 20)
	testing.expect(t, !plugin.record(&w, 0x82, .Zone, &z), "no such zone")
}

@(test)
test_record_equip_slot :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.equip_slots)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.equip_slots[0x12EB7] = {kind = .Weapon, etyp = gamedb.EQUP_RIGHT_HAND, weapon_type = 1, damage = 7}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	e: plugin.Equip_Slot
	testing.expect(t, plugin.record(&w, 0x12EB7, .Equip_Slot, &e), "found")
	testing.expect_value(t, e.kind, u8(gamedb.Equip_Kind.Weapon))
	testing.expect_value(t, e.etyp, gamedb.EQUP_RIGHT_HAND)
	testing.expect_value(t, e.damage, 7)
	testing.expect(t, !plugin.record(&w, 0x12EB8, .Equip_Slot, &e), "no such slot")
}

@(test)
test_record_equip_type :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.equip_types)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.equip_types[0x13F45] = {parents = []gamedb.Form_ID{gamedb.EQUP_RIGHT_HAND, gamedb.EQUP_LEFT_HAND}, use_all = true}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	e: plugin.Equip_Type
	testing.expect(t, plugin.record(&w, 0x13F45, .Equip_Type, &e), "found")
	testing.expect(t, e.use_all, "use_all")
	testing.expect_value(t, plugin.items(e.parents)[1], gamedb.EQUP_LEFT_HAND)
	testing.expect(t, !plugin.record(&w, 0x13F46, .Equip_Type, &e), "no such type")
}

@(test)
test_record_movement :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.movement)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.movement[0x90] = {80, 370}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	m: plugin.Movement
	testing.expect(t, plugin.record(&w, 0x90, .Movement, &m), "found")
	testing.expect_value(t, m.speed, [2]f32{80, 370})
	testing.expect(t, !plugin.record(&w, 0x91, .Movement, &m), "no such movement")
}
