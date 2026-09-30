package unit_tests

import "core:os"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import ws "../../src/worldstate"

CRIME_TOWN :: ws.Form_ID(0x000267EA)
CRIME_THIEF :: ws.Form_ID(0x000A0100)
CRIME_GUARD :: ws.Form_ID(0x000A0101)
CRIME_CITIZEN :: ws.Form_ID(0x000A0102)

// A local bounty belongs to its knower; the faction-wide one to every member; the higher counts.
@(test)
test_crime_bounty_store :: proc(t: ^testing.T) {
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	ws.set_crime_faction(&s, CRIME_CITIZEN, CRIME_TOWN)

	ws.learn_bounty(&s, nil, CRIME_CITIZEN, CRIME_THIEF, {violent = 40})
	testing.expect_value(t, ws.bounty(&s, nil, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{violent = 40})
	testing.expect_value(t, ws.bounty(&s, nil, CRIME_GUARD, CRIME_THIEF), ws.Bounty{})

	ws.learn_bounty(&s, nil, CRIME_CITIZEN, CRIME_THIEF, {nonviolent = 5}) // lower: the known one stays
	testing.expect_value(t, ws.bounty(&s, nil, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{violent = 40})

	ws.set_faction_bounty(&s, CRIME_THIEF, CRIME_TOWN, {nonviolent = 100})
	testing.expect_value(t, ws.bounty(&s, nil, CRIME_GUARD, CRIME_THIEF), ws.Bounty{nonviolent = 100})
	testing.expect_value(t, ws.bounty(&s, nil, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{nonviolent = 100})

	// A save keeps both kinds.
	path := "test_crime.skysave"
	defer os.remove(path)
	testing.expect(t, ws.save_to_file(&s, path, ws.Save_Manifest{}), "save failed")
	d: ws.World_State
	ws.init(&d)
	defer ws.destroy(&d)
	_, ok := ws.load_from_file(&d, path)
	testing.expect(t, ok, "load failed")
	testing.expect_value(t, ws.wanted(&d, CRIME_THIEF, CRIME_TOWN).bounty, ws.Bounty{nonviolent = 100})
	testing.expect_value(t, d.known_bounties[{CRIME_CITIZEN, CRIME_THIEF}], ws.Known_Bounty{CRIME_TOWN, {violent = 40}})

	// Paying clears the faction's bounty and what its members knew.
	ws.pay_bounty(&s, nil, CRIME_THIEF, CRIME_TOWN)
	testing.expect_value(t, ws.bounty(&s, nil, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{})
	testing.expect_value(t, len(s.wanted), 0)
}

// A script's SetEnemy between two factions turns their members hostile, one direction at a time.
@(test)
test_faction_relation_delta :: proc(t: ^testing.T) {
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	a_fac, b_fac := ws.Form_ID(0x000FA001), ws.Form_ID(0x000FA002)
	ws.faction_set_rank(&s, CRIME_GUARD, a_fac, 0)
	ws.faction_set_rank(&s, CRIME_THIEF, b_fac, 0)
	testing.expect_value(t, ws.faction_relation(&s, nil, CRIME_GUARD, CRIME_THIEF), esm.Combat_Reaction.Neutral)

	ws.set_relation(&s, a_fac, b_fac, {combat = .Enemy, modifier = -10})
	testing.expect_value(t, ws.faction_relation(&s, nil, CRIME_GUARD, CRIME_THIEF), esm.Combat_Reaction.Enemy)
	testing.expect_value(t, ws.faction_relation(&s, nil, CRIME_THIEF, CRIME_GUARD), esm.Combat_Reaction.Neutral)
	r, ok := ws.relation(&s, nil, a_fac, b_fac)
	testing.expect(t, ok && r.modifier == -10 && r.faction == b_fac, "relation delta read back")
}

// SetPlayerEnemy's flag makes every member of that crime faction hostile to the offender.
@(test)
test_crime_enemy_is_hostile :: proc(t: ^testing.T) {
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	testing.expect(t, !ws.hostile(&s, nil, CRIME_GUARD, CRIME_THIEF), "not hostile before")
	ws.set_wanted(&s, CRIME_THIEF, CRIME_TOWN, {enemy = true})
	testing.expect(t, ws.hostile(&s, nil, CRIME_GUARD, CRIME_THIEF), "enemy flag makes members hostile")
	testing.expect(t, !ws.hostile(&s, nil, CRIME_CITIZEN, CRIME_THIEF), "a non-member is not")
}

// A witness that detects the offender, and the victim of a violent crime, learn the faction's
// CRVA bounty; a theft is worth the item's value times the steal multiplier.
@(test)
test_crime_report :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.factions)
	db.factions[CRIME_TOWN] = {flags = esm.FACT_TRACK_CRIME, has_crime = true, crime = {murder = 1000, assault = 40, steal_multiplier = 0.5}}
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	ws.set_crime_faction(&s, CRIME_CITIZEN, CRIME_TOWN)
	posted := ws.Form_ID(0x000A0104) // a guard nobody meets, so bounties stay local
	ws.set_crime_faction(&s, posted, CRIME_TOWN)
	ws.faction_set_rank(&s, posted, 0x86EEE, 0)

	testing.expect_value(t, ws.report_crime(&s, &db, CRIME_THIEF, CRIME_CITIZEN, .Steal, 100), ws.Crime_Status.Unreported)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{}) // an owner sees nothing

	ws.set_awareness(&s, CRIME_GUARD, CRIME_THIEF, {level = 1, detected = true})
	testing.expect_value(t, ws.report_crime(&s, &db, CRIME_THIEF, CRIME_CITIZEN, .Steal, 100), ws.Crime_Status.Reported)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_GUARD, CRIME_THIEF), ws.Bounty{nonviolent = 50})

	testing.expect_value(t, ws.report_crime(&s, &db, CRIME_THIEF, CRIME_CITIZEN, .Assault, 0), ws.Crime_Status.Reported)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_GUARD, CRIME_THIEF), ws.Bounty{violent = 40, nonviolent = 50})
	testing.expect_value(t, s.story_events[len(s.story_events) - 1].type, ws.STORY_ASSAULT)
	// The victim turns witness VICTIM_DELAY later.
	ws.tick_crime(&s, &db, 1)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{})
	ws.tick_crime(&s, &db, 1.5)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_CITIZEN, CRIME_THIEF), ws.Bounty{violent = 40})
	// A victim dead before then never does.
	victim2 := ws.Form_ID(0x000A0103)
	ws.set_crime_faction(&s, victim2, CRIME_TOWN)
	ws.report_crime(&s, &db, CRIME_THIEF, victim2, .Assault, 0)
	ws.set_dead(&s, victim2, 0x0004DEAD, true)
	ws.tick_crime(&s, &db, 3)
	testing.expect_value(t, ws.bounty(&s, &db, victim2, CRIME_THIEF), ws.Bounty{})
	testing.expect_value(t, len(s.victim_waits), 0)

	// Fighting an enemy is no crime.
	ws.set_wanted(&s, CRIME_THIEF, CRIME_TOWN, {enemy = true})
	testing.expect_value(t, ws.report_crime(&s, &db, CRIME_THIEF, CRIME_CITIZEN, .Assault, 0), ws.Crime_Status.None)
}

