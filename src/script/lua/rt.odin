package script_lua

// The engine half of `skymod.rt`, the runtime every converted script requires. rt.lua is the
// language half; these are the few things it cannot do without the registry or gamedb.

import "core:c"
import "core:log"
import "core:reflect"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../gamedb"
import "../../worldstate"

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
		{"__actor_value", rt_actor_value},
		{"__formula", rt_formula},
		{"__level_up_choice", rt_level_up_choice},
		{"__effect_class", rt_effect_class},
		{"__seed_spell", rt_seed_spell},
	}
	for h in hooks {
		lua.pushlightuserdata(L, vm)
		lua.pushcclosure(L, h.fn, 1)
		lua.setglobal(L, h.name)
	}

	return preload(L, "skymod.params", PARAMS_SRC) && preload(L, "skymod.rt", RT_SRC)
}


// __actor_value(name, default, kind) is rt.actor_value's engine half.
@(private)
rt_actor_value :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	kind, ok := reflect.enum_from_name(gamedb.AV_Kind, strings.to_pascal_case(to_string(L, 3), context.temp_allocator))
	if !ok {
		log.warnf("script: rt.actor_value(%q): no kind %q (static, latched, pool)", to_string(L, 1), to_string(L, 3))
		return 0
	}
	worldstate.av_create(vm.ctx.ws, to_string(L, 1), f32(lua.tonumber(L, 2)), kind)
	return 0
}

// __formula(name, src) is rt.formula's engine half.
@(private)
rt_formula :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	name, ok := reflect.enum_from_name(worldstate.Formula_Name, to_string(L, 1))
	if !ok {
		log.warnf("script: rt.formula: no formula named %q", to_string(L, 1))
		return 0
	}
	worldstate.set_formula(vm.ctx.ws, name, to_string(L, 2))
	return 0
}

// __level_up_choice(name, {AV = "formula"}) is rt.level_up_choice's engine half.
@(private)
rt_level_up_choice :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	changes := make(map[string]string, context.temp_allocator)
	if lua.istable(L, 2) {
		lua.pushnil(L)
		for lua.next(L, 2) != 0 {
			changes[strings.clone(to_string(L, -2), context.temp_allocator)] = strings.clone(to_string(L, -1), context.temp_allocator)
			lua.pop(L, 1)
		}
	}
	worldstate.set_level_choice(vm.ctx.ws, to_string(L, 1), changes)
	return 0
}

// __seed_spell(owner, spell, change) is rt.seed_spell's and rt.unseed_spell's engine half.
@(private)
rt_seed_spell :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	owner, _ := ref_form(L, 1)
	spell, _ := ref_form(L, 2)
	worldstate.seed_spell(vm.ctx.ws, owner, spell, i32(lua.tointeger(L, 3)))
	return 0
}

// __effect_class(class, __effect, claims, pure) hands a class's __effect table to the engine when
// the class loads: {AV or slot = {capacity = "formula", amount = "formula"}, caster = {...}}.
@(private)
rt_effect_class :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	class := to_string(L, 1)
	srcs := make([dynamic]worldstate.Effect_Src, context.temp_allocator)
	lua.pushvalue(L, 2)
	read_effect_table(L, class, &srcs, false)
	lua.pop(L, 1)
	worldstate.set_effect_class(vm.ctx.ws, class, srcs[:], bool(lua.toboolean(L, 3)), bool(lua.toboolean(L, 4)))
	return 0
}

// read_effect_table reads the AV table on top of the stack; its `caster` part holds terms on the caster.
@(private)
read_effect_table :: proc(L: ^lua.State, class: string, srcs: ^[dynamic]worldstate.Effect_Src, on_caster: bool) {
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		av := strings.clone(to_string(L, -2), context.temp_allocator)
		switch {
		case !lua.istable(L, -1):
			log.warnf("script: %s.__effect %s: not a table of knobs", class, av)
		case av == "caster" && !on_caster:
			read_effect_table(L, class, srcs, true)
		case:
			lua.pushnil(L)
			for lua.next(L, -2) != 0 {
				name := to_string(L, -2)
				if knob, ok := reflect.enum_from_name(worldstate.Knob, strings.to_pascal_case(name, context.temp_allocator)); ok {
					append(srcs, worldstate.Effect_Src{av, knob, strings.clone(to_string(L, -1), context.temp_allocator), on_caster})
				} else {
					log.warnf("script: %s.__effect %s: no knob %q (capacity, amount)", class, av, name)
				}
				lua.pop(L, 1)
			}
		}
		lua.pop(L, 1)
	}
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
// Actor when its base is an NPC_ (the player ref places NPC_ 0x7); other refs are ObjectReferences.
@(private)
engine_chain :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, form: script.Form_ID) -> []string {
	kind := gamedb.form_kind(db, form)
	if kind != .Unknown {
		return script.class_chain(kind)
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
