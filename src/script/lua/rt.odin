package script_lua

// The engine half of `skymod.rt`, the runtime every converted script requires. rt.lua is the
// language half; these are the few things it cannot do without the registry or gamedb.

import "core:c"
import "core:log"
import "core:math"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import lua "../../../vendor/lua"
import script ".."
import "../../combat"
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
		{"__content_files", rt_content_files},
		{"__spell_def", rt_spell_def},
		{"__power_def", rt_power_def},
		{"__item_def", rt_item_def},
		{"__global", rt_global},
		{"__effect_def", rt_effect_def},
		{"__av_part", rt_av_part},
		{"__seed_spell", rt_seed_spell},
		{"__faction", rt_faction},
		{"__stolen_mark", rt_stolen_mark},
		{"__resolve", rt_resolve},
		{"__ref", rt_ref},
		{"__method_kind", rt_method_kind},
		{"__native_condition", rt_native_condition},
		{"__condition", rt_condition},
		{"__make_zone", rt_zone},
		{"__spawn_hazard", rt_spawn_hazard},
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
	kind, ok := gamedb.av_kind_named(to_string(L, 3))
	if !ok {
		log.warnf("script: rt.actor_value(%q): no kind %q (static, latched, pool, timer, stopwatch, gametimer, gamestopwatch)", to_string(L, 1), to_string(L, 3))
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
	f.jail, f.follower_wait = field_ref(L, 2, "jail"), field_ref(L, 2, "follower_wait")
	f.stolen_chest, f.player_chest = field_ref(L, 2, "stolen_chest"), field_ref(L, 2, "player_chest")
	f.crime_group, f.jail_outfit = field_ref(L, 2, "crime_group"), field_ref(L, 2, "jail_outfit")
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
			other := field_ref(L, r, "faction")
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
	worldstate.set_effect_class(vm.ctx.ws, vm.ctx.db, class, srcs[:], bool(lua.toboolean(L, 3)), bool(lua.toboolean(L, 4)))
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
			read_knobs(L, class, av, srcs, on_caster)
		}
		lua.pop(L, 1)
	}
}

// read_avs reads {AV = {knob = "formula"}} on top of the stack: the av or caster part of rt.effect.
@(private)
read_avs :: proc(L: ^lua.State, owner: string, srcs: ^[dynamic]worldstate.Effect_Src, on_caster: bool) {
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		av := to_string(L, -2)
		if lua.istable(L, -1) {read_knobs(L, owner, av, srcs, on_caster)} else {log.warnf("rt.effect %s: %s is not a table of knobs", owner, av)}
		lua.pop(L, 1)
	}
}

// read_knobs reads one AV's {capacity = "formula", amount = "formula"} on top of the stack.
@(private)
read_knobs :: proc(L: ^lua.State, owner, av: string, srcs: ^[dynamic]worldstate.Effect_Src, on_caster: bool) {
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		name := to_string(L, -2)
		if knob, ok := reflect.enum_from_name(worldstate.Knob, strings.to_pascal_case(name, context.temp_allocator)); ok {
			append(srcs, worldstate.Effect_Src{av, knob, to_string(L, -1), on_caster})
		} else {
			log.warnf("script: %s %s: no knob %q (capacity, amount)", owner, av, name)
		}
		lua.pop(L, 1)
	}
}

// run_magic_hit is worldstate.Hooks.magic_hit: rt.magic_hit runs the magichit hooks and the
// effect's own, then its context gives back m, d and the tunables. def is nil for an effect
// with no definition.
@(private)
run_magic_hit :: proc(data: rawptr, def: ^worldstate.Effect_Def, e: ^worldstate.Active_Effect) -> bool {
	vm := cast(^VM)data
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "magic_hit") {return true}
	tunables := def.tunables[:] if def != nil else nil
	lua.pushstring(L, strings.clone_to_cstring(strings.to_lower(def.name if def != nil else "", context.temp_allocator), context.temp_allocator))
	for f in ([4]script.Form_ID{e.caster, e.target, e.spell, e.effect}) {push_value(L, f if f != 0 else nil)}
	lua.pushnumber(L, lua.Number(e.magnitude))
	lua.pushnumber(L, lua.Number(e.duration))
	lua.createtable(L, 0, i32(len(tunables)))
	for t, i in tunables {
		lua.pushnumber(L, lua.Number(e.tunables[i]))
		lua.setfield(L, -2, strings.clone_to_cstring(t.name, context.temp_allocator))
	}
	if lua.pcall(L, 8, 1, 0) != 0 {
		log.errorf("lua: landing %X: %s", e.effect, to_string(L, -1))
		return true // a broken hook does not keep the effect from starting
	}
	if !lua.istable(L, -1) {return false}
	apply_part(L, "m", &e.magnitude)
	apply_part(L, "d", &e.duration)
	for t, i in tunables {
		if lua.getfield(L, -1, strings.clone_to_cstring(t.name, context.temp_allocator)) == i32(lua.TNUMBER) {e.tunables[i] = f32(lua.tonumber(L, -1))}
		lua.pop(L, 1)
	}
	return true
}