// A local bounty spreads to the members a knower detects. It goes faction-wide at a guard, or at
// half the living members in a faction with no guard; a dead knower's bounty goes with it.
@(test)
test_crime_spread :: proc(t: ^testing.T) {
	BASE :: gamedb.Form_ID(0x000B0001)
	WILD :: gamedb.Form_ID(0x000FB001) // no guards
	db: gamedb.DB
	defer {delete(db.actors);delete(db.ref_by_id);for _, r in db.actor_refs {delete(r)};delete(db.actor_refs)}
	db.actors[BASE] = {crime_faction = WILD}
	members := [4]gamedb.Form_ID{0x000C0001, 0x000C0002, 0x000C0003, 0x000C0004}
	db.actor_refs[0x0004CE11] = make([dynamic]gamedb.Ref)
	for m in members {
		append(&db.actor_refs[0x0004CE11], gamedb.Ref{form_id = m, base = BASE})
		db.ref_by_id[m] = {form_id = m, base = BASE}
	}
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)

	ws.learn_bounty(&s, &db, members[0], CRIME_THIEF, {violent = 40})
	ws.tick_crime(&s, &db, ws.SPREAD_EVERY)
	testing.expect_value(t, ws.wanted(&s, CRIME_THIEF, WILD).bounty, ws.Bounty{}) // 1 of 4 knows
	ws.set_awareness(&s, members[0], members[1], {level = 1, detected = true})
	ws.tick_crime(&s, &db, ws.SPREAD_EVERY)
	testing.expect_value(t, ws.wanted(&s, CRIME_THIEF, WILD).bounty, ws.Bounty{violent = 40}) // 2 of 4
	testing.expect_value(t, len(s.known_bounties), 0)
	testing.expect_value(t, ws.bounty(&s, &db, members[3], CRIME_THIEF), ws.Bounty{violent = 40})

	// A guard of the faction makes it wide at once; a dead knower forgets.
	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	ws.set_crime_faction(&s, CRIME_CITIZEN, CRIME_TOWN)
	ws.faction_set_rank(&s, CRIME_GUARD, 0x86EEE, 0) // IsGuardFaction
	ws.learn_bounty(&s, &db, CRIME_CITIZEN, 0x000C00FF, {nonviolent = 5})
	ws.set_dead(&s, CRIME_CITIZEN, 0x0004CE11, true)
	ws.tick_crime(&s, &db, ws.SPREAD_EVERY)
	testing.expect_value(t, len(s.known_bounties), 0)
	ws.learn_bounty(&s, &db, CRIME_GUARD, CRIME_THIEF, {nonviolent = 5})
	ws.tick_crime(&s, &db, ws.SPREAD_EVERY)
	testing.expect_value(t, ws.wanted(&s, CRIME_THIEF, CRIME_TOWN).bounty, ws.Bounty{nonviolent = 5})
}

