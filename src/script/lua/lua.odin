package script_lua

// Lua 5.4 front-end for the VM-agnostic script registry. registry.odin calls this
// "one more front-end": a lua_State plus the single `native_call` C bridge that
// marshals Lua values into script.call() and the result back. Gameplay scripts
// (the Papyrus replacement) and — later — IN-WORLD UI behavior handlers (HUD,
// inventory, dialogue: UI that reads/mutates world state) share this one VM; every
// engine call funnels through the same dispatch chokepoint.
//
// The PRE-WORLD UI — the main menu, mod manager, and load screen — is deliberately
// NOT on this VM (see src/ui/runtime.odin): it runs before any gamedb/worldstate
// exists, so it has nothing to dispatch into the registry. It uses its own isolated
// VM with a small `engine.*` host table instead. The split is along the world-context
// boundary, not UI-vs-gameplay; the `ui` substrate + table→node loader are VM-agnostic
// and reused by both.
//
// Cross-platform by construction: nothing here is OS-specific. It links our own
// static Lua build (vendor/lua, built by build/build-lua.sh from pinned source, patched
// there) through a copy of Odin's lua.odin binding.

import "base:runtime"
import "core:c"
import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."

// HOLE(script, blocker): no scheduler — nothing ticks a script, so a delayed or resumed body has no home. docs/script-rewrite.md notes both rewrite routes need this same piece.
// VM binds a Lua state to the registry and an engine call-context (self/ws/db).
VM :: struct {
	L:            ^lua.State,
	reg:          ^script.Registry,
	ctx:          script.Call, // self/ws/db template; reg is filled by script.call()
	host_context: runtime.Context, // captured per run so the "c"-callconv bridge can log/alloc
	none_warned:  map[string]bool, // per-method log-once guard for None absorption (decision #2)
	scripts:      map[string][dynamic]Script_Layer, // lowercase script name -> its files (loader.odin)
}

// UPVAL_VM is lua_upvalueindex(1) — the closure upvalue holding the ^VM. The
// binding doesn't expose the macro, so derive it from REGISTRYINDEX ourselves.
@(private)
UPVAL_VM :: lua.REGISTRYINDEX - 1

// upvalueindex is lua_upvalueindex(i): the pseudo-index of the i-th closure upvalue.
// The binding omits the macro (it's `LUA_REGISTRYINDEX - i`), so provide it here.
@(private)
upvalueindex :: #force_inline proc "contextless" (i: c.int) -> c.int {
	return lua.REGISTRYINDEX - i
}

// PRELUDE installs class proxies so modder Lua reads `Class.Fn(args)` rather than
// the raw native_call primitive. Object `self` comes from the VM ctx for now;
// per-ref form objects (ref:Method()) are a later step.
@(private)
PRELUDE :: `
local function make_class(name)
  return setmetatable({}, { __index = function(_, fn)
    return function(...) return native_call(name, fn, ...) end
  end })
end
for _, n in ipairs({"Debug","Game","Utility","ObjectReference","Actor","Form"}) do
  _G[n] = make_class(n)
end
`

// init creates the VM, opens the standard libs, installs the native_call bridge,
// and runs the prelude. Returns false (and logs) on failure.
init :: proc(vm: ^VM, reg: ^script.Registry, ctx: script.Call) -> bool {
	vm.L = lua.L_newstate()
	if vm.L == nil {
		log.error("lua: L_newstate failed (out of memory)")
		return false
	}
	lua.L_openlibs(vm.L)
	vm.reg = reg
	vm.ctx = ctx
	vm.none_warned = make(map[string]bool)

	// native_call(class, fn, ...) -> ret  — the one dispatch bridge. ^VM rides as
	// upvalue 1 so the C closure can reach the registry + call context.
	lua.pushlightuserdata(vm.L, rawptr(vm))
	lua.pushcclosure(vm.L, dispatch, 1)
	lua.setglobal(vm.L, "native_call")

	// Ref + None userdata metatables and the `ref()`/`None` globals — push_value
	// marshals a Form_ID into a ref, so the metatables must exist before any call.
	setup_ref_system(vm)
	if !setup_rt(vm) {
		return false
	}

	return do_string(vm, PRELUDE)
}

destroy :: proc(vm: ^VM) {
	delete(vm.none_warned)
	free_script_index(vm)
	if vm.L != nil {
		lua.close(vm.L)
		vm.L = nil
	}
}

