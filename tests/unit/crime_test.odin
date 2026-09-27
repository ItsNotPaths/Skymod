package unit_tests

import "core:os"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
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
	ws.pay_bounty(&s, CRIME_THIEF, CRIME_TOWN)
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
