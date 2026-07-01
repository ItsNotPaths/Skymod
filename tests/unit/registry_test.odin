package unit_tests

// Script-registry tests (Phase 4). Hermetic + SYNTHETIC: drive native calls
// directly through the VM-agnostic dispatch and assert they land in the worldstate
// overlay — no Lua VM, no game files. The 674-native manifest is the committed
// generated artifact; we assert auto-stub coverage + that the hot set mutates +
// reads through baseline⊕overlay + case-insensitive dispatch.

import "core:log"
import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

@(test)
test_registry_manifest_and_stubs :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)

	// The whole declared surface is auto-stubbed (674 from the corpus).
	testing.expect(t, len(reg.declared) >= 600, "manifest auto-stubbed")
	testing.expect(t, script.is_declared(&reg, "ObjectReference", "Disable"), "Disable declared")
	testing.expect(t, script.is_implemented(&reg, "ObjectReference", "Disable"), "Disable implemented")
	// Declared but no body yet -> known, not implemented.
	testing.expect(t, script.is_declared(&reg, "Actor", "GetActorValue"), "GetActorValue declared")
	testing.expect(t, !script.is_implemented(&reg, "Actor", "GetActorValue"), "GetActorValue not impl")
}

@(test)
test_registry_disable_enable :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB // empty baseline; read-through falls back to defaults

	form := script.Form_ID(0x0001_2345)
	c := script.Call{self = form, ws = &ws, db = &db}

	script.call(&reg, "ObjectReference", "Disable", &c, nil)
	d, ok := worldstate.get(&ws, form)
	testing.expect(t, ok, "delta exists after Disable")
	testing.expect(t, .Disabled in d.live, "Disabled field live")
	testing.expect(t, d.disabled, "disabled = true")

	// case-insensitive dispatch (Papyrus is case-insensitive).
	script.call(&reg, "objectreference", "enable", &c, nil)
	d2, _ := worldstate.get(&ws, form)
	testing.expect(t, !d2.disabled, "Enable cleared disabled")

	// read-through getter reflects the overlay.
	res := script.call(&reg, "ObjectReference", "IsDisabled", &c, nil)
	b, isb := res.(bool)
	testing.expect(t, isb && !b, "IsDisabled reads overlay = false")
}

@(test)
test_registry_scale_and_player :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	form := script.Form_ID(0x0002_2222)
	c := script.Call{self = form, ws = &ws, db = &db}

	script.call(&reg, "ObjectReference", "SetScale", &c, []script.Value{f32(2.5)})
	gs := script.call(&reg, "ObjectReference", "GetScale", &c, nil)
	sv, oks := gs.(f32)
	testing.expect(t, oks, "GetScale returns a float")
	testing.expect_value(t, sv, f32(2.5))

	// Game.GetPlayer is a global (self unused) returning the player form 0x14.
	gp := script.call(&reg, "Game", "GetPlayer", &c, nil)
	pf, okf := gp.(script.Form_ID)
	testing.expect(t, okf, "GetPlayer returns a form")
	testing.expect_value(t, pf, script.PLAYER)
}

@(test)
test_registry_unimplemented_and_unknown :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	c := script.Call{self = script.Form_ID(1), ws = &ws, db = &db}

	// These paths log at WARN/ERROR by design (an unknown native is a real bug);
	// silence the logger so the test runner doesn't count them as failures.
	old := context.logger
	context.logger = log.nil_logger()

	// Declared-but-unimplemented returns None (nil) and does not crash.
	r1 := script.call(&reg, "Actor", "GetActorValue", &c, []script.Value{"Health"})
	testing.expect(t, r1 == nil, "unimplemented -> None")

	// Unknown native (not in the manifest) also returns None (logs an error).
	r2 := script.call(&reg, "TotallyNotAClass", "Nope", &c, nil)
	testing.expect(t, r2 == nil, "unknown -> None")
	testing.expect(t, !script.is_declared(&reg, "TotallyNotAClass", "Nope"), "unknown not declared")

	context.logger = old
}
