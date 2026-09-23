package script_lua

// Engine events into scripts. The engine sends an edge when it happens; the scripts run it when
// game_tick drains the queue. Timers are the third kind: tick_updates counts OnUpdate registrations
// down and sends the ones that come due (docs/script-rewrite.md "Events: edges, transitions, timers").

import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../gamedb"
import "../../worldstate"

// HOLE(combat, gap): nothing sends OnHit or OnDeath; there is no damage and no death path to send them from.
// HOLE(physics, gap): nothing sends OnTriggerEnter/OnTriggerLeave (442 scripts define one); there are no trigger volumes.

// send queues a ref's `event` for the scripts on it and on each alias it fills.
send :: proc(vm: ^VM, form: script.Form_ID, event: string, args: ..any) {
	for r in recipients(vm.ctx.ws, form) {send_own(vm, r, event, ..args)}
}

// recipients is who hears a ref's events: the ref, then each alias it fills ("ReferenceAliases
// receive events from the ObjectReference they are pointing at").
@(private = "file")
recipients :: proc(ws: ^worldstate.World_State, form: script.Form_ID) -> []script.Form_ID {
	holders, _ := ws.alias_holders[form]
	out := make([]script.Form_ID, 1 + len(holders), context.temp_allocator)
	out[0] = form
	copy(out[1:], holders[:])
	return out
}

// send_own queues `event` for every script on `form` alone, and reports whether `form` has any.
// Args are refs (Form_ID), i32, f32, bool or string.
send_own :: proc(vm: ^VM, form: script.Form_ID, event: string, args: ..any) -> bool {
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
			if u.single <= 0 && send_own(vm, form, "OnUpdate") {u.single_on = false}
		}
		if u.repeat_on {
			u.repeat -= dt
			if u.repeat <= 0 && send_own(vm, form, "OnUpdate") {u.repeat = max(u.repeat + u.interval, 0)}
		}
		if !u.single_on && !u.repeat_on {append(&stopped, form)}
	}
	for form in stopped {delete_key(&ws.updates, form)}
}

// tick_items sends the inventory events of the items scripts moved since the last tick: OnItemRemoved
// to the old container, OnItemAdded to the new one, then OnContainerChanged to a moved ref (not to a
// destroyed one). The CK does not give this order.
tick_items :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State) {
	for m in ws.item_moves {
		if m.from != 0 {send_item(vm, db, ws, m.from, "OnItemRemoved", m, m.to)}
		if m.to != 0 {send_item(vm, db, ws, m.to, "OnItemAdded", m, m.from)}
		if m.ref != 0 && m.to != 0 {send(vm, m.ref, "OnContainerChanged", m.to, m.from)}
	}
	clear(&ws.item_moves)
}

// send_item sends an inventory event to a container's recipients, each through its own filters.
@(private = "file")
send_item :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, container: script.Form_ID, event: string, m: worldstate.Item_Move, other: script.Form_ID) {
	for r in recipients(ws, container) {
		if item_passes(db, ws, r, m) {send_own(vm, r, event, m.base, m.count, m.ref, other)}
	}
}

// item_passes reports whether `recipient`'s inventory event filters let the move through. A filter
// matches the base or the ref itself, or a FormList holding either (not nested lists).
@(private = "file")
item_passes :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, recipient: script.Form_ID, m: worldstate.Item_Move) -> bool {
	filters, ok := ws.item_filters[recipient]
	if !ok {return true}
	for f in filters {
		if f == m.base || (m.ref != 0 && f == m.ref) {return true}
		members, _ := gamedb.form_list_of(db, f)
		for x in members {
			if x == m.base || (m.ref != 0 && x == m.ref) {return true}
		}
	}
	return false
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
