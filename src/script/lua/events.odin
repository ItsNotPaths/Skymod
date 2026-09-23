package script_lua

// Engine events into scripts. The engine sends an edge when it happens; the scripts run it when
// game_tick drains the queue (docs/script-rewrite.md "Events: edges, transitions, timers").

import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."

// HOLE(script, gap): only OnActivate has a sender; OnHit, OnDeath, OnContainerChanged, OnItemAdded and OnTriggerEnter are never sent.
// HOLE(script, gap): no transitions — OnLoad, OnUnload, OnCellAttach and OnCellDetach never fire.

// send queues `event` for every script on `form`. Args are refs (Form_ID), i32, f32, bool or string.
send :: proc(vm: ^VM, form: script.Form_ID, event: string, args: ..any) {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "send") {return}
	push_ref(L, form)
	lua.pushstring(L, strings.clone_to_cstring(event, context.temp_allocator))
	for a in args {
		switch x in a {
		case script.Form_ID:
			push_ref(L, x)
		case i32:
			lua.pushinteger(L, lua.Integer(x))
		case f32:
			lua.pushnumber(L, lua.Number(x))
		case bool:
			lua.pushboolean(L, b32(x))
		case string:
			lua.pushstring(L, strings.clone_to_cstring(x, context.temp_allocator))
		case:
			log.errorf("lua: send %s: unsupported arg type %v", event, a.id)
			return
		}
	}
	if lua.pcall(L, i32(2 + len(args)), 0, 0) != 0 {
		log.errorf("lua: rt.send: %s", to_string(L, -1))
	}
}

// drain runs every queued event. Call once per game_tick. Returns how many events ran.
drain :: proc(vm: ^VM) -> int {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "drain") {return 0}
	if lua.pcall(L, 0, 1, 0) != 0 {
		log.errorf("lua: rt.drain: %s", to_string(L, -1))
		return 0
	}
	return int(lua.tointeger(L, -1))
}

// push_rt_fn pushes skymod.rt[name]. The caller restores the stack.
@(private)
push_rt_fn :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.getglobal(L, "require")
	lua.pushstring(L, "skymod.rt")
	if lua.pcall(L, 1, 1, 0) != 0 {
		log.errorf("lua: require skymod.rt: %s", to_string(L, -1))
		return false
	}
	lua.getfield(L, -1, name)
	return true
}
