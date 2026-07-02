package ui

// The UI VM runtime: a persistent Lua VM running the framework + one screen, plus the thin
// Odin↔Lua per-frame protocol that drives it. The engine stays generic — each frame it asks Lua for
// the composed tree (ui._frame → `frame`), tells Lua which action fired (`dispatch`), exposes which
// node is focused (`set_focus`, so widgets style themselves), publishes the clock/viewport, and
// reads back a result verb (`take_result`). It knows NOTHING about specific buttons, dialogs, or
// screens — those live entirely in Lua.
//
// This VM is SEPARATE from the gameplay/script_lua VM by design: the PRE-WORLD UI (main menu / load
// screen) runs before any gamedb/worldstate exists, so it has nothing to dispatch into the script
// registry. IN-WORLD UI (HUD, inventory, dialogue — UI that reads/mutates world state) will instead
// drive this same substrate from the gameplay VM, through the registry's native_call chokepoint.
// The split is along the world-context boundary, not UI-vs-gameplay (see src/script/lua/lua.odin).
//
// Engine state the UI needs is SURFACED to Lua as callable host procs (the `engine` table — the
// same "host call from Lua" pattern as the gameplay registry), not pushed in as globals. The host
// API is app-owned: `open` takes an installer callback that registers app procs via `register_host`;
// the procs recover the ^VM with `vm_from_upvalue` and their app data through `vm.user`.

import "core:c"
import "core:log"
import "base:runtime"
import "core:strings"
import lua "vendor:lua/5.4"

// UPVAL is lua_upvalueindex(1) — the closure upvalue holding the ^VM for host procs (the binding
// doesn't expose the macro, so derive it from REGISTRYINDEX, as script_lua does).
@(private = "file")
UPVAL :: lua.REGISTRYINDEX - 1

// VM is a player-UI Lua state. `user` is the app's host data (opaque here), read back by the host
// procs via vm_from_upvalue(L).user; `host_ctx` is captured on each engine→Lua entry so the
// "c"-callconv host procs can alloc/log.
VM :: struct {
	L:        ^lua.State,
	host_ctx: runtime.Context,
	user:     rawptr,
}

// open builds the VM into the caller-owned `vm` (a POINTER, so host closures can capture a STABLE
// ^VM as their upvalue — returning by value would dangle it). Opens libs, installs the app's host
// API via `install` (if any), runs the framework files (constructors + interaction API) and the
// screen (which registers its view via ui.screen). `dir` is the on-disk UI lua root
// (content/baseui/lua); missing files fall back to the embedded copies. On failure the VM is closed.
open :: proc(vm: ^VM, dir, screen_rel: string, user: rawptr = nil, install: proc(vm: ^VM) = nil) -> bool {
	vm.L = lua.L_newstate()
	if vm.L == nil {
		log.error("ui: L_newstate failed")
		return false
	}
	vm.user = user
	vm.host_ctx = context
	lua.L_openlibs(vm.L)
	if install != nil {
		install(vm)
	}

	for rel in FRAMEWORK {
		src, sok := source(dir, rel)
		if !sok {
			log.errorf("ui: missing framework file %q", rel)
			close(vm)
			return false
		}
		if !run_chunk(vm.L, src, rel) {
			close(vm)
			return false
		}
	}

	src, sok := source(dir, screen_rel)
	if !sok {
		log.errorf("ui: missing screen %q", screen_rel)
		close(vm)
		return false
	}
	if !run_chunk(vm.L, src, screen_rel) {
		close(vm)
		return false
	}
	return true
}

close :: proc(vm: ^VM) {
	if vm.L != nil {
		lua.close(vm.L)
		vm.L = nil
	}
}

// vm_from_upvalue recovers the ^VM a host closure captured (upvalue 1). Host procs start with:
//   vm := ui.vm_from_upvalue(L); context = vm.host_ctx
vm_from_upvalue :: proc "contextless" (L: ^lua.State) -> ^VM {
	return cast(^VM)lua.touserdata(L, UPVAL)
}

// register_host sets `fn` as field `name` of the table at the top of the stack, as a C closure
// capturing ^VM (recovered in the proc via vm_from_upvalue). The app builds its `engine` table with
// this inside the `install` callback of open.
register_host :: proc(L: ^lua.State, vm: ^VM, name: cstring, fn: lua.CFunction) {
	lua.pushlightuserdata(L, vm)
	lua.pushcclosure(L, fn, 1)
	lua.setfield(L, -2, name) // table[name] = closure
}

// frame calls ui._frame() and walks the composed tree (base screen + active transients) into a
// Node. The node is allocated in context.allocator; free it with destroy.
frame :: proc(vm: ^VM) -> (root: Node, ok: bool) {
	vm.host_ctx = context
	L := vm.L
	if !push_ui_field(L, "_frame") { // [ui, fn]
		lua.settop(L, -2) // pop ui
		log.error("ui: ui._frame missing")
		return {}, false
	}
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, -3)
		log.error("ui: ui._frame is not a function")
		return {}, false
	}
	if lua.pcall(L, 0, 1, 0) != 0 { // [ui, result] | [ui, errmsg]
		log.errorf("ui: _frame: %s", lua_str(L, -1))
		lua.settop(L, -3)
		return {}, false
	}
	if lua.type(L, -1) != .TABLE {
		log.error("ui: ui._frame must return a node table")
		lua.settop(L, -3)
		return {}, false
	}
	root = parse_node(L, lua.gettop(L))
	lua.settop(L, -3) // pop result + ui
	return root, true
}