// run_magic_cost is worldstate.Hooks.magic_cost: rt.magic_cost runs the magiccost hooks on `cost`.
// False refuses the cast.
@(private)
run_magic_cost :: proc(data: rawptr, caster, spell: worldstate.Form_ID, cost: ^f32) -> bool {
	vm := cast(^VM)data
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "magic_cost") {return true}
	push_value(L, caster if caster != 0 else nil)
	push_value(L, spell if spell != 0 else nil)
	lua.pushnumber(L, lua.Number(cost^))
	if lua.pcall(L, 3, 1, 0) != 0 {
		log.errorf("lua: magiccost hooks: %s", to_string(L, -1))
		return true
	}
	if !lua.istable(L, -1) {return false}
	apply_part(L, "cost", cost)
	return true
}

// run_weapon_cost is worldstate.Hooks.weapon_cost: rt.weapon_cost runs the meleecost or archcost
// hooks on an attack's Stamina `cost`. False refuses it.
@(private)
run_weapon_cost :: proc(data: rawptr, actor, weapon: worldstate.Form_ID, kind: combat.Attack_Kind, ranged: bool, cost: ^f32) -> bool {
	vm := cast(^VM)data
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "weapon_cost") {return true}
	push_value(L, actor if actor != 0 else nil)
	push_value(L, weapon if weapon != 0 else nil)
	lua.pushboolean(L, b32(ranged))
	lua.pushboolean(L, b32(.Power in kind))
	lua.pushboolean(L, b32(.Bash in kind))
	lua.pushnumber(L, lua.Number(cost^))
	if lua.pcall(L, 6, 1, 0) != 0 {
		log.errorf("lua: weapon cost hooks: %s", to_string(L, -1))
		return true
	}
	if !lua.istable(L, -1) {return false}
	apply_part(L, "cost", cost)
	return true
}

// run_weapon_hit is worldstate.Hooks.weapon_hit: rt.weapon_hit runs the meleehit or archhit hooks,
// which fill the attack's parts and name the spells it puts on the target. False stops the hit.
@(private)
run_weapon_hit :: proc(data: rawptr, a: ^combat.Attack, ranged: bool, spells: ^[dynamic]worldstate.Form_ID) -> bool {
	vm := cast(^VM)data
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "weapon_hit") {return true}
	for f in ([3]worldstate.Form_ID{a.attacker, a.target, a.weapon}) {push_value(L, f if f != 0 else nil)}
	lua.pushboolean(L, b32(ranged))
	for k in ([3]combat.Attack_Kind{{.Power}, {.Sneak}, {.Bash}}) {lua.pushboolean(L, b32(k <= a.kind))}
	if lua.pcall(L, 7, 1, 0) != 0 {
		log.errorf("lua: weapon hit hooks: %s", to_string(L, -1))
		return true
	}
	if !lua.istable(L, -1) {return false}
	get_part(L, "damage", &a.damage)
	get_part(L, "armor_pen", &a.armor_pen)
	get_part(L, "crit_chance", &a.crit_chance)
	get_part(L, "crit_damage", &a.crit_damage)
	get_part(L, "power_mult", &a.power_mult)
	get_part(L, "sneak_mult", &a.sneak_mult)
	if lua.getfield(L, -1, "spells") == i32(lua.TTABLE) {
		for i in 0 ..< lua.Integer(lua.rawlen(L, -1)) {
			lua.rawgeti(L, -1, i)
			if f, ok := ref_form(L, -1); ok {append(spells, f)}
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	return true
}

// run_armor_hit is worldstate.Hooks.armor_hit: rt.armor_hit runs the armorhit hooks on one worn
// piece's rating.
@(private)
run_armor_hit :: proc(data: rawptr, wearer, item: worldstate.Form_ID, rating: ^combat.Part) {
	vm := cast(^VM)data
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "armor_hit") {return}
	push_value(L, wearer)
	push_value(L, item)
	if lua.pcall(L, 2, 1, 0) != 0 {
		log.errorf("lua: armorhit hooks: %s", to_string(L, -1))
		return
	}
	if lua.istable(L, -1) {read_part(L, rating)}
}

