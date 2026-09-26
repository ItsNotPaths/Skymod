package script

// Dialogue reads: who is talking to the player, and a topic info's quest.

import "../formid"

register_dialogue :: proc(reg: ^Registry) {
	register(reg, "TopicInfo", "GetOwningQuest", n_info_get_owning_quest)
	register(reg, "ObjectReference", "IsInDialogueWithPlayer", n_is_in_dialogue_with_player)
	register(reg, "Actor", "GetDialogueTarget", n_get_dialogue_target)
}

n_info_get_owning_quest :: proc(c: ^Call, args: []Value) -> Value {
	return c.db.topics[c.db.infos[c.self].topic].quest
}

n_is_in_dialogue_with_player :: proc(c: ^Call, args: []Value) -> Value {
	return c.self != 0 && c.ws.talking == c.self
}

// GetDialogueTarget: only the player's conversation exists, so the target is the player or None.
n_get_dialogue_target :: proc(c: ^Call, args: []Value) -> Value {
	return formid.PLAYER if c.self != 0 && c.ws.talking == c.self else Form_ID(0)
}
