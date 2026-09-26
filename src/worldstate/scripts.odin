package worldstate

import "core:strings"
import "../formid"
import "../gamedb"

// Update_Timers is one form's update registrations, as time left until each fires: real seconds for
// OnUpdate, game hours for OnUpdateGameTime. The single and the repeating one are independent, and
// registering again replaces that kind (Papyrus). A registration belongs to the form: its event goes
// to every script on it.
Update_Timers :: struct {
	single:    f32, // time until the single update (single_on)
	repeat:    f32, // time until the next repeating update (repeat_on)
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
	via:                 Item_Via,
}

// Item_Via is how the player gains or loses items, as the AIPL and REMP story events carry it:
// the engine's AQUIRE_TYPE (CommonLibSSE BGSAddToPlayerInventoryEvent.h), which the vanilla nodes
// test (WIPlayerAddItemPurchaseNode V1 == 2, WIAddItem01 == 4 "just lying around", WIAddItem02 == 5
// "sifting through trash"). A removal uses the same values: WIRemoveItem01 == 4 is a dropped weapon.
Item_Via :: enum u32 {
	None,
	Steal,
	Buy,
	Pickpocket,
	World,
	Container,
	Dead_Body,
}

// register_update is RegisterFor[Single]Update[GameTime] on `timers` (ws.updates or ws.game_updates):
// `form` gets its update after `interval`, once or every `interval`. A negative or zero interval
// fires at the next tick.
register_update :: proc(timers: ^map[Form_ID]Update_Timers, form: Form_ID, interval: f32, repeat: bool) {
	if form not_in timers {timers[form] = {}}
	u := &timers[form]
	s := max(interval, 0)
	if repeat {
		u.repeat, u.interval, u.repeat_on = s, s, true
	} else {
		u.single, u.single_on = s, true
	}
}

// unregister_updates stops every update registration of `form`, real and game time.
unregister_updates :: proc(ws: ^World_State, form: Form_ID) {
	delete_key(&ws.updates, form)
	delete_key(&ws.game_updates, form)
}

// Anim_Reg is one RegisterForAnimationEvent: `form` hears `event` from the sender. The name is
// lower case and owned.
Anim_Reg :: struct {
	form:  Form_ID,
	event: string,
}

// register_anim_event is RegisterForAnimationEvent. A registration belongs to the registering
// form, as update registrations do.
register_anim_event :: proc(ws: ^World_State, sender, form: Form_ID, event: string) {
	if sender not_in ws.anim_regs {ws.anim_regs[sender] = make([dynamic]Anim_Reg)}
	list := &ws.anim_regs[sender]
	for r in list {if r.form == form && strings.equal_fold(r.event, event) {return}}
	append(list, Anim_Reg{form, strings.to_lower(event)})
}

// unregister_anim_event is UnregisterForAnimationEvent.
unregister_anim_event :: proc(ws: ^World_State, sender, form: Form_ID, event: string) {
	drop_anim_regs(ws, sender, form, event)
}

// unregister_anim_events drops every registration `form` holds: a stopped quest or alias, an
// ended effect, a deleted ref.
unregister_anim_events :: proc(ws: ^World_State, form: Form_ID) {
	senders := make([dynamic]Form_ID, context.temp_allocator)
	for sender in ws.anim_regs {append(&senders, sender)}
	for sender in senders {drop_anim_regs(ws, sender, form, "")}
}

// drop_anim_regs removes `form`'s registrations on `sender`: for `event`, or all when it is "".
@(private = "file")
drop_anim_regs :: proc(ws: ^World_State, sender, form: Form_ID, event: string) {
	list, ok := &ws.anim_regs[sender]
	if !ok {return}
	for i := len(list) - 1; i >= 0; i -= 1 {
		r := list[i]
		if r.form != form || (event != "" && !strings.equal_fold(r.event, event)) {continue}
		delete(r.event)
		ordered_remove(list, i)
	}
	if len(list) == 0 {
		delete(list^)
		delete_key(&ws.anim_regs, sender)
	}
}

// anim_registrants lists the forms that hear `event` from `sender`, in registration order.
anim_registrants :: proc(ws: ^World_State, sender: Form_ID, event: string) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	list, _ := ws.anim_regs[sender]
	for r in list {
		if strings.equal_fold(r.event, event) {append(&out, r.form)}
	}
	return out[:]
}

// move_items records items moving for the next tick's inventory events.
move_items :: proc(ws: ^World_State, m: Item_Move) {
	append(&ws.item_moves, m)
}

// Story_Event is one event for the story manager: its SMEN type and its data, which conditions,
// From_Event aliases and the started quest's handlers read. Which members an event fills depends on
// its type (CK wiki, GetEventData).
Story_Event :: struct {
	type:                 Story_Type,
	keyword:              Form_ID, // K1: a script event's keyword
	location1, location2: Form_ID, // L1, L2
	ref1, ref2:           Form_ID, // R1, R2: the actors or refs
	object:               Form_ID, // O1: an item that is not a ref (Player Add Item)
	form:                 Form_ID, // F1
	quest:                Form_ID, // Q1
	value1, value2:       i32,     // V1, V2
}

// Story_Type is an SMEN event type, as its four characters.
Story_Type :: [4]u8

STORY_SCRIPT :: Story_Type{'S', 'C', 'P', 'T'}
STORY_CHANGE_LOCATION :: Story_Type{'C', 'L', 'O', 'C'}
STORY_KILL :: Story_Type{'K', 'I', 'L', 'L'}
STORY_LEVEL :: Story_Type{'L', 'E', 'V', 'L'}
STORY_SKILL :: Story_Type{'S', 'K', 'I', 'L'} // value1: the skill's actor value index
STORY_CAST :: Story_Type{'C', 'A', 'S', 'T'}
STORY_ADD_ITEM :: Story_Type{'A', 'I', 'P', 'L'}
STORY_REMOVE_ITEM :: Story_Type{'R', 'E', 'M', 'P'}
STORY_RELATIONSHIP :: Story_Type{'C', 'H', 'R', 'R'}
STORY_VOICE_POWER :: Story_Type{'N', 'V', 'P', 'E'}

// queue_story_event keeps an engine event for the next tick's story manager.
queue_story_event :: proc(ws: ^World_State, e: Story_Event) {
	append(&ws.story_events, e)
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

// alias_ref is the ref in alias `id` of `quest`; 0 when it is empty.
alias_ref :: proc(ws: ^World_State, quest: Form_ID, id: i32) -> Form_ID {
	h, ok := formid.alias_handle(quest, u32(id))
	return ws.aliases[h] if ok && id >= 0 else 0
}

// holder_aliases are the quest aliases that hold `form` now.
holder_aliases :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> []gamedb.Quest_Alias {
	holders, ok := ws.alias_holders[form]
	if !ok || db == nil {return nil}
	out := make([dynamic]gamedb.Quest_Alias, 0, len(holders), context.temp_allocator)
	for h in holders {
		quest, id, _ := formid.alias_key(h)
		if a, aok := gamedb.quest_alias(db, quest, id); aok {append(&out, a)}
	}
	return out[:]
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
// forget_scripts drops what a deleted ref's scripts left in the world: registrations, filters and
// saved members. The ref never returns, so nothing needs its OnInit record.
forget_scripts :: proc(ws: ^World_State, form: Form_ID) {
	unregister_updates(ws, form)
	remove_item_filters(ws, form)
	unregister_anim_events(ws, form)
	if vars, ok := ws.script_state[form]; ok {free_script_vars(vars)}
	delete_key(&ws.script_state, form)
}

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
