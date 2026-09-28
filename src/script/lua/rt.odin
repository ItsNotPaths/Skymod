package script_lua

// The engine half of `skymod.rt`, the runtime every converted script requires. rt.lua is the
// language half; these are the few things it cannot do without the registry or gamedb.

import "core:c"
import "core:log"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import lua "../../../vendor/lua"
import script ".."
import "../../formats/esm"
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
		{"__info", rt_info},
		{"__now", rt_now},
		{"__script_layers", rt_script_layers},
		{"__anim_event", rt_anim_event},
		{"__actor_value", rt_actor_value},
		{"__formula", rt_formula},
		{"__level_up_choice", rt_level_up_choice},
		{"__effect_class", rt_effect_class},
		{"__seed_spell", rt_seed_spell},
		{"__faction", rt_faction},
		{"__stolen_mark", rt_stolen_mark},
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

// __stolen_mark(item, marks) is rt.stolen_mark's engine half.
@(private)
rt_stolen_mark :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	item, _ := ref_form(L, 1)
	worldstate.set_stolen_mark(vm.ctx.ws, item, bool(lua.toboolean(L, 2)))
	return 0
}

// __faction(name, def) is rt.faction's engine half: the script faction called `name`, made from
// `def` if there is none (flags, crime, the jail and chest refs, crime_group, ranks, relations).
@(private)
rt_faction :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	ws := vm.ctx.ws
	f: gamedb.Faction
	number :: proc(L: ^lua.State, t: c.int, key: cstring) -> f64 {
		lua.getfield(L, t, key)
		defer lua.pop(L, 1)
		return f64(lua.tonumber(L, -1))
	}
	form :: proc(L: ^lua.State, t: c.int, key: cstring) -> script.Form_ID {
		lua.getfield(L, t, key)
		defer lua.pop(L, 1)
		f, _ := ref_form(L, -1)
		return f
	}
	if lua.getfield(L, 2, "flags") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			name := to_string(L, -1)
			if bit, ok := faction_flag(name); ok {f.flags |= bit} else {log.warnf("script: rt.faction(%q): no flag %q", to_string(L, 1), name)}
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	if lua.getfield(L, 2, "crime") == i32(lua.TTABLE) {
		t := lua.gettop(L)
		f.has_crime = true
		f.crime = {
			murder           = u16(number(L, t, "murder")),
			assault          = u16(number(L, t, "assault")),
			trespass         = u16(number(L, t, "trespass")),
			pickpocket       = u16(number(L, t, "pickpocket")),
			steal_multiplier = f32(number(L, t, "steal_multiplier")),
			escape           = u16(number(L, t, "escape")),
			werewolf         = u16(number(L, t, "werewolf")),
		}
		lua.getfield(L, t, "arrest");f.crime.arrest = bool(lua.toboolean(L, -1));lua.pop(L, 1)
		lua.getfield(L, t, "attack_on_detect");f.crime.attack_on_detect = bool(lua.toboolean(L, -1));lua.pop(L, 1)
	}
	lua.pop(L, 1)
	f.jail, f.follower_wait = form(L, 2, "jail"), form(L, 2, "follower_wait")
	f.stolen_chest, f.player_chest = form(L, 2, "stolen_chest"), form(L, 2, "player_chest")
	f.crime_group, f.jail_outfit = form(L, 2, "crime_group"), form(L, 2, "jail_outfit")
	ranks := make([dynamic]gamedb.Faction_Rank)
	if lua.getfield(L, 2, "ranks") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			append(&ranks, gamedb.Faction_Rank{index = u32(lua.tointeger(L, -2)), male_title = to_string(L, -1, context.allocator)})
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	slice.sort_by(ranks[:], proc(a, b: gamedb.Faction_Rank) -> bool {return a.index < b.index})
	f.ranks = ranks[:]
	id, made := worldstate.make_faction(ws, to_string(L, 1), f)
	if made && lua.getfield(L, 2, "relations") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			r := lua.gettop(L)
			other := form(L, r, "faction")
			lua.getfield(L, r, "reaction")
			combat, ok := reflect.enum_from_name(esm.Combat_Reaction, strings.to_pascal_case(to_string(L, -1), context.temp_allocator))
			lua.pop(L, 1)
			lua.getfield(L, r, "mutual")
			mutual := lua.isnil(L, -1) || bool(lua.toboolean(L, -1))
			lua.pop(L, 1)
			if other != 0 && ok {
				rel := gamedb.Faction_Relation{combat = combat, modifier = i32(number(L, r, "modifier"))}
				worldstate.set_relation(ws, id, other, rel)
				if mutual {worldstate.set_relation(ws, other, id, rel)}
			}
			lua.pop(L, 1)
		}
	}
	lua.settop(L, 2)
	push_ref(L, id)
	return 1
}

// FACTION_FLAGS are rt.faction's flag names for the FACT DATA bits.
@(private = "file")
FACTION_FLAGS := [?]struct {
	name: string,
	bit:  u32,
}{
	{"hidden", esm.FACT_HIDDEN_FROM_PC},
	{"special_combat", esm.FACT_SPECIAL_COMBAT},
	{"track_crime", esm.FACT_TRACK_CRIME},
	{"ignore_murder", esm.FACT_IGNORE_MURDER},
	{"ignore_assault", esm.FACT_IGNORE_ASSAULT},
	{"ignore_stealing", esm.FACT_IGNORE_STEALING},
	{"ignore_trespass", esm.FACT_IGNORE_TRESPASS},
	{"ignore_pickpocket", esm.FACT_IGNORE_PICKPOCKET},
	{"ignore_werewolf", esm.FACT_IGNORE_WEREWOLF},
	{"unreported_against_members", esm.FACT_DO_NOT_REPORT_CRIMES},
	{"vendor", esm.FACT_VENDOR},
}

@(private = "file")
faction_flag :: proc(name: string) -> (u32, bool) {
	for f in FACTION_FLAGS {
		if f.name == name {return f.bit, true}
	}
	return 0, false
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
rt_info :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	log.infof("%s", to_string(L, 1))
	return 0
}

// __now() is a steady clock in seconds, for timing handlers. libc's clock_gettime: time.tick_now on
// Linux is a raw syscall, ~0.3 us, and every handler reads the clock twice.
@(private)
rt_now :: proc "c" (L: ^lua.State) -> c.int {
	ts: posix.timespec
	posix.clock_gettime(.MONOTONIC, &ts)
	lua.pushnumber(L, lua.Number(f64(ts.tv_sec) + f64(ts.tv_nsec) * 1e-9))
	return 1
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