// apply_part makes `v` what the part `key` of the table on top of the stack says of it, from the
// part's value when it has one (rt.magic_hit settles m and d before the effect's own hooks).
@(private = "file")
apply_part :: proc(L: ^lua.State, key: cstring, v: ^f32) {
	if lua.getfield(L, -1, key) != i32(lua.TTABLE) {
		lua.pop(L, 1)
		return
	}
	defer lua.pop(L, 1)
	if lua.getfield(L, -1, "value") == i32(lua.TNUMBER) {v^ = f32(lua.tonumber(L, -1))}
	lua.pop(L, 1)
	p := combat.KEEP
	read_part(L, &p)
	v^ = combat.apply(p, v^)
}

// get_part reads the part `key` of the table on top of the stack.
@(private = "file")
get_part :: proc(L: ^lua.State, key: cstring, p: ^combat.Part) {
	if lua.getfield(L, -1, key) == i32(lua.TTABLE) {read_part(L, p)}
	lua.pop(L, 1)
}

// read_part reads the part on top of the stack: add, mult and set.
@(private = "file")
read_part :: proc(L: ^lua.State, p: ^combat.Part) {
	number :: proc(L: ^lua.State, key: cstring) -> (f32, bool) {
		defer lua.pop(L, 1)
		if lua.getfield(L, -1, key) != i32(lua.TNUMBER) {return 0, false}
		return f32(lua.tonumber(L, -1)), true
	}
	p.add, _ = number(L, "add")
	if m, ok := number(L, "mult"); ok {p.mult = m}
	p.set, p.has_set = number(L, "set")
}

// __global(name) reads the GLOB with that editor id: global.<Name>. 0 for none.
@(private)
rt_global :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	g, ok := gamedb.global_by_editor_id(vm.ctx.db, to_string(L, 1))
	lua.pushnumber(L, lua.Number(worldstate.global_value(vm.ctx.ws, vm.ctx.db, g) if ok else 0))
	return 1
}

// __spell_def(name, def) hands an rt.spell definition to the engine (worldstate.set_spell_def).
@(private)
rt_spell_def :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	src := worldstate.Spell_Def_Src{name = to_string(L, 1)}
	src.form, src.display, src.use = field_str(L, 2, "form"), field_str(L, 2, "name"), field_str(L, 2, "use")
	src.cost = field_num(L, 2, "cost")
	read_shape(L, 2, &src)
	tags := make([dynamic]string, context.temp_allocator)
	if lua.getfield(L, 2, "tags") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {append(&tags, to_string(L, -1)); lua.pop(L, 1)}
	}
	lua.pop(L, 1)
	src.tags, src.entries = tags[:], read_applies(L, 2)
	worldstate.set_spell_def(vm.ctx.ws, vm.ctx.db, src)
	return 0
}

// read_shape reads the table at `t`'s `shape`: "self", a primitive's name, or { "projectile",
// range =, speed =, gravity =, radius =, spread = degrees, burst =, lasts = "3s", follow =, place =,
// anchor = }.
@(private)
read_shape :: proc(L: ^lua.State, t: c.int, src: ^worldstate.Spell_Def_Src) {
	defer lua.pop(L, 1)
	if lua.getfield(L, t, "shape") != i32(lua.TTABLE) {
		src.shape = to_string(L, -1) if lua.type(L, -1) != .NIL else ""
		return
	}
	s := lua.gettop(L)
	lua.geti(L, s, 0)
	src.shape = to_string(L, -1)
	lua.pop(L, 1)
	src.body = {
		range   = field_num(L, s, "range"),
		speed   = field_num(L, s, "speed"),
		gravity = field_num(L, s, "gravity"),
		radius  = field_num(L, s, "radius"),
		spread  = field_num(L, s, "spread") * math.RAD_PER_DEG,
		burst   = field_num(L, s, "burst"),
	}
	lua.getfield(L, s, "follow")
	src.body.follow = bool(lua.toboolean(L, -1))
	lua.getfield(L, s, "place")
	src.body.place = bool(lua.toboolean(L, -1))
	lua.pop(L, 2)
	src.lasts, src.anchor = field_str(L, s, "lasts"), field_str(L, s, "anchor")
}

