package script

// Reads of where a ref is and what it is: position, angle, distance, links, cell, worldspace,
// location, base form and open state. Each reads the overlay over the baseline.

import "core:math"
import "../gamedb"
import smath "../math"
import "../worldstate"
import "../formid"

register_ref_reads :: proc(reg: ^Registry) {
	register(reg, "ObjectReference", "GetPositionX", n_get_position_x)
	register(reg, "ObjectReference", "GetPositionY", n_get_position_y)
	register(reg, "ObjectReference", "GetPositionZ", n_get_position_z)
	register(reg, "ObjectReference", "SetPosition", n_set_position)
	register(reg, "ObjectReference", "GetAngleX", n_get_angle_x)
	register(reg, "ObjectReference", "GetAngleY", n_get_angle_y)
	register(reg, "ObjectReference", "GetAngleZ", n_get_angle_z)
	register(reg, "ObjectReference", "GetDistance", n_get_distance)
	register(reg, "ObjectReference", "GetLinkedRef", n_get_linked_ref)
	register(reg, "ObjectReference", "GetNthLinkedRef", n_get_nth_linked_ref)
	register(reg, "ObjectReference", "GetParentCell", n_get_parent_cell)
	register(reg, "ObjectReference", "GetWorldSpace", n_get_world_space)
	register(reg, "ObjectReference", "GetCurrentLocation", n_get_current_location)
	register(reg, "Location", "IsLoaded", n_location_is_loaded)
	register(reg, "ObjectReference", "GetBaseObject", n_get_base_object)
	register(reg, "Actor", "GetActorBase", n_get_base_object)
	register(reg, "ObjectReference", "GetOpenState", n_get_open_state)
	register(reg, "Cell", "IsAttached", n_cell_is_attached)
}

n_get_position_x :: proc(c: ^Call, args: []Value) -> Value {return ref_pos(c, c.self).x}
n_get_position_y :: proc(c: ^Call, args: []Value) -> Value {return ref_pos(c, c.self).y}
n_get_position_z :: proc(c: ^Call, args: []Value) -> Value {return ref_pos(c, c.self).z}

n_set_position :: proc(c: ^Call, args: []Value) -> Value {
	pos := smath.Vec3{arg_f32(args, 0, 0), arg_f32(args, 1, 0), arg_f32(args, 2, 0)}
	worldstate.set_moved(c.ws, c.self, ref_cell(c, c.self), smath.translate(pos), pos)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

// (hole set-angle :tags script :sev gap) SetAngle is a stub, so GetAngle* reads the placement's angles; the player's read 0.
n_get_angle_x :: proc(c: ^Call, args: []Value) -> Value {return math.to_degrees(ref_rot(c, c.self).x)}
n_get_angle_y :: proc(c: ^Call, args: []Value) -> Value {return math.to_degrees(ref_rot(c, c.self).y)}
n_get_angle_z :: proc(c: ^Call, args: []Value) -> Value {return math.to_degrees(ref_rot(c, c.self).z)}

n_get_distance :: proc(c: ^Call, args: []Value) -> Value {
	other := arg_form(args, 0)
	space := ref_space(c, c.self)
	if space == 0 || space != ref_space(c, other) {return FAR_DISTANCE}
	return smath.length3(ref_pos(c, c.self) - ref_pos(c, other))
}

// n_get_linked_ref follows the link on the keyword's channel; no keyword is the default link.
n_get_linked_ref :: proc(c: ^Call, args: []Value) -> Value {
	ref, _ := gamedb.linked_ref(c.db, c.self, arg_form(args, 0))
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
	cell, ok := gamedb.cell_by_formid(c.db, ref_grid_cell(c, c.self))
	if !ok || (!cell.interior && cell.form_id not_in c.ws.attached) {return nil}
	return cell.form_id
}

n_get_world_space :: proc(c: ^Call, args: []Value) -> Value {
	cell, _ := gamedb.cell_by_formid(c.db, ref_cell(c, c.self))
	return form_or_none(cell.world_form_id)
}

// n_get_current_location is the cell's location, else its worldspace's.
n_get_current_location :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(ref_location(c, c.self))
}

ref_location :: proc(c: ^Call, form: Form_ID) -> Form_ID {
	return cell_location(c.db, ref_grid_cell(c, form))
}

// cell_location is a cell's XLCN location, else its worldspace's; 0 when it has neither.
cell_location :: proc(db: ^gamedb.DB, cell_id: Form_ID) -> Form_ID {
	cell, ok := gamedb.cell_by_formid(db, cell_id)
	if !ok {return 0}
	if cell.location != 0 {return cell.location}
	return db.world_location[cell.world_form_id]
}

// location_loaded: an attached cell is in `location` or in a child of it. Reads the attached set
// only; loads nothing.
location_loaded :: proc(c: ^Call, location: Form_ID) -> bool {
	if location == 0 {return false}
	for cell in c.ws.attached {
		l := cell_location(c.db, cell)
		if l == location || gamedb.location_is_child(c.db, l, location) {return true}
	}
	return false
}

n_location_is_loaded :: proc(c: ^Call, args: []Value) -> Value {
	return location_loaded(c, c.self)
}

n_get_base_object :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(ref_base(c, c.self))
}

// n_get_open_state answers 1 (open) or 3 (closed) for a door or a ref SetOpen touched, else 0 (none).
// (hole door-default-open :tags world :sev gap) a door's authored open-by-default flag is not decoded; an untouched door reads closed.
n_get_open_state :: proc(c: ^Call, args: []Value) -> Value {
	if d, ok := worldstate.get(c.ws, c.self); ok && .Open in d.live {
		return i32(1) if d.open else i32(3)
	}
	if gamedb.is_door(c.db, ref_base(c, c.self)) {return i32(3)}
	return i32(0)
}

n_cell_is_attached :: proc(c: ^Call, args: []Value) -> Value {
	return c.self in c.ws.attached
}

// ref_base is a placed or created ref's base form; 0 when it is neither.
ref_base :: proc(c: ^Call, form: Form_ID) -> Form_ID {
	if r, ok := gamedb.ref_by_formid(c.db, form); ok {return r.base}
	if cr, ok := worldstate.get_created(c.ws, form); ok {return cr.base}
	return 0
}

// ref_rot is a placed or created ref's rotation, XYZ euler radians.
@(private)
ref_rot :: proc(c: ^Call, form: Form_ID) -> [3]f32 {
	if form == formid.PLAYER {return {}}
	if r, ok := gamedb.ref_by_formid(c.db, form); ok {return r.rot}
	if cr, ok := worldstate.get_created(c.ws, form); ok {return cr.rot}
	return {}
}

// ref_grid_cell is the cell under a ref, with a worldspace-persistent ref resolved to its grid cell.
ref_grid_cell :: proc(c: ^Call, form: Form_ID) -> Form_ID {
	return gamedb.grid_cell(c.db, ref_cell(c, form), ref_pos(c, form))
}

// ref_space is the interior cell or the worldspace a ref is in; 0 when it has no cell.
@(private)
ref_space :: proc(c: ^Call, form: Form_ID) -> Form_ID {
	cell, ok := gamedb.cell_by_formid(c.db, ref_cell(c, form))
	if !ok {return 0}
	return cell.form_id if cell.interior else cell.world_form_id
}

// form_or_none turns an absent form (0) into None.
form_or_none :: proc(form: Form_ID) -> Value {
	if form == 0 {return nil}
	return form
}
