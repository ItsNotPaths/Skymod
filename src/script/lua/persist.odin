package script_lua

// Script members in saves: each member that differs from its start value (declared default or plugin
// value), and which forms ran OnInit. Loading rebuilds instances from the plugins, then restores them.

import "core:c"
import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../formats/esm"
import "../../gamedb"
import "../../worldstate"

// save_scripts records every scripted form's changed members in ws.script_state. Call before
// worldstate.save_to_file. Forms without instances now (unloaded cells) keep what the store holds.
save_scripts :: proc(vm: ^VM) {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "save_vars") {return}
	lua.pushlightuserdata(L, vm)
	lua.pushcclosure(L, save_var, 1)
	if lua.pcall(L, 1, 0, 0) != 0 {log.errorf("lua: rt.save_vars: %s", to_string(L, -1))}
}

// save_var is rt.save_vars' emit: (form) resets the form's record, (form, script, member, value
// [, length]) adds one changed member.
@(private = "file")
save_var :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context
	form, _ := ref_form(L, 1)
	if lua.isnoneornil(L, 2) {
		worldstate.reset_script_state(vm.ctx.ws, form)
		return 0
	}
	value: worldstate.Script_Value
	if lua.istable(L, 4) {
		arr := make([]worldstate.Script_Value, int(lua.tointeger(L, 5)))
		for &e, i in arr {
			lua.rawgeti(L, 4, lua.Integer(i))
			e = saved_scalar(L, -1)
			lua.pop(L, 1)
		}
		value = arr
	} else {
		value = saved_scalar(L, 4)
	}
	worldstate.add_script_var(vm.ctx.ws, form, {strings.clone(to_string(L, 2)), strings.clone(to_string(L, 3)), value})
	return 0
}

@(private = "file")
saved_scalar :: proc(L: ^lua.State, idx: c.int) -> worldstate.Script_Value {
	switch x in to_value(L, idx) {
	case i32:
		return x
	case f32:
		return x
	case bool:
		return x
	case string:
		return strings.clone(x)
	case script.Form_ID:
		return x
	}
	return worldstate.Form_ID(0)
}

// attach_known gives `form` its scripts. A form the save has no record of runs OnInit; one it
// knows gets its saved members back instead. Returns how many instances were made.
attach_known :: proc(vm: ^VM, form: script.Form_ID, scripts: []esm.Script_Attach) -> int {
	vars, known := vm.ctx.ws.script_state[form]
	made := attach(vm, form, scripts, !known)
	if made == 0 {return 0}
	for v in vars {restore_var(vm, form, v)}
	return made
}

@(private = "file")
restore_var :: proc(vm: ^VM, form: script.Form_ID, v: worldstate.Script_Var) {
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "restore_var") {return}
	push_ref(L, form)
	lua.pushstring(L, strings.clone_to_cstring(v.script, context.temp_allocator))
	lua.pushstring(L, strings.clone_to_cstring(v.name, context.temp_allocator))
	if arr, is_arr := v.value.([]worldstate.Script_Value); is_arr {
		lua.createtable(L, c.int(len(arr)), 0)
		for e, i in arr {
			push_saved_scalar(L, e)
			lua.rawseti(L, -2, lua.Integer(i))
		}
	} else {
		push_saved_scalar(L, v.value)
	}
	if lua.pcall(L, 4, 0, 0) != 0 {log.errorf("lua: rt.restore_var: %s", to_string(L, -1))}
}

@(private = "file")
push_saved_scalar :: proc(L: ^lua.State, v: worldstate.Script_Value) {
	#partial switch x in v {
	case bool:
		lua.pushboolean(L, b32(x))
	case i32:
		lua.pushinteger(L, lua.Integer(x))
	case f32:
		lua.pushnumber(L, lua.Number(x))
	case string:
		lua.pushstring(L, strings.clone_to_cstring(x, context.temp_allocator))
	case worldstate.Form_ID:
		push_ref(L, x)
	case:
		push_none(L)
	}
}

// reload_scripts rebuilds every instance after a save loads mid-session: the quests, aliases and
// persistent refs, then the refs of the cells attached now.
reload_scripts :: proc(vm: ^VM, db: ^gamedb.DB) -> int {
	L := vm.L
	top := lua.gettop(L)
	if push_rt_fn(L, "reset") && lua.pcall(L, 0, 0, 0) != 0 {log.errorf("lua: rt.reset: %s", to_string(L, -1))}
	lua.settop(L, top)
	clear(&vm.ctx.ws.new_refs)
	clear(&vm.ctx.ws.gone_refs)
	clear(&vm.ctx.ws.refiles)
	clear(&vm.ctx.ws.reset_quests)
	made := start_game(vm, db)
	for cell in vm.ctx.ws.attached {made += attach_cell(vm, db, cell)}
	return made
}

// quest_var reads a quest script member for GetVMQuestVariable (conditions.Quest_Vars); `data` is
// the ^VM. Only int, float and bool members answer. Papyrus names fold case: a condition asks for
// `::EstablishScene_var`, the transpiled member is `::establishscene_var`.
quest_var :: proc(data: rawptr, quest: script.Form_ID, name: string) -> (f32, bool) {
	vm := cast(^VM)data
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "quest_var") {return 0, false}
	push_value(L, quest)
	lua.pushstring(L, strings.clone_to_cstring(strings.to_lower(name, context.temp_allocator), context.temp_allocator))
	if lua.pcall(L, 2, 1, 0) != 0 {
		log.errorf("lua: rt.quest_var: %s", to_string(L, -1))
		return 0, false
	}
	if lua.isnoneornil(L, -1) {return 0, false}
	return f32(lua.tonumber(L, -1)), true
}
