package script_lua

// Engine events into scripts. The engine sends an edge when it happens; the scripts run it when
// game_tick drains the queue. Timers are the third kind: tick_updates counts OnUpdate registrations
// down and sends the ones that come due (docs/script-rewrite.md "Events: edges, transitions, timers").

import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../worldstate"

// HOLE(script, gap): only OnActivate has a sender; OnHit, OnDeath, OnContainerChanged, OnItemAdded and OnTriggerEnter are never sent.

// send queues `event` for every script on `form`, and reports whether `form` has any. Args are refs
// (Form_ID), i32, f32, bool or string.
send :: proc(vm: ^VM, form: script.Form_ID, event: string, args: ..any) -> bool {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "send") {return false}
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
			return false
		}
	}
	if lua.pcall(L, i32(2 + len(args)), 1, 0) != 0 {
		log.errorf("lua: rt.send: %s", to_string(L, -1))
		return false
	}
	return bool(lua.toboolean(L, -1))
}

// tick_updates is the scheduler: every OnUpdate registration counts down by `dt`, and a due one
// queues OnUpdate on its form. A due form with no script instances yet (after a Continue, a ref
// whose cell has not loaded) stays due until one exists.
tick_updates :: proc(vm: ^VM, ws: ^worldstate.World_State, dt: f32) {
	stopped := make([dynamic]script.Form_ID, context.temp_allocator)
	for form, &u in ws.updates {
		if u.single_on {
			u.single -= dt
			if u.single <= 0 && send(vm, form, "OnUpdate") {u.single_on = false}
		}
		if u.repeat_on {
			u.repeat -= dt
			if u.repeat <= 0 && send(vm, form, "OnUpdate") {u.repeat = max(u.repeat + u.interval, 0)}
		}
		if !u.single_on && !u.repeat_on {append(&stopped, form)}
	}
	for form in stopped {delete_key(&ws.updates, form)}
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
