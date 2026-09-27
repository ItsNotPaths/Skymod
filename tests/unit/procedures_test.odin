package unit_tests

// A package procedure a mod writes in Lua, run through ai.Lua_Hook.

import "core:testing"
import "../../src/ai"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

@(test)
test_lua_procedure :: proc(t: ^testing.T) {
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
	testing.expect(t, slua.do_string(&vm, `
		local rt = require("skymod.rt")
		local C = rt.class("TestPace")
		function C.Procedure(actor, dt, far, spot)
			if far > 1 then return "running", spot, "run" end
			return "done"
		end`), "define TestPace")

	goal: ai.Goal
	status := slua.run_procedure(&vm, "TestPace", 0x14, 0.1, {f32(2), [3]f32{1, 2, 3}}, &goal)
	testing.expect_value(t, status, ai.Status.Running)
	testing.expect_value(t, goal.point, [3]f32{1, 2, 3})
	testing.expect_value(t, goal.gait, ai.Gait.Run)
	testing.expect(t, goal.active)

	testing.expect_value(t, slua.run_procedure(&vm, "TestPace", 0x14, 0.1, {f32(0), nil}, &goal), ai.Status.Done)
	testing.expect(t, !goal.active, "no goal: stand")
	testing.expect_value(t, slua.run_procedure(&vm, "NoSuchProcedure", 0x14, 0.1, nil, &goal), ai.Status.Failed)
}
