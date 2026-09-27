package unit_tests

import "core:os"
import "core:testing"
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
