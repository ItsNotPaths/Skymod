package unit_tests

import "core:testing"
import "../../src/gamedb"
import "../../src/worldstate"

// A tag pattern matches its own tag and those below it; kw.<editor id> is a keyword, and an actor
// has its race's keywords.
@(test)
test_tags :: proc(t: ^testing.T) {
	FX, NPC, RACE, UNDEAD :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x20), gamedb.Form_ID(0x10), gamedb.Form_ID(0x950)
	db: gamedb.DB
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[NPC] = {race = RACE}
	db.keywords = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.keywords[RACE] = {UNDEAD}
	db.keyword_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	db.keyword_by_edid["actortypeundead"] = UNDEAD
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.set_tags(&ws, FX, {"magic.fire", "status"})
	for p in ([]string{"magic", "magic.fire", "status"}) {
		testing.expectf(t, worldstate.has_tag(&ws, &db, FX, p), "%s should match", p)
	}
	for p in ([]string{"magic.frost", "magic.fire.burn", "mag", "kw.ActorTypeUndead"}) {
		testing.expectf(t, !worldstate.has_tag(&ws, &db, FX, p), "%s should not match", p)
	}
	testing.expect(t, worldstate.has_tag(&ws, &db, NPC, "kw.ActorTypeUndead"), "an actor has its race's keywords")
	worldstate.set_tags(&ws, FX, {"magic.frost"})
	testing.expect(t, !worldstate.has_tag(&ws, &db, FX, "status"), "set_tags replaces")
}
