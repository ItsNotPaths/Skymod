package script

// Reads of where a ref is and what it is: position, angle, distance, links, cell, worldspace,
// location, base form and open state. Each reads the overlay over the baseline.

import "core:math"
import "../gamedb"
import "../sighthost"
import smath "../math"
import "../worldstate"

register_ref_reads :: proc(reg: ^Registry) {
	register(reg, "ObjectReference", "GetTriggerObjectCount", n_get_trigger_object_count)
	register(reg, "ObjectReference", "GetPositionX", n_get_position_x)
	register(reg, "ObjectReference", "GetPositionY", n_get_position_y)
	register(reg, "ObjectReference", "GetPositionZ", n_get_position_z)
	register(reg, "ObjectReference", "SetPosition", n_set_position)
	register(reg, "ObjectReference", "SetAngle", n_set_angle)
	register(reg, "ObjectReference", "GetAngleX", n_get_angle_x)
	register(reg, "ObjectReference", "GetAngleY", n_get_angle_y)
	register(reg, "ObjectReference", "GetAngleZ", n_get_angle_z)
	register(reg, "ObjectReference", "GetDistance", n_get_distance)
	register(reg, "Actor", "HasLOS", n_has_los)
	register(reg, "Actor", "GetSightLevel", n_get_sight_level)
	register(reg, "Actor", "IsDetectedBy", n_is_detected_by)
	register(reg, "ObjectReference", "GetLinkedRef", n_get_linked_ref)
	register(reg, "ObjectReference", "GetNthLinkedRef", n_get_nth_linked_ref)
	register(reg, "ObjectReference", "GetParentCell", n_get_parent_cell)
	register(reg, "ObjectReference", "GetWorldSpace", n_get_world_space)
	register(reg, "ObjectReference", "GetCurrentLocation", n_get_current_location)
	register(reg, "Location", "IsLoaded", n_location_is_loaded)
	register(reg, "ObjectReference", "GetBaseObject", n_get_base_object)
	register(reg, "Actor", "GetActorBase", n_get_base_object)
	register(reg, "Actor", "GetLeveledActorBase", n_get_leveled_actor_base)
	register(reg, "ObjectReference", "GetOpenState", n_get_open_state)
	register(reg, "Cell", "IsAttached", n_cell_is_attached)
}

n_get_position_x :: proc(c: ^Call, args: []Value) -> Value {return worldstate.ref_pos(c.ws, c.db, c.self).x}
n_get_position_y :: proc(c: ^Call, args: []Value) -> Value {return worldstate.ref_pos(c.ws, c.db, c.self).y}
n_get_position_z :: proc(c: ^Call, args: []Value) -> Value {return worldstate.ref_pos(c.ws, c.db, c.self).z}

n_set_position :: proc(c: ^Call, args: []Value) -> Value {
	place(c, c.self, {arg_f32(args, 0, 0), arg_f32(args, 1, 0), arg_f32(args, 2, 0)}, worldstate.ref_rot(c.ws, c.db, c.self))
	return nil
}

// SetAngle(afXAngle, afYAngle, afZAngle), degrees.
n_set_angle :: proc(c: ^Call, args: []Value) -> Value {
	rot := [3]f32{arg_f32(args, 0, 0), arg_f32(args, 1, 0), arg_f32(args, 2, 0)} * math.RAD_PER_DEG
	place(c, c.self, worldstate.ref_pos(c.ws, c.db, c.self), rot)
	return nil
}

n_get_angle_x :: proc(c: ^Call, args: []Value) -> Value {return math.to_degrees(worldstate.ref_rot(c.ws, c.db, c.self).x)}
n_get_angle_y :: proc(c: ^Call, args: []Value) -> Value {return math.to_degrees(worldstate.ref_rot(c.ws, c.db, c.self).y)}
n_get_angle_z :: proc(c: ^Call, args: []Value) -> Value {return math.to_degrees(worldstate.ref_rot(c.ws, c.db, c.self).z)}

n_get_distance :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.ref_distance(c.ws, c.db, c.self, arg_form(c, args, 0))
}

