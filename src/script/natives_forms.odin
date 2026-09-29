package script

// Reads over base-form data: keywords, race, form lists, the location tree and its keyword data,
// and the game time.

import "../gamedb"
import "../worldstate"
import "../formid"

register_forms :: proc(reg: ^Registry) {
	register(reg, "Form", "HasKeyword", n_has_keyword)
	register(reg, "Form", "HasTag", n_has_tag)
	register(reg, "Actor", "GetRace", n_actor_get_race)
	register(reg, "ActorBase", "GetRace", n_actor_base_get_race)

	register(reg, "FormList", "GetSize", n_list_get_size)
	register(reg, "FormList", "GetAt", n_list_get_at)
	register(reg, "FormList", "HasForm", n_list_has_form)
	register(reg, "FormList", "AddForm", n_list_add_form)
	register(reg, "FormList", "RemoveAddedForm", n_list_remove_added_form)
	register(reg, "FormList", "Revert", n_list_revert)

	register(reg, "Location", "IsChild", n_location_is_child)
	register(reg, "Location", "GetKeywordData", n_location_get_keyword_data)
	register(reg, "Location", "SetKeywordData", n_location_set_keyword_data)

	register(reg, "Utility", "GetCurrentGameTime", n_get_current_game_time)
}

n_has_keyword :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.has_keyword(c.ws, c.db, c.self, arg_form(c, args, 0))
}

// HasTag(asPattern) is not Papyrus: a tag of the form matches (worldstate.has_tag).
n_has_tag :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.has_tag(c.ws, c.db, c.self, arg_str(args, 0))
}

n_actor_get_race :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(worldstate.actor_traits(c.ws, c.db, c.self).race)
}

n_actor_base_get_race :: proc(c: ^Call, args: []Value) -> Value {
	base, _ := gamedb.actor_base(c.db, c.self)
	return form_or_none(base.race)
}

// A form list is its authored members, then the forms scripts added.

n_list_get_size :: proc(c: ^Call, args: []Value) -> Value {
	authored, _ := gamedb.form_list_of(c.db, c.self)
	return i32(len(authored) + len(worldstate.list_added(c.ws, c.self)))
}

n_list_get_at :: proc(c: ^Call, args: []Value) -> Value {
	authored, _ := gamedb.form_list_of(c.db, c.self)
	added := worldstate.list_added(c.ws, c.self)
	i := int(arg_i32(args, 0, 0))
	switch {
	case i < 0:
		return nil
	case i < len(authored):
		return authored[i]
	case i - len(authored) < len(added):
		return added[i - len(authored)]
	}
	return nil
}

n_list_has_form :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.list_has(c.ws, c.db, c.self, arg_form(c, args, 0))
}

n_list_add_form :: proc(c: ^Call, args: []Value) -> Value {
	if form := arg_form(c, args, 0); form != 0 {worldstate.add_to_list(c.ws, c.self, form)}
	return nil
}

n_list_remove_added_form :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.remove_from_list(c.ws, c.self, arg_form(c, args, 0))
	return nil
}

n_list_revert :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.revert_list(c.ws, c.self)
	return nil
}

n_location_is_child :: proc(c: ^Call, args: []Value) -> Value {
	return gamedb.location_is_child(c.db, c.self, arg_form(c, args, 0))
}

n_location_get_keyword_data :: proc(c: ^Call, args: []Value) -> Value {
	return c.ws.keyword_data[{c.self, arg_form(c, args, 0)}]
}

n_location_set_keyword_data :: proc(c: ^Call, args: []Value) -> Value {
	c.ws.keyword_data[{c.self, arg_form(c, args, 0)}] = arg_f32(args, 1, 0)
	return nil
}

n_get_current_game_time :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.global_value(c.ws, c.db, formid.GAME_DAYS_PASSED)
}