// do_string runs a chunk of Lua, discarding any results. Returns false (and logs
// the Lua error message) on a load or runtime error.
do_string :: proc(vm: ^VM, code: string) -> bool {
	vm.host_context = context
	cs := strings.clone_to_cstring(code, context.temp_allocator)
	if lua.L_dostring(vm.L, cs) != 0 {
		log.errorf("lua: %s", to_string(vm.L, -1))
		lua.settop(vm.L, -2) // pop the error message
		return false
	}
	return true
}

// eval_int runs a chunk expected to `return` one integer (test/util helper:
// validates the result-marshalling direction). ok=false on error or no result.
eval_int :: proc(vm: ^VM, code: string) -> (result: i64, ok: bool) {
	vm.host_context = context
	cs := strings.clone_to_cstring(code, context.temp_allocator)
	if lua.L_dostring(vm.L, cs) != 0 {
		log.errorf("lua: %s", to_string(vm.L, -1))
		lua.settop(vm.L, -2)
		return 0, false
	}
	if lua.gettop(vm.L) == 0 {
		return 0, false
	}
	result = i64(lua.tointeger(vm.L, -1))
	lua.settop(vm.L, -2) // pop the result
	return result, true
}

// eval_form runs a chunk expected to `return` a ref and yields its Form_ID (the
// marshalling direction for decision #1: a native's Form_ID result surfaces as a ref
// userdata, not an integer). ok=false on error, no result, or a non-ref result.
eval_form :: proc(vm: ^VM, code: string) -> (form: script.Form_ID, ok: bool) {
	vm.host_context = context
	cs := strings.clone_to_cstring(code, context.temp_allocator)
	if lua.L_dostring(vm.L, cs) != 0 {
		log.errorf("lua: %s", to_string(vm.L, -1))
		lua.settop(vm.L, -2)
		return 0, false
	}
	if lua.gettop(vm.L) == 0 {
		return 0, false
	}
	form, ok = ref_form(vm.L, -1)
	lua.settop(vm.L, -2) // pop the result
	return
}

// dispatch is the C closure behind `native_call(class, fn, ...)`. Upvalue 1 = ^VM.
@(private)
dispatch :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context

	n := lua.gettop(L)
	if n < 2 {
		lua.L_error(L, "native_call(class, fn, ...) needs class and fn")
		return 0
	}
	class := to_string(L, 1)
	fn := to_string(L, 2)

	args := make([dynamic]script.Value, 0, int(n) - 2, context.temp_allocator)
	for i in 3 ..= int(n) {
		append(&args, to_value(L, c.int(i)))
	}

	cc := vm.ctx // copy the call template; script.call fills cc.reg
	ret := script.call(vm.reg, class, fn, &cc, args[:])
	push_value(L, ret)
	return 1
}

// ── marshalling ──────────────────────────────────────────────────────────────

@(private)
to_value :: proc(L: ^lua.State, idx: c.int) -> script.Value {
	#partial switch lua.type(L, idx) {
	case .BOOLEAN:
		return bool(lua.toboolean(L, idx))
	case .NUMBER:
		if lua.isinteger(L, idx) {
			return i32(lua.tointeger(L, idx))
		}
		return f32(lua.tonumber(L, idx))
	case .STRING:
		return to_string(L, idx)
	case .USERDATA:
		// A ref userdata carries a Form_ID; None (and any other userdata) → Papyrus None.
		if form, ok := ref_form(L, idx); ok {
			return form
		}
	}
	return nil // NIL / None / unsupported → Papyrus None
}

@(private)
push_value :: proc(L: ^lua.State, v: script.Value) {
	switch x in v {
	case i32:
		lua.pushinteger(L, lua.Integer(x))
	case f32:
		lua.pushnumber(L, lua.Number(x))
	case bool:
		lua.pushboolean(L, b32(x))
	case string:
		lua.pushstring(L, strings.clone_to_cstring(x, context.temp_allocator))
	case script.Form_ID:
		push_ref(L, x) // Form_ID → ref userdata (plain ints rejected, decision #1)
	case:
		push_none(L) // nil Value → the None sentinel (decision #2), not Lua nil
	}
}

// to_string clones a Lua string off the stack into `alloc` (temp by default).
// Identifiers and trace strings carry no embedded NULs; a binary-safe (length-
// based) copy is a later refinement if a native ever needs one.
@(private)
to_string :: proc(L: ^lua.State, idx: c.int, alloc := context.temp_allocator) -> string {
	s := lua.tolstring(L, idx, nil)
	if s == nil {
		return ""
	}
	return strings.clone(string(s), alloc)
}
