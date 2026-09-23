package unit_tests

// skymod.rt (src/script/lua/rt.lua) on a real VM: registry + worldstate behind it, no game files.

import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

RT_TEST_SRC :: #load("rt_test.lua", string)

@(test)
test_rt :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB

	vm: slua.VM
	testing.expect(t, slua.init(&vm, &reg, script.Call{ws = &ws, db = &db}), "VM init")
	defer slua.destroy(&vm)
	testing.expect(t, slua.do_string(&vm, RT_TEST_SRC), "rt_test.lua passes")
}