// dispatch runs the action that the engine's input routing activated (Lua decides what it does:
// mutate state, spawn a transient, or ui.exit a result verb).
dispatch :: proc(vm: ^VM, action: string) {
	if action == "" {
		return
	}
	vm.host_ctx = context
	call_ui_method_str(vm.L, "dispatch", action)
}

// back asks the UI to go back (Backspace): the framework closes the topmost transient.
back :: proc(vm: ^VM) {
	vm.host_ctx = context
	call_ui_method0(vm.L, "back")
}

// set_time publishes the animation clock (seconds since the screen opened) as ui.time, so Lua
// screens can tween (e.g. a sidebar's slide-in) without any per-widget engine animation logic.
set_time :: proc(vm: ^VM, t: f64) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return
	}
	lua.pushnumber(L, lua.Number(t))
	lua.setfield(L, -2, "time") // pops value
	lua.settop(L, -2) // pop ui
}

// set_viewport publishes the screen size as ui.vw/ui.vh, so a screen that needs absolute pixels
// (e.g. a credits scroll starting just below the bottom edge) can read it instead of guessing.
set_viewport :: proc(vm: ^VM, w, h: f32) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return
	}
	lua.pushnumber(L, lua.Number(w));lua.setfield(L, -2, "vw")
	lua.pushnumber(L, lua.Number(h));lua.setfield(L, -2, "vh")
	lua.settop(L, -2) // pop ui
}

// set_focus tells Lua which node id is focused (widgets read ui.focus to style themselves). An
// empty id clears focus.
set_focus :: proc(vm: ^VM, id: string) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return
	}
	if id == "" {
		lua.pushnil(L)
	} else {
		lua.pushstring(L, strings.clone_to_cstring(id, context.temp_allocator))
	}
	lua.setfield(L, -2, "focus") // pops value
	lua.settop(L, -2) // pop ui
}

// take_result reads + clears ui.result (the verb the screen hands back to the app via ui.exit).
// The returned string is temp-allocated.
take_result :: proc(vm: ^VM) -> (string, bool) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return "", false
	}
	lua.getfield(L, -1, "result") // [ui, result]
	res: string
	ok: bool
	if lua.type(L, -1) == .STRING {
		res = strings.clone(string(lua.tolstring(L, -1, nil)), context.temp_allocator)
		ok = true
	}
	lua.settop(L, -2) // pop result → [ui]
	if ok {
		lua.pushnil(L)
		lua.setfield(L, -2, "result") // ui.result = nil
	}
	lua.settop(L, -2) // pop ui
	return res, ok
}

// ── ui-table access (shared by the protocol procs; also used by app sideband readers) ──────────

// push_ui_field pushes the global `ui` table then its field `name` on top (leaving [ui, field]).
// Returns false (with only [ui] on the stack) if `ui` isn't a table.
push_ui_field :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		return false
	}
	lua.getfield(L, -1, name) // [ui, field]
	return true
}

// read_num_field reads numeric field `key` of the table at the top of the stack into `dst` (left
// unchanged if the field is absent / not a number). Pops only its own temporary.
read_num_field :: proc(L: ^lua.State, key: cstring, dst: ^f32) {
	lua.getfield(L, -1, key)
	if lua.type(L, -1) == .NUMBER {
		dst^ = f32(lua.tonumber(L, -1))
	}
	lua.settop(L, -2)
}

// read_num_index reads numeric array element `i` of the table at the top of the stack into `dst`.
read_num_index :: proc(L: ^lua.State, i: lua.Integer, dst: ^f32) {
	lua.geti(L, -1, i)
	if lua.type(L, -1) == .NUMBER {
		dst^ = f32(lua.tonumber(L, -1))
	}
	lua.settop(L, -2)
}

// call_ui_method0 calls ui[name]() with no args, discarding results.
@(private = "file")
call_ui_method0 :: proc(L: ^lua.State, name: cstring) {
	if !push_ui_field(L, name) {
		lua.settop(L, -2)
		return
	}
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, -3)
		return
	}
	if lua.pcall(L, 0, 0, 0) != 0 { // [ui] | [ui, errmsg]
		log.errorf("ui: %s: %s", name, lua_str(L, -1))
		lua.settop(L, -2) // pop errmsg
	}
	lua.settop(L, -2) // pop ui
}

// call_ui_method_str calls ui[name](arg) with one string arg, discarding results.
@(private = "file")
call_ui_method_str :: proc(L: ^lua.State, name: cstring, arg: string) {
	if !push_ui_field(L, name) {
		lua.settop(L, -2)
		return
	}
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, -3)
		return
	}
	lua.pushstring(L, strings.clone_to_cstring(arg, context.temp_allocator)) // [ui, fn, arg]
	if lua.pcall(L, 1, 0, 0) != 0 { // [ui] | [ui, errmsg]
		log.errorf("ui: %s: %s", name, lua_str(L, -1))
		lua.settop(L, -2) // pop errmsg
	}
	lua.settop(L, -2) // pop ui
}
