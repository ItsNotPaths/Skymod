package script

// Quest aliases. A script addresses an alias through its handle (formid.alias_handle); the ref
// filling it lives in worldstate.aliases. A quest fills its aliases when it starts and empties them
// when it stops (CK "Quest Alias Tab"). `self` is the alias handle.

import "../formid"
import "../gamedb"
import "../worldstate"

// HOLE(script, gap): only Forced, Unique_Actor and External fills resolve; Matching_Ref, From_Event, Create_Ref and From_List aliases stay empty until conditions, the story manager and PlaceAtMe exist.
// HOLE(script, gap): location aliases never fill; the ALFL/ALFA location fills are not decoded.

register_alias :: proc(reg: ^Registry) {
	register(reg, "Quest", "GetAlias", n_quest_get_alias)
	register(reg, "Alias", "GetOwningQuest", n_alias_get_owning_quest)
	register(reg, "Alias", "RegisterForSingleUpdate", n_register_single_update)
	register(reg, "Alias", "RegisterForUpdate", n_register_update)
	register(reg, "Alias", "UnregisterForUpdate", n_unregister_for_update)
	register(reg, "ReferenceAlias", "GetReference", n_alias_get)
	register(reg, "ReferenceAlias", "ForceRefTo", n_alias_force)
	register(reg, "ReferenceAlias", "Clear", n_alias_clear)
	register(reg, "ReferenceAlias", "AddInventoryEventFilter", n_add_inventory_event_filter)
	register(reg, "ReferenceAlias", "RemoveInventoryEventFilter", n_remove_inventory_event_filter)
	register(reg, "ReferenceAlias", "RemoveAllInventoryEventFilters", n_remove_all_inventory_event_filters)
	register(reg, "LocationAlias", "GetLocation", n_alias_get)
	register(reg, "LocationAlias", "ForceLocationTo", n_alias_force)
	register(reg, "LocationAlias", "Clear", n_alias_clear)
}

// fill_aliases fills a starting quest's aliases in declaration order, so an External fill can read
// one filled above it.
fill_aliases :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, quest: Form_ID) {
	for a in gamedb.quest_aliases_of(db, quest) {
		h, ok := formid.alias_handle(quest, a.id)
		if !ok {continue}
		form: Form_ID
		#partial switch a.fill {
		case .Forced:
			form = a.target
		case .Unique_Actor:
			form, _ = gamedb.unique_actor_ref(db, a.target)
		case .External:
			if other, hok := formid.alias_handle(a.target, a.extra); hok {form = ws.aliases[other]}
		}
		worldstate.fill_alias(ws, h, form)
	}
}

// clear_aliases empties a stopping quest's aliases and stops their update registrations.
clear_aliases :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, quest: Form_ID) {
	for a in gamedb.quest_aliases_of(db, quest) {
		h, ok := formid.alias_handle(quest, a.id)
		if !ok {continue}
		worldstate.clear_alias(ws, h)
		worldstate.unregister_updates(ws, h)
	}
}

// Quest.GetAlias(aiAliasID) -> Alias.
n_quest_get_alias :: proc(c: ^Call, args: []Value) -> Value {
	id := u32(arg_i32(args, 0, 0))
	if _, ok := gamedb.quest_alias(c.db, c.self, id); !ok {return Form_ID(0)}
	h, _ := formid.alias_handle(c.self, id)
	return h
}

n_alias_get_owning_quest :: proc(c: ^Call, args: []Value) -> Value {
	quest, _, _ := formid.alias_key(c.self)
	return quest
}

n_alias_get :: proc(c: ^Call, args: []Value) -> Value {
	return c.ws.aliases[c.self]
}

n_alias_force :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.fill_alias(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_alias_clear :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.clear_alias(c.ws, c.self)
	return nil
}
