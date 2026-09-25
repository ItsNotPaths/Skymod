package unit_tests

// Lua front-end round-trip (Phase 4). Proves the VM wires to the VM-agnostic
// registry end-to-end: a Lua chunk -> native_call bridge -> script.call() ->
// worldstate overlay (args-in), and a returned Form_ID back into Lua (result-out).
// Hermetic + synthetic: empty baseline DB, no game files.

import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"
import "../../src/formid"

@(test)
test_lua_args_in_to_overlay :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	form := script.Form_ID(0x0003_3333)
	vm: slua.VM
	ok := slua.init(&vm, &reg, script.Call{self = form, ws = &ws, db = &db})
	defer slua.destroy(&vm)
	testing.expect(t, ok, "VM init + prelude ran")

	// Lua -> native_call -> registry -> worldstate overlay (float arg marshalled in).
	ran := slua.do_string(&vm, "ObjectReference.SetScale(2.5)")
	testing.expect(t, ran, "lua chunk ran")

	d, found := worldstate.get(&ws, form)
	testing.expect(t, found, "scale delta written from lua")
	testing.expect(t, .Scaled in d.live, "Scaled field live")
	testing.expect_value(t, d.scale, f32(2.5))
}

@(test)
test_lua_result_out :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	vm: slua.VM
	ok := slua.init(&vm, &reg, script.Call{self = 0, ws = &ws, db = &db})
	defer slua.destroy(&vm)
	testing.expect(t, ok, "VM init")

	// Game.GetPlayer() returns the player form; per decision #1 it surfaces as a REF
	// userdata (not a bare integer), whose Form_ID round-trips back equal to PLAYER.
	p, got := slua.eval_form(&vm, "return Game.GetPlayer()")
	testing.expect(t, got, "got a ref result")
	testing.expect_value(t, p, formid.PLAYER)

	// A bare integer result is NOT a ref (guards the contract: ints are rejected).
	_, isref := slua.eval_form(&vm, "return 0x14")
	testing.expect(t, !isref, "a plain integer is not a ref")
}
