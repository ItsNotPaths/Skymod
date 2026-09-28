package script

// Leveling (worldstate/leveling.odin). The Game verbs act on the player; GetLevel on any actor.

import "../formid"
import "../worldstate"

register_leveling :: proc(reg: ^Registry) {
	register(reg, "Actor", "GetLevel", n_get_level)
	register(reg, "Game", "AdvanceSkill", n_advance_skill)
	register(reg, "Game", "IncrementSkill", n_increment_skill)
	register(reg, "Game", "IncrementSkillBy", n_increment_skill_by)
	register(reg, "Game", "AddPerkPoints", n_add_perk_points)
	for class in ([]string{"Form", "Alias", "ActiveMagicEffect"}) {
		register(reg, class, "RegisterForLevelUp", n_register_level_ups)
		register(reg, class, "UnregisterForLevelUp", n_unregister_level_ups)
	}
}

n_get_level :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.actor_level(c.ws, c.db, c.self)
}

// AdvanceSkill(asSkillName, afMagnitude): skill XP for the player, as using the skill gives.
n_advance_skill :: proc(c: ^Call, args: []Value) -> Value {
	if skill, ok := av_arg(c, args); ok {worldstate.advance_skill(c.ws, c.db, c.ws.player, skill, arg_f32(args, 1, 0))}
	return nil
}

n_increment_skill :: proc(c: ^Call, args: []Value) -> Value {
	if skill, ok := av_arg(c, args); ok {worldstate.raise_skill(c.ws, c.db, c.ws.player, skill, 1)}
	return nil
}

n_increment_skill_by :: proc(c: ^Call, args: []Value) -> Value {
	if skill, ok := av_arg(c, args); ok {worldstate.raise_skill(c.ws, c.db, c.ws.player, skill, arg_i32(args, 1, 1))}
	return nil
}

n_add_perk_points :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.add_perk_points(c.ws, c.ws.player, arg_i32(args, 0, 0))
	return nil
}

// RegisterForLevelUp is ours: the form hears OnLevelUp(akActor, aiLevel, asChoice) after any actor
// levels up. Saved.
n_register_level_ups :: proc(c: ^Call, args: []Value) -> Value {
	c.ws.level_listeners[c.self] = true
	return nil
}

n_unregister_level_ups :: proc(c: ^Call, args: []Value) -> Value {
	delete_key(&c.ws.level_listeners, c.self)
	return nil
}