// A take robs the ref's owner, else its cell's; the owner's own base and its faction's members
// take freely.
@(test)
test_crime_robbed :: proc(t: ^testing.T) {
	CELL :: gamedb.Form_ID(0x0004CE12)
	SHOP :: gamedb.Form_ID(0x000FB002) // an owning faction
	SHOPKEEP_BASE :: gamedb.Form_ID(0x000B0002)
	CHEST, LOOSE, KEEPER :: gamedb.Form_ID(0x000D0001), gamedb.Form_ID(0x000D0002), gamedb.Form_ID(0x000D0003)
	db: gamedb.DB
	defer {delete(db.owners);delete(db.ref_by_id);delete(db.factions)}
	db.factions[SHOP] = {}
	db.ref_by_id[CHEST] = {form_id = CHEST, cell_form_id = CELL}
	db.ref_by_id[LOOSE] = {form_id = LOOSE, cell_form_id = CELL}
	db.ref_by_id[KEEPER] = {form_id = KEEPER, base = SHOPKEEP_BASE, cell_form_id = CELL}
	db.owners[CHEST] = SHOPKEEP_BASE
	db.owners[CELL] = SHOP
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)

	testing.expect_value(t, ws.robbed(&s, &db, CRIME_THIEF, CHEST), SHOPKEEP_BASE)
	testing.expect_value(t, ws.robbed(&s, &db, KEEPER, CHEST), gamedb.Form_ID(0))
	testing.expect_value(t, ws.robbed(&s, &db, CRIME_THIEF, LOOSE), SHOP) // the cell's owner
	ws.faction_set_rank(&s, CRIME_THIEF, SHOP, 0)
	testing.expect_value(t, ws.robbed(&s, &db, CRIME_THIEF, LOOSE), gamedb.Form_ID(0))
}