// read_applies reads the table at `t`'s `applies`: { { "EffectName", m =, d =, area =, hits = }, ... }.
@(private)
read_applies :: proc(L: ^lua.State, t: c.int) -> []worldstate.Spell_Entry_Src {
	entries := make([dynamic]worldstate.Spell_Entry_Src, context.temp_allocator)
	if lua.getfield(L, t, "applies") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			e := lua.gettop(L)
			lua.geti(L, e, 0)
			entry := worldstate.Spell_Entry_Src{effect = to_string(L, -1)}
			lua.pop(L, 1)
			entry.m, entry.area, entry.d, entry.hits = field_num(L, e, "m"), field_num(L, e, "area"), field_str(L, e, "d"), field_str(L, e, "hits")
			append(&entries, entry)
			lua.pop(L, 1)
		}
	}
	lua.pop(L, 1)
	return entries[:]
}

@(private)
field_str :: proc(L: ^lua.State, t: c.int, key: cstring) -> string {
	lua.getfield(L, t, key)
	defer lua.pop(L, 1)
	return to_string(L, -1) if lua.type(L, -1) != .NIL else ""
}

@(private)
field_ref :: proc(L: ^lua.State, t: c.int, key: cstring) -> script.Form_ID {
	lua.getfield(L, t, key)
	defer lua.pop(L, 1)
	f, _ := ref_form(L, -1)
	return f
}

@(private)
field_num :: proc(L: ^lua.State, t: c.int, key: cstring) -> f32 {
	lua.getfield(L, t, key)
	defer lua.pop(L, 1)
	return f32(lua.tonumber(L, -1))
}

// __power_def(name, def) hands an rt.power definition to the engine (worldstate.set_power_def). A
// power without `words` is one word: its own `applies` and `cooldown`.
@(private)
rt_power_def :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	src := worldstate.Power_Def_Src{name = to_string(L, 1)}
	src.form, src.display, src.shape, src.mult = field_str(L, 2, "form"), field_str(L, 2, "name"), field_str(L, 2, "shape"), field_str(L, 2, "cooldown_mult")
	src.cooldown = field_str(L, 2, "cooldown_av")
	words := make([dynamic]worldstate.Power_Word_Src, context.temp_allocator)
	if lua.getfield(L, 2, "words") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			w := lua.gettop(L)
			append(&words, worldstate.Power_Word_Src{entries = read_applies(L, w), cooldown = field_str(L, w, "cooldown")})
			lua.pop(L, 1)
		}
	} else {
		append(&words, worldstate.Power_Word_Src{entries = read_applies(L, 2), cooldown = field_str(L, 2, "cooldown")})
	}
	lua.pop(L, 1)
	src.words = words[:]
	worldstate.set_power_def(vm.ctx.ws, vm.ctx.db, src)
	return 0
}

// __item_def(name, def) hands an rt.item definition to the engine (worldstate.set_item_def).
@(private)
rt_item_def :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	src := worldstate.Item_Def_Src{name = to_string(L, 1)}
	src.form, src.use, src.casts = field_str(L, 2, "form"), field_str(L, 2, "use"), field_str(L, 2, "casts")
	tags := make([dynamic]string, context.temp_allocator)
	if lua.getfield(L, 2, "tags") == i32(lua.TTABLE) {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {append(&tags, to_string(L, -1)); lua.pop(L, 1)}
	}
	lua.pop(L, 1)
	src.tags, src.entries = tags[:], read_applies(L, 2)
	worldstate.set_item_def(vm.ctx.ws, vm.ctx.db, src)
	return 0
}

// __av_part(ref, name, part) reads ref.av.<name>.<part> (worldstate.av_part).
@(private)
rt_av_part :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	part, ok := reflect.enum_from_name(worldstate.AV_Part, strings.to_pascal_case(to_string(L, 3), context.temp_allocator))
	if !ok {return c.int(lua.L_error(L, "read an actor value as .av.<Name>.value, .capacity or .amount"))}
	lua.pushnumber(L, lua.Number(worldstate.av_part(vm.ctx.ws, vm.ctx.db, worldstate.resolve(vm.ctx.ws, form), to_string(L, 2), part)))
	return 1
}

