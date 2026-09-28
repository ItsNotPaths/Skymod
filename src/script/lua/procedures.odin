package script_lua

import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../ai"
import "../../worldstate"

// run_procedure is ai.Lua_Hook's run: one tick of a package procedure a mod wrote in Lua (rt.procedure).
run_procedure :: proc(user: rawptr, name: string, actor: script.Form_ID, dt: f32, inputs: []ai.Lua_Input, goal: ^ai.Goal) -> ai.Status {
	vm := cast(^VM)user
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "procedure") {return .Failed}
	rt := top + 1 // push_rt_fn leaves the rt table under the function
	lua.pushstring(L, strings.clone_to_cstring(name, context.temp_allocator))
	push_ref(L, actor)
	lua.pushnumber(L, lua.Number(dt))
	for in_ in inputs {
		switch x in in_ {
		case bool:           lua.pushboolean(L, b32(x))
		case i32:            lua.pushinteger(L, lua.Integer(x))
		case f32:            lua.pushnumber(L, lua.Number(x))
		case script.Form_ID: push_ref(L, x)
		case [3]f32:
			lua.getfield(L, rt, "vec3")
			for v in x {lua.pushnumber(L, lua.Number(v))}
			lua.call(L, 3, 1)
		case:                push_none(L)
		}
	}
	if lua.pcall(L, i32(3 + len(inputs)), 3, 0) != 0 {
		log.errorf("lua: rt.procedure: %s", to_string(L, -1))
		return .Failed
	}

	status, gait := to_string(L, -3), strings.to_lower(to_string(L, -1), context.temp_allocator)
	at := lua.gettop(L) - 1
	goal^ = {}
	ws, db := vm.ctx.ws, vm.ctx.db
	if ref, ok := ref_form(L, at); ok && ref != 0 {
		goal^ = {active = true, point = worldstate.ref_pos(ws, db, ref), radius = ai.ARRIVED, cell = worldstate.ref_grid_cell(ws, db, ref)}
	} else if lua.istable(L, at) {
		goal.active, goal.radius = true, ai.ARRIVED
		for k, i in ([3]cstring{"x", "y", "z"}) {
			lua.getfield(L, at, k)
			goal.point[i] = f32(lua.tonumber(L, -1))
			lua.pop(L, 1)
		}
	}
	switch gait {
	case "jog":      goal.gait = .Jog
	case "run":      goal.gait = .Run
	case "fastwalk": goal.gait = .FastWalk
	}
	switch status {
	case "running": return .Running
	case "done":    return .Done
	}
	return .Failed
}