// A faction with a jail queues the actor; serving skips the clock to the sentence's end, which
// queues the release; a 7-day sentence clears every skill's progress.
@(test)
test_crime_jail :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.factions)
	db.factions[CRIME_TOWN] = {jail = 0x000267E5}
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)

	testing.expect_value(t, ws.jail_days({nonviolent = 40}), i32(1))
	testing.expect_value(t, ws.jail_days({violent = 1000, nonviolent = 5}), i32(7))
	testing.expect(t, !ws.send_to_jail(&s, &db, CRIME_THIEF, 0x000FB009, CRIME_GUARD), "no jail, no order")
	testing.expect(t, ws.send_to_jail(&s, &db, CRIME_THIEF, CRIME_TOWN, CRIME_GUARD), "jail ordered")
	testing.expect_value(t, s.jail_orders[0], ws.Jail_Order{actor = CRIME_THIEF, faction = CRIME_TOWN, guard = CRIME_GUARD})
	clear(&s.jail_orders)

	// What the app does on the way in, then the bed.
	s.jailed[CRIME_THIEF] = {faction = CRIME_TOWN, cell = 0x0004CE13, until = s.clock.hours + 48}
	ws.tick_crime(&s, &db, 0.1)
	testing.expect(t, CRIME_THIEF in s.jailed, "not there yet: no escape")
	ws.relocate(&s, CRIME_THIEF, 0x0004CE13, {}, {})
	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	ws.set_wanted(&s, CRIME_THIEF, CRIME_TOWN, {enemy = true})
	testing.expect(t, !ws.hostile(&s, &db, CRIME_GUARD, CRIME_THIEF), "a prisoner is left be")
	ws.serve_time(&s, CRIME_THIEF)
	ws.tick_crime(&s, &db, 0.1)
	testing.expect_value(t, len(s.jail_orders), 1)
	testing.expect(t, s.jail_orders[0].release, "served: released")
	clear(&s.jail_orders)

	// Out of the cell is an escape: not jailed, the bounty stays, ESJA goes out.
	ws.relocate(&s, CRIME_THIEF, 0x0004CE14, {}, {})
	ws.tick_crime(&s, &db, 0.1)
	testing.expect(t, CRIME_THIEF not_in s.jailed, "escaped")
	testing.expect(t, ws.wanted(&s, CRIME_THIEF, CRIME_TOWN).enemy, "bounty stays")
	testing.expect_value(t, s.story_events[len(s.story_events) - 1].type, ws.STORY_ESCAPE_JAIL)

	ws.av_set_base(&s, CRIME_THIEF, "SneakSkillAdvance", 12)
	ws.av_set_base(&s, CRIME_THIEF, "AlchemySkillAdvance", 3)
	ws.lose_skill_progress(&s, CRIME_THIEF, 7)
	testing.expect_value(t, ws.av_base(&s, nil, CRIME_THIEF, "SneakSkillAdvance"), f32(0))
	testing.expect_value(t, ws.av_base(&s, nil, CRIME_THIEF, "AlchemySkillAdvance"), f32(0))
}

