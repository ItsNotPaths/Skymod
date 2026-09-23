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

// HOLE(script, gap): a quest that starts is not reset, so its OnInit does not run a second time as Papyrus runs it.

// start_game gives every quest its scripts, then every persistent ref and actor: Papyrus runs
// their OnInit at game start, loaded or not. Form order keeps a run reproducible. Returns how many
// instances were made.
start_game :: proc(vm: ^VM, db: ^gamedb.DB, init: bool) -> int {
	forms := make([dynamic]script.Form_ID, 0, 8192, context.temp_allocator)
	for q in db.quest_baseline {append(&forms, q)}
	slice.sort(forms[:])
	made := 0
	for q in forms {
		made += attach(vm, q, gamedb.form_scripts(db, q), init)
	}

	refs := make([dynamic]gamedb.Ref, 0, 8192, context.temp_allocator)
	for _, cell in db.cell_refs {
		for r in cell {if r.persistent {append(&refs, r)}}
	}
	for _, cell in db.actor_refs {
		for r in cell {if r.persistent {append(&refs, r)}}
	}
	slice.sort_by(refs[:], proc(a, b: gamedb.Ref) -> bool {return a.form_id < b.form_id})
	for r in refs {
		made += attach_ref(vm, db, r, init)
	}
	return made
}

// attach_cell gives a cell's non-persistent refs and actors their scripts when the cell loads.
// Papyrus runs their OnInit the first time they load; rt.attach skips refs that already have
// instances, so a cell that loads again runs nothing. Returns how many instances were made.
attach_cell :: proc(vm: ^VM, db: ^gamedb.DB, cell: script.Form_ID, init: bool) -> int {
	made := 0
	for list in ([2][]gamedb.Ref{gamedb.refs_of(db, cell), gamedb.actors_of(db, cell)}) {
		for r in list {
			if !r.persistent {made += attach_ref(vm, db, r, init)}
		}
	}
	return made
}

// HOLE(script, gap): a cell reset does not re-run OnInit on its refs; Papyrus resets their variables and runs it again.
// HOLE(script, gap): refs made at runtime (PlaceAtMe, the overlay's created refs) get no scripts.
@(private)
attach_ref :: proc(vm: ^VM, db: ^gamedb.DB, r: gamedb.Ref, init: bool) -> int {
	if r.deleted {return 0}
	scripts := gamedb.effective_scripts(db, r.form_id, r.base, context.temp_allocator)
	if len(scripts) == 0 {return 0}
	return attach(vm, r.form_id, scripts, init)
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