// __effect_def(name, def) hands an rt.effect definition to the engine (worldstate.set_effect_def).
@(private)
rt_effect_def :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	src := worldstate.Effect_Def_Src{name = to_string(L, 1)}
	terms := make([dynamic]worldstate.Effect_Src, context.temp_allocator)
	defaults := make([dynamic]worldstate.Tunable, context.temp_allocator)
	tags := make([dynamic]string, context.temp_allocator)
	scripts := make([dynamic]esm.Script_Attach, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, 2) != 0 {
		key := to_string(L, -2)
		switch {
		case key == "form": src.form = to_string(L, -1)
		case key == "resist": src.resist = to_string(L, -1)
		case key == "hooks": // Lua keeps them (rt.magic_hit)
		case key == "stack": src.stack = to_string(L, -1)
		case key == "nostack": src.nostack = to_string(L, -1)
		case key == "taper": src.taper = to_string(L, -1)
		case key == "tags":
			lua.pushnil(L)
			for lua.next(L, -2) != 0 {append(&tags, to_string(L, -1)); lua.pop(L, 1)}
		case key == "script": read_moments(L, &scripts)
		case (key == "av" || key == "caster") && lua.istable(L, -1): read_avs(L, src.name, &terms, key == "caster")
		case lua.type(L, -1) == .NUMBER: append(&defaults, worldstate.Tunable{key, f32(lua.tonumber(L, -1))})
		case: log.warnf("rt.effect %s: %s: formulas go under av or caster, decisions in hooks", src.name, key)
		}
		lua.pop(L, 1)
	}
	src.terms, src.defaults, src.tags, src.scripts = terms[:], defaults[:], tags[:], scripts[:]
	worldstate.set_effect_def(vm.ctx.ws, vm.ctx.db, src)
	return 0
}

// read_moments reads `script` on top of the stack: one script, or a list of them.
@(private)
read_moments :: proc(L: ^lua.State, out: ^[dynamic]esm.Script_Attach) {
	list := false // a single script's table has no entry 1
	if lua.istable(L, -1) {
		first, second := lua.geti(L, -1, 0), lua.geti(L, -2, 1)
		lua.pop(L, 2)
		list = first == i32(lua.TTABLE) || second != i32(lua.TNIL)
	}
	if !list {
		append(out, read_moment(L))
		return
	}
	for i: lua.Integer = 0; lua.geti(L, -1, i) != i32(lua.TNIL); i += 1 {
		append(out, read_moment(L))
		lua.pop(L, 1)
	}
	lua.pop(L, 1)
}

// read_moment reads `script = "Name"` or `{ "Name", Prop = value }` on top of the stack. A ref value
// is an object property; numbers, strings and booleans are the rest.
@(private)
read_moment :: proc(L: ^lua.State) -> esm.Script_Attach {
	if !lua.istable(L, -1) {return {name = to_string(L, -1)}}
	lua.geti(L, -1, 0)
	s := esm.Script_Attach{name = to_string(L, -1)}
	lua.pop(L, 1)
	props := make([dynamic]esm.Script_Prop, context.temp_allocator)
	lua.pushnil(L)
	for lua.next(L, -2) != 0 {
		defer lua.pop(L, 1)
		if lua.type(L, -2) != .STRING {continue}
		p := esm.Script_Prop{name = to_string(L, -2), status = 1}
		if f, ok := ref_form(L, -1); ok {
			p.kind, p.value = .Object, esm.Prop_Object{form = f, alias = -1}
		} else {
			#partial switch lua.type(L, -1) {
			case .BOOLEAN: p.kind, p.value = .Bool, bool(lua.toboolean(L, -1))
			case .STRING:  p.kind, p.value = .String, to_string(L, -1)
			case .NUMBER:
				if lua.isinteger(L, -1) {p.kind, p.value = .Int, i32(lua.tointeger(L, -1))} else {p.kind, p.value = .Float, f32(lua.tonumber(L, -1))}
			case: continue
			}
		}
		append(&props, p)
	}
	s.props = props[:]
	return s
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
// __make_zone(def) is rt.zone's engine half: it makes the zone and returns its ref.
@(private)
rt_zone :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	z := worldstate.Zone {
		left   = field_num(L, 1, "lifetime"),
		caster = field_ref(L, 1, "caster"),
		spell  = field_ref(L, 1, "spell"),
		every  = field_num(L, 1, "every"),
		burst  = field_num(L, 1, "burst"),
		follow = field_ref(L, 1, "follow"),
	}
	lua.getfield(L, 1, "shape")
	if r := field_num(L, -1, "sphere"); r > 0 {
		z.shape = {half = r, kind = .Sphere}
	} else if lua.getfield(L, -1, "box") == i32(lua.TTABLE) {
		for i in 0 ..< 3 {
			lua.geti(L, -1, lua.Integer(i))
			z.shape.half[i] = f32(lua.tonumber(L, -1)) / 2
			lua.pop(L, 1)
		}
		z.shape.kind = .Box
	}
	lua.settop(L, 1)
	id := worldstate.make_zone(vm.ctx.ws, vm.ctx.db, field_ref(L, 1, "form"), field_ref(L, 1, "at"), z, int(field_num(L, 1, "limit")))
	push_ref(L, id)
	return 1
}

