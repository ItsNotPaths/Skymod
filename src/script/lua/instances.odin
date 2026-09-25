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
import "../../formid"
import "../../gamedb"
import "../../worldstate"

// attach creates the instances for `scripts` on `form` and, when `init` is set, fires their
// OnInit. Returns how many instances were made.
attach :: proc(vm: ^VM, form: script.Form_ID, scripts: []esm.Script_Attach, init: bool) -> int {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "attach") {return 0}
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

// (hole quest-reset :tags script :sev gap) a quest that starts is not reset, so its scripts' and its alias scripts' OnInit do not run a second time as Papyrus runs them.

// new_game fills the aliases of the quests that run from a new game, then starts the game's
// scripts. A loaded save keeps its own fills, so it calls start_game alone.
new_game :: proc(vm: ^VM, db: ^gamedb.DB) -> int {
	for q in sorted_quests(db) {
		if gamedb.quest_start_game_enabled(db, q) {script.fill_aliases(vm.ctx.ws, db, q)}
	}
	return start_game(vm, db)
}

// start_game gives every quest and every alias its scripts, then every persistent ref and actor:
// Papyrus runs their OnInit at game start, loaded or not. Form order keeps a run reproducible.
// Returns how many instances were made.
start_game :: proc(vm: ^VM, db: ^gamedb.DB) -> int {
	made := 0
	for q in sorted_quests(db) {
		made += attach_known(vm, q, gamedb.form_scripts(db, q))
		for a in db.form_scripts[q].aliases {
			if h, ok := formid.alias_handle(q, u32(a.owner.alias)); ok {made += attach_known(vm, h, a.scripts)}
		}
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
		made += attach_ref(vm, db, r)
	}

	// created refs persist, so they attach at game start too
	created := make([dynamic]script.Form_ID, 0, len(vm.ctx.ws.created), context.temp_allocator)
	for id in vm.ctx.ws.created {append(&created, id)}
	slice.sort(created[:])
	for id in created {made += attach_created(vm, db, id)}

	effects := make([dynamic]script.Form_ID, 0, len(vm.ctx.ws.effects), context.temp_allocator)
	for h in vm.ctx.ws.effects {append(&effects, h)}
	slice.sort(effects[:])
	for h in effects {made += attach_known(vm, h, gamedb.form_scripts(db, vm.ctx.ws.effects[h].effect))}
	return made
}

@(private)
sorted_quests :: proc(db: ^gamedb.DB) -> []script.Form_ID {
	forms := make([dynamic]script.Form_ID, 0, len(db.quest_baseline), context.temp_allocator)
	for q in db.quest_baseline {append(&forms, q)}
	slice.sort(forms[:])
	return forms[:]
}

// attach_cell gives a cell's non-persistent refs and actors their scripts when the cell loads.
// Papyrus runs their OnInit the first time they load; rt.attach skips refs that already have
// instances, so a cell that loads again runs nothing. Returns how many instances were made.
attach_cell :: proc(vm: ^VM, db: ^gamedb.DB, cell: script.Form_ID) -> int {
	made := 0
	for list in ([2][]gamedb.Ref{gamedb.refs_of(db, cell), gamedb.actors_of(db, cell)}) {
		for r in list {
			if !r.persistent {made += attach_ref(vm, db, r)}
		}
	}
	return made
}

// (hole cell-reset :tags script :sev gap :needs (game-clock)) a cell reset does not re-run OnInit on its refs; Papyrus resets their variables and runs it again.
@(private)
attach_ref :: proc(vm: ^VM, db: ^gamedb.DB, r: gamedb.Ref) -> int {
	if r.deleted || worldstate.is_deleted(vm.ctx.ws, r.form_id) {return 0}
	scripts := gamedb.effective_scripts(db, r.form_id, r.base, context.temp_allocator)
	if len(scripts) == 0 {return 0}
	return attach_known(vm, r.form_id, scripts)
}

// attach_created gives a created ref the scripts of its base. In an attached cell it joins the
// cell's refs, so the next tick's transitions send it OnLoad.
@(private)
attach_created :: proc(vm: ^VM, db: ^gamedb.DB, id: script.Form_ID) -> int {
	ws := vm.ctx.ws
	cr, ok := worldstate.get_created(ws, id)
	if !ok || worldstate.is_deleted(ws, id) {return 0}
	scripts := gamedb.effective_scripts(db, id, cr.base, context.temp_allocator)
	if len(scripts) == 0 {return 0}
	made := attach_known(vm, id, scripts)
	c := script.Call{ws = ws, db = db}
	if refs, attached := &ws.attached[script.ref_grid_cell(&c, id)]; attached && !slice.contains(refs[:], id) {
		append(refs, id)
	}
	return made
}

// sync_refs gives refs created since the last call their scripts, OnInit included, so a script's
// PlaceAtMe returns a ref whose OnInit has run. It drops the scripts of refs deleted since: they
// leave the tick schedule, and their registrations and saved members go. Effects started or ended
// since get their instance and OnEffectStart, or OnEffectFinish.
sync_refs :: proc(vm: ^VM) {
	ws := vm.ctx.ws
	for len(ws.new_effects) > 0 || len(ws.ended_effects) > 0 {
		started := slice.clone(ws.new_effects[:], context.temp_allocator)
		clear(&ws.new_effects)
		for h in started {
			e := ws.effects[h]
			attach_known(vm, h, gamedb.form_scripts(vm.ctx.db, e.effect))
			send_own(vm, h, "OnEffectStart", e.target, e.caster)
		}
		ended := slice.clone(ws.ended_effects[:], context.temp_allocator)
		clear(&ws.ended_effects)
		for h in ended {
			e, ok := &ws.effects[h]
			if !ok {continue}
			e.finished = true
			worldstate.unregister_anim_events(ws, h)
			worldstate.unregister_updates(ws, h)
			send_own(vm, h, "OnEffectFinish", e.target, e.caster)
		}
	}
	for len(ws.new_refs) > 0 || len(ws.gone_refs) > 0 {
		gone := slice.clone(ws.gone_refs[:], context.temp_allocator)
		clear(&ws.gone_refs)
		for id in gone {
			detach(vm, id)
			worldstate.forget_scripts(ws, id)
		}
		made := slice.clone(ws.new_refs[:], context.temp_allocator)
		clear(&ws.new_refs)
		for id in made {attach_created(vm, vm.ctx.db, id)}
	}
}

// detach is rt.detach: the form's instances go.
@(private)
detach :: proc(vm: ^VM, form: script.Form_ID) {
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "detach") {return}
	push_ref(L, form)
	if lua.pcall(L, 1, 0, 0) != 0 {log.errorf("lua: rt.detach: %s", to_string(L, -1))}
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

// push_object pushes a form's ref, or the alias handle when the value names a quest alias.
@(private)
push_object :: proc(L: ^lua.State, o: esm.Prop_Object) {
	if o.alias < 0 {
		push_ref(L, o.form)
		return
	}
	h, _ := formid.alias_handle(o.form, u32(o.alias))
	push_ref(L, h)
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
