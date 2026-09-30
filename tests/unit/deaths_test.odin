package unit_tests

import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

// A deferred kill holds death at 0 Health until it ends; a trap's hits count as its cause's; at
// DisintegrateEnd the body goes and its ash pile is left.
@(test)
test_death_reads :: proc(t: ^testing.T) {
	VICTIM, TRAP, SETTER, ASH :: gamedb.Form_ID(0xA1), gamedb.Form_ID(0xB1), gamedb.Form_ID(0xC1), gamedb.Form_ID(0xD1)
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	worldstate.av_set_base(&ws, VICTIM, "Health", 10)
	c := script.Call{self = VICTIM, ws = &ws, db = &db}

	script.call(&reg, "Actor", "StartDeferredKill", &c, {})
	script.damage_health(&c, VICTIM, 20, TRAP)
	testing.expect(t, !worldstate.is_dead(&ws, &db, VICTIM), "deferred")
	trap := script.Call{self = TRAP, ws = &ws, db = &db}
	script.call(&reg, "ObjectReference", "SetActorCause", &trap, {SETTER})
	script.call(&reg, "Actor", "EndDeferredKill", &c, {})
	testing.expect(t, worldstate.is_dead(&ws, &db, VICTIM), "dies once the deferral ends")

	worldstate.av_set_base(&ws, 0xA2, "Health", 10)
	other := script.Call{self = 0xA2, ws = &ws, db = &db}
	script.damage_health(&other, 0xA2, 20, TRAP)
	testing.expect_value(t, ws.killers[0xA2], SETTER) // the trap's kill is its setter's

	script.call(&reg, "Actor", "AttachAshPile", &c, {ASH})
	script.call(&reg, "Actor", "SetCriticalStage", &c, {i32(4)})
	testing.expect(t, !worldstate.ref_enabled(&ws, &db, VICTIM), "the body goes")
	found := false
	for _, cr in ws.created {found ||= cr.base == ASH}
	testing.expect(t, found, "its ash pile stays")
}
