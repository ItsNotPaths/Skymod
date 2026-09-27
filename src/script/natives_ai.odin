package script

// What scripts ask of the AI (worldstate.AI_Link): package selection, placement, paths, holds.
// The AI answers at its next tick.

import "../worldstate"

// (hole ai-combat-natives :tags (ai combat) :sev gap :needs combat-damage) StartCombat, StopCombat, IsInCombat and GetCombatTarget are stubs: the stand-in combat toward the player is not reachable from scripts.
// (hole look-at :tags (ai animation unclaimed) :sev gap :needs animation) SetLookAt and ClearLookAt are stubs: no head tracking.
register_ai :: proc(reg: ^Registry) {
	register(reg, "Actor", "EvaluatePackage", n_evaluate_package)
	register(reg, "Actor", "GetCurrentPackage", n_get_current_package)
	register(reg, "Actor", "MoveToPackageLocation", n_move_to_package_location)
	register(reg, "Actor", "PathToReference", n_path_to_reference)
	register(reg, "Actor", "PathTo", n_path_to)
	register(reg, "Actor", "IsPathingTo", n_is_pathing_to)
	register(reg, "Actor", "SetDontMove", n_set_dont_move)
	register(reg, "Actor", "SetRestrained", n_set_restrained)
	register(reg, "Actor", "KeepOffsetFromActor", n_keep_offset_from_actor)
	register(reg, "Actor", "ClearKeepOffsetFromActor", n_clear_keep_offset_from_actor)
}

n_evaluate_package :: proc(c: ^Call, args: []Value) -> Value {
	c.ws.ai.evaluate[c.self] = true
	return nil
}

n_get_current_package :: proc(c: ^Call, args: []Value) -> Value {
	if pack := c.ws.ai.packages[c.self]; pack != 0 {return pack}
	return nil
}

n_move_to_package_location :: proc(c: ^Call, args: []Value) -> Value {
	c.ws.ai.to_package[c.self] = true
	return nil
}

// PathTo(to, speed) starts a walk to `to` and returns; IsPathingTo(to) is its guard (script-api.md).
n_path_to :: proc(c: ^Call, args: []Value) -> Value {
	to := arg_form(args, 0)
	if to == 0 {return false}
	c.ws.ai.paths[c.self] = {to, arg_f32(args, 1, 0.5)}
	return true
}

n_is_pathing_to :: proc(c: ^Call, args: []Value) -> Value {
	o, ok := c.ws.ai.paths[c.self]
	return ok && o.to == arg_form(args, 0)
}

// PathToReference never blocks (script-api.md): it is PathTo, and reports the order taken.
n_path_to_reference :: proc(c: ^Call, args: []Value) -> Value {
	return n_path_to(c, args)
}

n_set_dont_move :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_dont_move(c.ws, c.self, arg_bool(args, 0, true))
	return nil
}

n_set_restrained :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_restrained(c.ws, c.self, arg_bool(args, 0, true))
	return nil
}

// KeepOffsetFromActor(akTarget, afOffsetX, Y, Z, afOffsetAngleX, Y, Z, afCatchUpRadius = 20,
// afFollowRadius = 5): the actor holds a place beside the target until cleared. Only the Z angle turns it.
n_keep_offset_from_actor :: proc(c: ^Call, args: []Value) -> Value {
	target := arg_form(args, 0)
	if target == 0 {return nil}
	c.ws.ai.offsets[c.self] = {
		target   = target,
		offset   = {arg_f32(args, 1, 0), arg_f32(args, 2, 0), arg_f32(args, 3, 0)},
		angle    = arg_f32(args, 6, 0),
		catch_up = arg_f32(args, 7, 20),
		follow   = arg_f32(args, 8, 5),
	}
	return nil
}

n_clear_keep_offset_from_actor :: proc(c: ^Call, args: []Value) -> Value {
	delete_key(&c.ws.ai.offsets, c.self)
	return nil
}