// __spawn_hazard(effect) is rt.spawn_hazard's engine half (worldstate.effect_hazard).
@(private)
rt_spawn_hazard :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	effect, _ := ref_form(L, 1)
	push_ref(L, worldstate.effect_hazard(vm.ctx.ws, vm.ctx.db, effect))
	return 1
}

// __resolve(ref) is the actor PlayerRef stands for; any other ref as it is.
@(private)
rt_resolve :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	if vm.ctx.ws != nil {form = worldstate.resolve(vm.ctx.ws, form)}
	push_ref(L, form)
	return 1
}

// __ref(name) is the form a name means, "File.esm:012FCD" or an editor id, as a ref; nil for none.
@(private)
rt_ref :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, ok := worldstate.form_by_name(vm.ctx.ws, vm.ctx.db, to_string(L, 1))
	if !ok {return 0}
	push_ref(L, form)
	return 1
}

// __method_kind(ref, name) is what ref:name() calls: "native" for a native on the ref's class chain,
// unless it is a stub the condition function of its name stands in for; then "condition" for a
// condition function; nil for none.
@(private)
rt_method_kind :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	form, _ := ref_form(L, 1)
	name := to_string(L, 2)
	class, declared := script.method_class(vm.reg, name, gamedb.form_kind(vm.ctx.db, form))
	_, condition := esm.condition_function_by_name(name)
	switch {
	case declared && !script.condition_stands_in(vm.reg, class, name): lua.pushstring(L, "native")
	case condition:                                                    lua.pushstring(L, "condition")
	case:                                                              return 0
	}
	return 1
}

// __native_condition(class, fn) reports whether the condition function of that name stands in for
// a native with no body (script.condition_stands_in).
@(private)
rt_native_condition :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	lua.pushboolean(L, b32(script.condition_stands_in(vm.reg, to_string(L, 1), to_string(L, 2))))
	return 1
}

// __condition(ref, name, args...) runs a condition function on ref, its arguments as
// worldstate.condition_param takes them. An Is* or Has* function answers a boolean, the rest a
// number (esm.condition_answers_bool).
@(private)
rt_condition :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	subject, _ := ref_form(L, 1)
	fn, _ := esm.condition_function_by_name(to_string(L, 2))
	info := esm.condition_function(fn)
	params: [2]u64
	for kind, i in info.params {
		idx := c.int(3 + i)
		if lua.isnoneornil(L, idx) {continue}
		arg: worldstate.Condition_Arg
		if f, is_ref := ref_form(L, idx); is_ref {
			arg = f
		} else if lua.type(L, idx) == .NUMBER {
			arg = f64(lua.tonumber(L, idx))
		} else {
			arg = to_string(L, idx)
		}
		v, err := worldstate.condition_param(vm.ctx.ws, vm.ctx.db, kind, arg)
		if err != "" {return c.int(lua.L_error(L, "%s", strings.clone_to_cstring(strings.concatenate({info.name, ": ", err}, context.temp_allocator), context.temp_allocator)))}
		params[i] = v
	}
	v: f32
	if worldstate.condition_call != nil {
		v = worldstate.condition_call(vm.ctx.ws, vm.ctx.db, {function = fn, param1 = params[0], param2 = params[1], param3 = -1}, subject, 0)
	}
	if esm.condition_answers_bool(info.name) {
		lua.pushboolean(L, b32(v != 0))
	} else {
		lua.pushnumber(L, lua.Number(v))
	}
	return 1
}

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
	form := worldstate.resolve(ws, form) if ws != nil else form // PlayerRef is the controlled actor
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