n_has_los :: proc(c: ^Call, args: []Value) -> Value {
	return sighthost.has_los(c.ws, c.db, c.self, arg_form(c, args, 0))
}

// n_get_sight_level is ours, not Papyrus: Actor.GetSightLevel(akTarget, aiMode) is how much this
// actor sees of the target, 0..1; mode 0 Raw (rays only), 1 Cone (in view and range), 2 Detect
// (awareness).
n_get_sight_level :: proc(c: ^Call, args: []Value) -> Value {
	mode := arg_i32(args, 1, 0)
	if mode < 0 || mode > i32(max(sighthost.Mode)) {return f32(0)}
	return sighthost.level(c.ws, c.db, c.self, arg_form(c, args, 0), sighthost.Mode(mode))
}

n_is_detected_by :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.detected(c.ws, arg_form(c, args, 0), c.self)
}

// n_get_linked_ref follows the link on the keyword's channel; no keyword is the default link.
n_get_linked_ref :: proc(c: ^Call, args: []Value) -> Value {
	ref, _ := gamedb.linked_ref(c.db, c.self, arg_form(c, args, 0))
	return form_or_none(ref)
}

// n_get_nth_linked_ref follows the default link n times: 1 is GetLinkedRef().
n_get_nth_linked_ref :: proc(c: ^Call, args: []Value) -> Value {
	ref := c.self
	for _ in 0 ..< arg_i32(args, 0, 0) {
		ref, _ = gamedb.linked_ref(c.db, ref)
		if ref == 0 {break}
	}
	return form_or_none(ref)
}

// n_get_parent_cell reads None for an exterior cell that is not attached, as Papyrus does.
n_get_parent_cell :: proc(c: ^Call, args: []Value) -> Value {
	cell, ok := gamedb.cell_by_formid(c.db, worldstate.ref_grid_cell(c.ws, c.db, c.self))
	if !ok || (!cell.interior && cell.form_id not_in c.ws.attached) {return nil}
	return cell.form_id
}

n_get_world_space :: proc(c: ^Call, args: []Value) -> Value {
	cell, _ := gamedb.cell_by_formid(c.db, worldstate.ref_cell(c.ws, c.db, c.self))
	return form_or_none(cell.world_form_id)
}

// n_get_current_location is the cell's location, else its worldspace's.
n_get_current_location :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(worldstate.ref_location(c.ws, c.db, c.self))
}


// location_loaded: an attached cell is in `location` or in a child of it. Reads the attached set
// only; loads nothing.
location_loaded :: proc(c: ^Call, location: Form_ID) -> bool {
	if location == 0 {return false}
	for cell in c.ws.attached {
		if gamedb.location_within(c.db, gamedb.cell_location(c.db, cell), location) {return true}
	}
	return false
}

n_location_is_loaded :: proc(c: ^Call, args: []Value) -> Value {
	return location_loaded(c, c.self)
}

n_get_base_object :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(worldstate.ref_base(c.ws, c.db, c.self))
}

// GetLeveledActorBase is the NPC_ a leveled actor rolled; any other actor answers its base.
n_get_leveled_actor_base :: proc(c: ^Call, args: []Value) -> Value {
	if pick := worldstate.actor_pick(c.ws, c.db, c.self); pick != 0 {return pick}
	return form_or_none(worldstate.ref_base(c.ws, c.db, c.self))
}

n_get_open_state :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.open_state(c.ws, c.db, c.self)
}

n_cell_is_attached :: proc(c: ^Call, args: []Value) -> Value {
	return c.self in c.ws.attached
}





// form_or_none turns an absent form (0) into None.
form_or_none :: proc(form: Form_ID) -> Value {
	if form == 0 {return nil}
	return form
}

// GetTriggerObjectCount() -> int: how many actors are inside this trigger volume (script tick_triggers).
n_get_trigger_object_count :: proc(c: ^Call, args: []Value) -> Value {
	n: i32
	for key in c.ws.in_triggers {
		if key[0] == c.self {n += 1}
	}
	return n
}
