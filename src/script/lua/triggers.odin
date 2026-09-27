package script_lua

// Trigger volumes: a scripted ref with an XPRM box or sphere hears OnTriggerEnter and
// OnTriggerLeave as an actor, the player or a loaded NPC, crosses it. The test is polled each
// tick, not a physics sensor.

import script ".."
import "../../formats/esm"
import "../../formid"
import "../../gamedb"
import smath "../../math"
import "../../worldstate"

// tick_triggers sends OnTriggerEnter / OnTriggerLeave(actor) for each enabled trigger in the
// attached cells that an actor's height went into or out of since the last tick. A trigger that
// detaches or is disabled, or an actor that unloads, is forgotten without an event.
tick_triggers :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State) {
	actors := make([dynamic]script.Form_ID, context.temp_allocator)
	append(&actors, formid.PLAYER)
	for actor in ws.ai.loaded {append(&actors, actor)}
	live := make(map[[2]script.Form_ID]bool, context.temp_allocator)
	for _, refs in ws.attached {
		for trig in refs {
			shape, ok := db.triggers[trig]
			if !ok || !worldstate.ref_enabled(ws, db, trig) {continue}
			pos, rot, scale := worldstate.ref_pos(ws, db, trig), worldstate.ref_rot(ws, db, trig), worldstate.ref_scale(ws, db, trig)
			for actor in actors {
				key := [2]script.Form_ID{trig, actor}
				live[key] = true
				feet := worldstate.ref_pos(ws, db, actor)
				box := worldstate.actor_box(ws, db, actor)
				inside := segment_in(shape, pos, rot, scale, feet, feet + {0, 0, box[1].z - box[0].z})
				if inside == (key in ws.in_triggers) {continue}
				if inside {
					ws.in_triggers[key] = true
					send(vm, trig, "OnTriggerEnter", actor)
				} else {
					delete_key(&ws.in_triggers, key)
					send(vm, trig, "OnTriggerLeave", actor)
				}
			}
		}
	}
	gone := make([dynamic][2]script.Form_ID, context.temp_allocator)
	for key in ws.in_triggers {
		if key not_in live {append(&gone, key)}
	}
	for key in gone {delete_key(&ws.in_triggers, key)}
}

// segment_in reports whether the segment a..b touches a primitive placed at pos/rot/scale.
@(private = "file")
segment_in :: proc(shape: esm.Primitive, pos, rot: smath.Vec3, scale: f32, a, b: smath.Vec3) -> bool {
	to_local := smath.rotate_z(rot.z) * smath.rotate_y(rot.y) * smath.rotate_x(rot.x) // the inverse of trs's rotation
	local :: proc(m: smath.Mat4, v: smath.Vec3) -> smath.Vec3 {return (m * [4]f32{v.x, v.y, v.z, 0}).xyz}
	la, lb := local(to_local, (a - pos) / scale), local(to_local, (b - pos) / scale)
	if shape.kind == .Sphere {
		d := lb - la
		t := clamp(smath.dot3(-la, d) / max(smath.dot3(d, d), 1e-6), 0, 1)
		return smath.length3(la + d * t) <= shape.half.x
	}
	// Slab clip of the segment against the box.
	t0, t1: f32 = 0, 1
	for i in 0 ..< 3 {
		d := lb[i] - la[i]
		if abs(d) < 1e-6 {
			if abs(la[i]) > shape.half[i] {return false}
			continue
		}
		u, v := (-shape.half[i] - la[i]) / d, (shape.half[i] - la[i]) / d
		t0, t1 = max(t0, min(u, v)), min(t1, max(u, v))
		if t0 > t1 {return false}
	}
	return true
}
