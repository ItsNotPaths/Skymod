package script

// Dialogue reads: who is talking to the player, a topic info's quest, and who follows the player.

import "../formid"
import "../worldstate"

register_dialogue :: proc(reg: ^Registry) {
	register(reg, "TopicInfo", "GetOwningQuest", n_info_get_owning_quest)
	register(reg, "ObjectReference", "IsInDialogueWithPlayer", n_is_in_dialogue_with_player)
	register(reg, "Actor", "GetDialogueTarget", n_get_dialogue_target)
	register(reg, "Actor", "SetPlayerTeammate", n_set_player_teammate)
	register(reg, "Actor", "IsPlayerTeammate", n_is_player_teammate)
	register(reg, "Actor", "AllowPCDialogue", n_allow_pc_dialogue)
}

n_info_get_owning_quest :: proc(c: ^Call, args: []Value) -> Value {
	return c.db.topics[c.db.infos[c.self].topic].quest
}

n_is_in_dialogue_with_player :: proc(c: ^Call, args: []Value) -> Value {
	return c.self != 0 && c.ws.talking == c.self
}

// GetDialogueTarget: only the player's conversation exists, so the target is the player or None.
n_get_dialogue_target :: proc(c: ^Call, args: []Value) -> Value {
	return c.ws.player if c.self != 0 && c.ws.talking == c.self else Form_ID(0)
}

// (hole teammate-behavior :tags (ai player) :sev gap) a teammate is only a saved flag that dialogue reads, and a summoned or raised actor (worldstate.command) only fights: neither follows, shares crimes or uses the player's commands, and SetNoFavorAllowed has nothing to read it. Leaning (not final): a Follow package the engine applies, so mods can change it; out of combat that is A* with the player as the goal.
// SetPlayerTeammate(abTeammate, abCanDoFavor).
n_set_player_teammate :: proc(c: ^Call, args: []Value) -> Value {
	if arg_bool(args, 0, true) {c.ws.teammates[c.self] = true} else {delete_key(&c.ws.teammates, c.self)}
	return nil
}

n_is_player_teammate :: proc(c: ^Call, args: []Value) -> Value {
	return c.self in c.ws.teammates
}

// AllowPCDialogue(abTalk): false and the actor will not talk to the player.
n_allow_pc_dialogue :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_in_set(&c.ws.no_pc_dialogue, c.self, !arg_bool(args, 0, true))
	return nil
}
