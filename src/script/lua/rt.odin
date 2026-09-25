package script_lua

// The engine half of `skymod.rt`, the runtime every converted script requires. rt.lua is the
// language half; these are the few things it cannot do without the registry or gamedb.

// (hole utility-wait :tags script :sev gap) Utility.Wait returns at once, so a poll loop in a handler (CritterSpawn's OnLoad) spins until rt.lua's instruction budget ends it — 20-125 ms per re-attaching cell ring. The S5 rewrite turns these into guards; docs/script-rewrite.md "Perf findings".

import "core:c"
import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../gamedb"
import "../../worldstate"
import "../../formid"

@(private)
RT_SRC :: #load("rt.lua", string)
@(private)
PARAMS_SRC :: #load("params.lua", string) // generated: tools/pexdump --emit-params

// setup_rt registers the hooks rt.lua calls and makes `require('skymod.rt')` and
// `require('skymod.params')` load them.
@(private)
setup_rt :: proc(vm: ^VM) -> bool {
	L := vm.L
	hooks := [?]struct {
		name: cstring,
		fn:   lua.CFunction,
	}{
		{"__native", rt_native},
		{"__method", rt_method},
		{"__has_method", rt_has_method},
		{"__none_value", rt_none_value},
		{"__is_engine_class", rt_is_engine_class},
		{"__class_of", rt_class_of},
		{"__is_a", rt_is_a},
		{"__warn", rt_warn},
		{"__script_layers", rt_script_layers},
		{"__anim_event", rt_anim_event},
	}
	for h in hooks {
		lua.pushlightuserdata(L, vm)
		lua.pushcclosure(L, h.fn, 1)
		lua.setglobal(L, h.name)
	}

	return preload(L, "skymod.params", PARAMS_SRC) && preload(L, "skymod.rt", RT_SRC)
}

// preload compiles `src` and registers it as package.preload[name].
@(private)
preload :: proc(L: ^lua.State, name: cstring, src: string) -> bool {
	chunk := strings.clone_to_cstring(strings.concatenate({"=", string(name)}, context.temp_allocator), context.temp_allocator)
	if lua.L_loadbuffer(L, raw_data(src), len(src), chunk) != .OK {
		log.errorf("lua: %s: %s", name, to_string(L, -1))
		lua.pop(L, 1)
		return false
	}
	lua.getglobal(L, "package")
	lua.getfield(L, -1, "preload")
	lua.pushvalue(L, -3)
	lua.setfield(L, -2, name)
	lua.pop(L, 3)
	return true
}

// __native(class, fn, recv, ...) calls a registry native with `recv` (a ref, or nil/None for a
// global) as its receiver.
@(private)
rt_native :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context

	class := to_string(L, 1)
	fn := to_string(L, 2)
	form, _ := ref_form(L, 3)
	n := int(lua.gettop(L))
	args := make([dynamic]script.Value, 0, max(n - 3, 0), context.temp_allocator)
	for i in 4 ..= n {
		append(&args, to_value(L, c.int(i)))
	}
	cc := vm.ctx
	cc.self = form
	v := script.call(vm.reg, class, fn, &cc, args[:])
	sync_refs(vm)
	push_value(L, v)
	return 1
}

// __method(ref, fn, ...) calls native `fn` on a form, resolved up its engine class chain.
@(private)
rt_method :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	v := call_method(vm, L, form, to_string(L, 2), 3)
	sync_refs(vm)
	push_value(L, v)
	return 1
}

// __has_method(ref, fn) reports whether a native `fn` exists on the form's engine class chain.
@(private)
rt_has_method :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	_, ok := script.method_class(vm.reg, to_string(L, 2), gamedb.form_kind(vm.ctx.db, form))
	lua.pushboolean(L, b32(ok))
	return 1
}

// __none_value(fn) is what a call named fn returns on None: the native's zero, else None.
@(private)
rt_none_value :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	v, _ := script.none_value(to_string(L, 1))
	push_value(L, v)
	return 1
}

// __is_engine_class(name) reports whether a Papyrus type is an engine class, not a script's.
@(private)
rt_is_engine_class :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	lua.pushboolean(L, b32(script.is_engine_class(to_string(L, 1))))
	return 1
}

// __class_of(ref) names the engine class a ref's methods resolve through.
@(private)
rt_class_of :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	chain := engine_chain(vm.ctx.db, vm.ctx.ws, form)
	lua.pushstring(L, strings.clone_to_cstring(chain[0], context.temp_allocator))
	return 1
}

// __is_a(ref, class) reports whether a ref is an instance of an engine class (lowercased name).
@(private)
rt_is_a :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	want := to_string(L, 2)
	for class in engine_chain(vm.ctx.db, vm.ctx.ws, form) {
		if strings.equal_fold(class, want) {
			lua.pushboolean(L, true)
			return 1
		}
	}
	lua.pushboolean(L, false)
	return 1
}

@(private)
rt_warn :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	log.warnf("script: %s", to_string(L, 1))
	return 0
}

@(private)
ACTOR_CHAIN := []string{"Actor", "ObjectReference", "Form"}
@(private)
OBJECT_REF_CHAIN := []string{"ObjectReference", "Form"}

// engine_chain is a form's engine class chain, most-derived first. A placed or created ref is an
// Actor when its base is an NPC_ (the player always is); other refs are ObjectReferences.
@(private)
engine_chain :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, form: script.Form_ID) -> []string {
	kind := gamedb.form_kind(db, form)
	if kind != .Unknown {
		return script.class_chain(kind)
	}
	if form == formid.PLAYER {
		return ACTOR_CHAIN
	}
	if db != nil {
		if r, ok := gamedb.ref_by_formid(db, form); ok && gamedb.is_actor(db, r.base) {
			return ACTOR_CHAIN
		}
		if cr, ok := worldstate.get_created(ws, form); ok && gamedb.is_actor(db, cr.base) {
			return ACTOR_CHAIN
		}
	}
	return OBJECT_REF_CHAIN
}
