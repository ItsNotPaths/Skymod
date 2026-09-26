package script

// Quest aliases. A script addresses an alias through its handle (formid.alias_handle); the ref
// filling it lives in worldstate.aliases. A quest fills its aliases when it starts and empties them
// when it stops (CK "Quest Alias Tab"). `self` is the alias handle.

import "../conditions"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

// (hole alias-fills :tags (script quest) :sev polish) Allow Destroyed is not honored (nothing tracks a destroyed ref), and an External fill takes a ref even while it sits in a container, where the CK says it fails.

register_alias :: proc(reg: ^Registry) {
	register(reg, "Quest", "GetAlias", n_quest_get_alias)
	register(reg, "Alias", "GetOwningQuest", n_alias_get_owning_quest)
	register(reg, "Alias", "RegisterForSingleUpdate", n_register_single_update)
	register(reg, "Alias", "RegisterForUpdate", n_register_update)
	register(reg, "Alias", "UnregisterForUpdate", n_unregister_for_update)
	register(reg, "Alias", "RegisterForSingleUpdateGameTime", n_register_single_update_game_time)
	register(reg, "Alias", "RegisterForUpdateGameTime", n_register_update_game_time)
	register(reg, "Alias", "UnregisterForUpdateGameTime", n_unregister_for_update_game_time)
	register(reg, "Alias", "RegisterForAnimationEvent", n_register_anim_event)
	register(reg, "Alias", "UnregisterForAnimationEvent", n_unregister_anim_event)
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

// clear_aliases empties a stopping quest's aliases and stops their update and animation registrations.
clear_aliases :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, quest: Form_ID) {
	for a in gamedb.quest_aliases_of(db, quest) {
		h, ok := formid.alias_handle(quest, a.id)
		if !ok {continue}
		worldstate.clear_alias(ws, h)
		worldstate.unregister_all(ws, h)
	}
}

// objective_targets are the refs filling an objective's target aliases whose conditions pass, in
// QSTA order. Conditions run on the target ref. Temp-allocated.
// (hole quest-markers :tags (ui quest) :sev gap) Nothing draws these yet: no compass or map markers, and TARGET_IGNORES_LOCKS is unread.
objective_targets :: proc(c: ^Call, quest: Form_ID, objective: u16) -> []Form_ID {
	qb, _ := gamedb.quest_baseline_of(c.db, quest)
	ts, ok := qb.objective_targets[objective]
	if !ok {return nil}
	out := make([dynamic]Form_ID, context.temp_allocator)
	for t in ts {
		ref := worldstate.alias_ref(c.ws, quest, t.alias)
		if ref == 0 {continue}
		ctx := condition_context(c, ref, 0, quest)
		if conditions.all(&ctx, t.conditions) {append(&out, ref)}
	}
	return out[:]
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
