package worldstate

// Update_Timers is one form's OnUpdate registrations, as real seconds left until each fires. The
// single and the repeating one are independent, and registering again replaces that kind (Papyrus).
// A registration belongs to the form: its OnUpdate goes to every script on it.
Update_Timers :: struct {
	single:    f32, // seconds until the single update (single_on)
	repeat:    f32, // seconds until the next repeating update (repeat_on)
	interval:  f32, // the repeating update's period
	single_on: bool,
	repeat_on: bool,
}

// Activation is one request to activate `target` by `by`. `default_only` skips OnActivate and ignores
// BlockActivation (Papyrus abDefaultProcessingOnly).
Activation :: struct {
	target, by:   Form_ID,
	default_only: bool,
}

// Script_Value is a saved script member's value; a ref of 0 is None.
Script_Value :: union {
	bool,
	i32,
	f32,
	string,
	Form_ID,
	[]Script_Value,
}

// Script_Var is one member whose value differs from what its instance starts with. Owned.
Script_Var :: struct {
	script, name: string, // lowercase
	value:        Script_Value,
}

// Item_Move is `count` of `base` leaving `from` for `to`; 0 is the world (or destroyed). `ref` is the
// moved reference, 0 when the items are not one.
Item_Move :: struct {
	base, ref, from, to: Form_ID,
	count:               i32,
}

// register_update is RegisterForSingleUpdate / RegisterForUpdate: `form` gets OnUpdate after
// `seconds`, once or every `seconds`. A negative or zero interval fires at the next tick.
register_update :: proc(ws: ^World_State, form: Form_ID, seconds: f32, repeat: bool) {
	if form not_in ws.updates {ws.updates[form] = {}}
	u := &ws.updates[form]
	s := max(seconds, 0)
	if repeat {
		u.repeat, u.interval, u.repeat_on = s, s, true
	} else {
		u.single, u.single_on = s, true
	}
}

// unregister_updates is UnregisterForUpdate: both kinds stop.
unregister_updates :: proc(ws: ^World_State, form: Form_ID) {
	delete_key(&ws.updates, form)
}

// move_items records items moving for the next tick's inventory events.
move_items :: proc(ws: ^World_State, m: Item_Move) {
	append(&ws.item_moves, m)
}

// add_item_filter is AddInventoryEventFilter: filters stack.
add_item_filter :: proc(ws: ^World_State, container, filter: Form_ID) {
	if container not_in ws.item_filters {ws.item_filters[container] = make([dynamic]Form_ID)}
	append(&ws.item_filters[container], filter)
}

// remove_item_filter is RemoveInventoryEventFilter.
remove_item_filter :: proc(ws: ^World_State, container, filter: Form_ID) {
	list, ok := &ws.item_filters[container]
	if !ok {return}
	for i := len(list) - 1; i >= 0; i -= 1 {
		if list[i] == filter {ordered_remove(list, i)}
	}
	if len(list) == 0 {remove_item_filters(ws, container)}
}

// remove_item_filters is RemoveAllInventoryEventFilters.
remove_item_filters :: proc(ws: ^World_State, container: Form_ID) {
	if list, ok := ws.item_filters[container]; ok {delete(list)}
	delete_key(&ws.item_filters, container)
}

// fill_alias puts `form` in `alias`, replacing what it held.
fill_alias :: proc(ws: ^World_State, alias, form: Form_ID) {
	clear_alias(ws, alias)
	if form == 0 {return}
	ws.aliases[alias] = form
	if form not_in ws.alias_holders {ws.alias_holders[form] = make([dynamic]Form_ID)}
	append(&ws.alias_holders[form], alias)
}

// clear_alias empties `alias`.
clear_alias :: proc(ws: ^World_State, alias: Form_ID) {
	form, ok := ws.aliases[alias]
	if !ok {return}
	delete_key(&ws.aliases, alias)
	list := &ws.alias_holders[form]
	for a, i in list {
		if a == alias {
			unordered_remove(list, i)
			break
		}
	}
	if len(list) == 0 {
		delete(list^)
		delete_key(&ws.alias_holders, form)
	}
}

// reset_script_state marks `form`'s scripts initialized with no changed members.
reset_script_state :: proc(ws: ^World_State, form: Form_ID) {
	if vars, ok := ws.script_state[form]; ok {free_script_vars(vars)}
	ws.script_state[form] = nil
}

@(private)
free_script_vars :: proc(vars: [dynamic]Script_Var) {
	for v in vars {
		delete(v.script)
		delete(v.name)
		free_script_value(v.value)
	}
	delete(vars)
}

// add_script_var records a changed member of `form`'s script, taking ownership of `v`'s strings.
add_script_var :: proc(ws: ^World_State, form: Form_ID, v: Script_Var) {
	if form not_in ws.script_state {ws.script_state[form] = nil}
	append(&ws.script_state[form], v)
}

free_script_value :: proc(v: Script_Value) {
	#partial switch x in v {
	case string:
		delete(x)
	case []Script_Value:
		for e in x {free_script_value(e)}
		delete(x)
	}
}

// request_activation queues a script's Activate for the app's next tick.
request_activation :: proc(ws: ^World_State, target, by: Form_ID, default_only: bool) {
	append(&ws.activations, Activation{target, by, default_only})
}
