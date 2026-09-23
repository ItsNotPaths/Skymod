package script_lua

// Gives forms their scripts at runtime: the plugin's attachments (VMAD) become script instances
// in this VM, with the authored property values filled in, and OnInit fires on each (rt.attach).

import "core:c"
import "core:log"
import "core:slice"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../formats/esm"
import "../../gamedb"

// HOLE(script, gap): an object property that resolves through a quest alias (12,896 in Skyrim.esm) reads None — aliases are never filled.
// HOLE(script, gap): quest alias scripts are never instantiated, so behaviour vanilla hangs on ReferenceAliases does not run.
// HOLE(save, gap): script instances are not saved; a loaded game rebuilds them from the plugins with member variables at their defaults, and OnInit does not re-fire.

// attach creates the instances for `scripts` on `form` and, when `init` is set, fires their
// OnInit. Returns how many instances were made.
attach :: proc(vm: ^VM, form: script.Form_ID, scripts: []esm.Script_Attach, init: bool) -> int {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	lua.getglobal(L, "require")
	lua.pushstring(L, "skymod.rt")
	if lua.pcall(L, 1, 1, 0) != 0 {
		log.errorf("lua: require skymod.rt: %s", to_string(L, -1))
		return 0
	}
	lua.getfield(L, -1, "attach")
	push_ref(L, form)
	lua.createtable(L, c.int(len(scripts)), 0)
	n := 0
	for a in scripts {
		if esm.script_attach_removed(a) {continue}
		lua.createtable(L, 0, 2)
		lua.pushstring(L, strings.clone_to_cstring(a.name, context.temp_allocator))
		lua.setfield(L, -2, "name")
		push_props(L, a.props)
		lua.setfield(L, -2, "props")
		lua.rawseti(L, -2, lua.Integer(n))
		n += 1
	}
	lua.pushboolean(L, b32(init))
	if lua.pcall(L, 3, 1, 0) != 0 {
		log.errorf("lua: rt.attach: %s", to_string(L, -1))
		return 0
	}
	return int(lua.tointeger(L, -1))
}

// start_quests attaches the scripts of every start-game-enabled quest, in form order so a run is
// reproducible. Returns how many instances were made.
start_quests :: proc(vm: ^VM, db: ^gamedb.DB, init: bool) -> int {
	quests := make([dynamic]script.Form_ID, 0, 256, context.temp_allocator)
	for q, qb in db.quest_baseline {
		if qb.start_game_enabled {append(&quests, q)}
	}
	slice.sort(quests[:])
	made := 0
	for q in quests {
		made += attach(vm, q, gamedb.form_scripts(db, q), init)
	}
	return made
}

// push_props pushes a {lowercase name = value} table of a script's authored property values.
@(private)
push_props :: proc(L: ^lua.State, props: []esm.Script_Prop) {
	lua.createtable(L, 0, c.int(len(props)))
	for p in props {
		if p.status == 3 {continue} // removed by this record
		push_prop_value(L, p.value)
		name := strings.to_lower(p.name, context.temp_allocator)
		lua.setfield(L, -2, strings.clone_to_cstring(name, context.temp_allocator))
	}
}

@(private)
push_prop_value :: proc(L: ^lua.State, v: esm.Prop_Value) {
	switch x in v {
	case esm.Prop_Object:
		push_object(L, x)
	case string:
		lua.pushstring(L, strings.clone_to_cstring(x, context.temp_allocator))
	case i32:
		lua.pushinteger(L, lua.Integer(x))
	case f32:
		lua.pushnumber(L, lua.Number(x))
	case bool:
		lua.pushboolean(L, b32(x))
	case []esm.Prop_Object:
		push_array(L, x, push_object)
	case []string:
		push_array(L, x, proc(L: ^lua.State, s: string) {
			lua.pushstring(L, strings.clone_to_cstring(s, context.temp_allocator))
		})
	case []i32:
		push_array(L, x, proc(L: ^lua.State, i: i32) {lua.pushinteger(L, lua.Integer(i))})
	case []f32:
		push_array(L, x, proc(L: ^lua.State, f: f32) {lua.pushnumber(L, lua.Number(f))})
	case []bool:
		push_array(L, x, proc(L: ^lua.State, b: bool) {lua.pushboolean(L, b32(b))})
	case:
		push_none(L)
	}
}

// push_object pushes a form's ref; one addressed through a quest alias is None until aliases fill.
@(private)
push_object :: proc(L: ^lua.State, o: esm.Prop_Object) {
	if o.alias >= 0 {
		push_none(L)
		return
	}
	push_ref(L, o.form)
}

// push_array pushes a 0-based table; rt.instance marks it as a Papyrus array.
@(private)
push_array :: proc(L: ^lua.State, xs: []$T, push: proc(L: ^lua.State, x: T)) {
	lua.createtable(L, c.int(len(xs)), 0)
	for x, i in xs {
		push(L, x)
		lua.rawseti(L, -2, lua.Integer(i))
	}
}