// A theft marks what it took as units stolen from their owner: a move of the stolen ones takes only
// those, any other move takes clean ones first, and the owner travels with the unit, into the world
// and back. Given back to its owner, a unit is clean and a count again. Cheap items and gold take no
// mark, so they stay counts.
@(test)
test_stolen_stacks :: proc(t: ^testing.T) {
	AXE :: gamedb.Form_ID(0x000E0001)
	THIEF, CHEST :: gamedb.Form_ID(0x000E0002), gamedb.Form_ID(0x000E0003)
	CHEST_OWNER, OWNER_REF :: gamedb.Form_ID(0x000E0004), gamedb.Form_ID(0x000E0005)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	db.ref_by_id[OWNER_REF] = {form_id = OWNER_REF, base = CHEST_OWNER}
	CUP :: gamedb.Form_ID(0x000E0006)
	db.base_value = make(map[gamedb.Form_ID]i32, context.temp_allocator)
	db.base_value[AXE], db.base_value[CUP], db.base_value[0xF] = 20, 3, 1
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	c := script.Call{ws = &s, db = &db}

	ws.inv_add(&s, THIEF, AXE, 3)
	ws.inv_add(&s, CHEST, AXE, 1)
	script.move_items(&c, {base = AXE, from = CHEST, to = THIEF, count = 1, robbed = CHEST_OWNER})
	stacks := ws.inv_stacks(&s, &db, THIEF)
	testing.expect_value(t, len(stacks), 2)
	testing.expect_value(t, stacks[0], ws.Item_Stack{AXE, false, 3})
	testing.expect_value(t, stacks[1], ws.Item_Stack{AXE, true, 1})
	testing.expect_value(t, len(ws.held_units(&s, THIEF, AXE)), 1) // the clean ones are a count

	script.move_items(&c, {base = AXE, from = THIEF, to = CHEST, count = 2}) // clean ones go first
	testing.expect_value(t, ws.stolen_count(&s, &db, THIEF, AXE), 1)
	script.move_items(&c, {base = AXE, from = THIEF, to = CHEST, count = 1, stolen = true})
	testing.expect_value(t, ws.stolen_count(&s, &db, THIEF, AXE), 0)
	testing.expect_value(t, ws.inv_count(&s, &db, THIEF, AXE), 1)
	testing.expect_value(t, ws.stolen_count(&s, &db, CHEST, AXE), 1)
	script.move_items(&c, {base = AXE, from = THIEF, count = 5, stolen = true}) // nothing stolen left to take
	testing.expect_value(t, ws.inv_count(&s, &db, THIEF, AXE), 1)

	// Dropped, a stolen axe keeps its ID and is still its owner's; given back to its owner, it is clean.
	axe := ws.held_units(&s, CHEST, AXE)[0]
	script.move_items(&c, {base = AXE, from = CHEST, to = THIEF, count = 1, stolen = true})
	testing.expect_value(t, script.drop_object(&c, THIEF, AXE, 0, 1, true), axe)
	testing.expect_value(t, ws.robbed(&s, &db, THIEF, axe), CHEST_OWNER)
	script.take(&c, axe, AXE, THIEF)
	testing.expect_value(t, ws.held_units(&s, THIEF, AXE)[0], axe)
	script.move_items(&c, {base = AXE, from = THIEF, to = OWNER_REF, count = 1, stolen = true})
	testing.expect_value(t, ws.stolen_count(&s, &db, OWNER_REF, AXE), 0)
	testing.expect_value(t, ws.inv_count(&s, &db, OWNER_REF, AXE), 1)
	testing.expect(t, axe not_in s.units, "back with its owner, it is a count again")

	// Identical stolen units show as one row; gold is never marked.
	ws.inv_add(&s, CHEST, AXE, 2)
	script.move_items(&c, {base = AXE, from = CHEST, to = THIEF, count = 2, robbed = CHEST_OWNER})
	testing.expect_value(t, ws.inv_stacks(&s, &db, THIEF)[1], ws.Item_Stack{AXE, true, 2})
	ws.inv_add(&s, CHEST, 0xF, 500)
	script.move_items(&c, {base = 0xF, from = CHEST, to = THIEF, count = 500, robbed = CHEST_OWNER})
	testing.expect_value(t, ws.stolen_count(&s, &db, THIEF, 0xF), 0)
	testing.expect_value(t, len(ws.held_units(&s, THIEF, 0xF)), 0)

	// A unit worth 5 or less stays clean however many are taken; a mod can make one take marks.
	ws.inv_add(&s, CHEST, CUP, 21)
	script.move_items(&c, {base = CUP, from = CHEST, to = THIEF, count = 20, robbed = CHEST_OWNER})
	testing.expect_value(t, ws.stolen_count(&s, &db, THIEF, CUP), 0)
	ws.set_stolen_mark(&s, CUP, true)
	script.move_items(&c, {base = CUP, from = CHEST, to = THIEF, count = 1, robbed = CHEST_OWNER})
	testing.expect_value(t, ws.stolen_count(&s, &db, THIEF, CUP), 1)
}

// An owned interior that is not public is off limits while its owner has a load door locked. A
// witness warns the trespasser iGuardWarnings (2) times, fAITrespassWarningTimer (5 s) apart, then
// reports the trespass.
@(test)
test_trespass :: proc(t: ^testing.T) {
	HOUSE, DOOR, DOOR_BASE, OWNER_BASE :: gamedb.Form_ID(0x000F0001), gamedb.Form_ID(0x000F0002), gamedb.Form_ID(0x000F0003), gamedb.Form_ID(0x000F0004)
	db: gamedb.DB
	defer {delete(db.cells);delete(db.doors);delete(db.owners);delete(db.factions);for _, r in db.cell_refs {delete(r)};delete(db.cell_refs)}
	db.cells[HOUSE] = {form_id = HOUSE, interior = true}
	db.doors[DOOR_BASE] = true
	db.cell_refs[HOUSE] = make([dynamic]gamedb.Ref)
	append(&db.cell_refs[HOUSE], gamedb.Ref{form_id = DOOR, base = DOOR_BASE, cell_form_id = HOUSE, teleport = {door = 0x000F0009}})
	db.owners[HOUSE] = OWNER_BASE
	db.factions[CRIME_TOWN] = {flags = esm.FACT_TRACK_CRIME, has_crime = true, crime = {trespass = 5}}
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	ws.relocate(&s, CRIME_THIEF, HOUSE, {}, {})
	testing.expect(t, !ws.is_trespassing(&s, &db, CRIME_THIEF), "the door is open")
	ws.set_locked(&s, DOOR, HOUSE, true)
	testing.expect(t, ws.is_trespassing(&s, &db, CRIME_THIEF), "locked in an owned house")

	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	ws.set_awareness(&s, CRIME_GUARD, CRIME_THIEF, {level = 1, detected = true})
	for level in 0 ..= 2 {
		ws.tick_crime(&s, &db, 5)
		testing.expect_value(t, ws.trespass_warning(&s, CRIME_GUARD, CRIME_THIEF), i32(level))
	}
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_GUARD, CRIME_THIEF), ws.Bounty{})
	ws.tick_crime(&s, &db, 5)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_GUARD, CRIME_THIEF), ws.Bounty{nonviolent = 5})

	db.cells[HOUSE] = {form_id = HOUSE, interior = true, public = true}
	testing.expect(t, !ws.is_trespassing(&s, &db, CRIME_THIEF), "a public place")
	ws.tick_crime(&s, &db, 1)
	ws.tick_crime(&s, &db, 1) // a warning nobody ran for a whole tick is over
	testing.expect_value(t, len(s.trespass_warnings), 0)
}

