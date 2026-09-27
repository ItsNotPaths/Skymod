package script_lua

// Trigger volumes: a scripted ref with an XPRM box or sphere hears OnTriggerEnter and
// OnTriggerLeave as an actor, the player or a loaded NPC, crosses it. The test is polled each
// tick, not a physics sensor.

import script ".."
import "../../formats/esm"
import "../../formid"
import "../../gamedb"
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
				inside := worldstate.segment_in_primitive(shape, pos, rot, scale, feet, feet + {0, 0, box[1].z - box[0].z})
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