// Crimes against a member of a "do not report crimes against members" faction go unreported; a
// victim remembers who wronged it until the bounty is paid; two actors share a crime faction when
// theirs match or one's crime group lists the other's.
@(test)
test_crime_victims_and_groups :: proc(t: ^testing.T) {
	QUIET, GROUP, OTHER_TOWN :: gamedb.Form_ID(0x000FC001), gamedb.Form_ID(0x000FC002), gamedb.Form_ID(0x000FC003)
	db: gamedb.DB
	defer {delete(db.factions)}
	db.factions[CRIME_TOWN] = {flags = esm.FACT_TRACK_CRIME, has_crime = true, crime = {assault = 40}, crime_group = GROUP}
	db.factions[QUIET] = {flags = esm.FACT_DO_NOT_REPORT_CRIMES}
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	ws.set_crime_faction(&s, CRIME_GUARD, CRIME_TOWN)
	ws.set_crime_faction(&s, CRIME_CITIZEN, CRIME_TOWN)
	ws.set_awareness(&s, CRIME_GUARD, CRIME_THIEF, {level = 1, detected = true})

	testing.expect_value(t, ws.report_crime(&s, &db, CRIME_THIEF, CRIME_CITIZEN, .Assault, 0), ws.Crime_Status.Reported)
	testing.expect(t, s.crime_victims[{CRIME_CITIZEN, CRIME_THIEF}], "the victim remembers")
	s.ai.fighting[CRIME_CITIZEN] = CRIME_THIEF
	s.ai.fighting[0x000A0199] = CRIME_THIEF // a bandit, no part of it
	ws.pay_bounty(&s, &db, CRIME_THIEF, CRIME_TOWN)
	testing.expect(t, !s.crime_victims[{CRIME_CITIZEN, CRIME_THIEF}], "paid off")
	testing.expect_value(t, len(s.ai.combat_asks), 1)
	testing.expect_value(t, s.ai.combat_asks[0], ws.Combat_Ask{CRIME_CITIZEN, 0}) // the victim stops fighting

	quiet := ws.Form_ID(0x000A0105)
	ws.faction_set_rank(&s, quiet, QUIET, 0)
	testing.expect_value(t, ws.report_crime(&s, &db, CRIME_THIEF, quiet, .Assault, 0), ws.Crime_Status.Unreported)
	testing.expect_value(t, ws.bounty(&s, &db, CRIME_GUARD, CRIME_THIEF), ws.Bounty{})

	testing.expect(t, ws.shared_crime_faction(&s, &db, CRIME_GUARD, CRIME_CITIZEN), "one crime faction")
	far := ws.Form_ID(0x000A0106)
	ws.set_crime_faction(&s, far, OTHER_TOWN)
	testing.expect(t, !ws.shared_crime_faction(&s, &db, CRIME_GUARD, far), "not in the group")
	ws.add_to_list(&s, GROUP, OTHER_TOWN)
	testing.expect(t, ws.shared_crime_faction(&s, &db, CRIME_GUARD, far), "a script added it to the group")

	testing.expect_value(t, ws.arrest_state(&s, CRIME_THIEF), i32(0))
	ws.set_arresting(&s, CRIME_GUARD, CRIME_THIEF)
	testing.expect_value(t, ws.arrest_state(&s, CRIME_THIEF), i32(1))
}
