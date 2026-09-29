package script_lua

// Trigger volumes: a scripted ref with an XPRM box or sphere, or a zone made at runtime
// (worldstate.Zone), hears OnTriggerEnter and OnTriggerLeave as an actor, the player or a loaded
// NPC, crosses it. The test is polled each tick, not a physics sensor.

import "core:slice"
import script ".."
import "../../formats/esm"
import "../../gamedb"
import smath "../../math"
import "../../worldstate"

// tick_triggers sends OnTriggerEnter / OnTriggerLeave(actor) for each enabled trigger and zone in
// the attached cells that an actor's height went into or out of since the last tick. A trigger that
// detaches or is disabled, or an actor that unloads, is forgotten without an event. Runtime zones
// age wherever they are; they and the placed hazards (PHZD) run in attached cells (run_zone).
tick_triggers :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, dt: f32) {
	actors := make([dynamic]script.Form_ID, context.temp_allocator)
	for actor in ws.ai.loaded {append(&actors, actor)}
	live := make(map[[2]script.Form_ID]bool, context.temp_allocator)
	for _, refs in ws.attached {
		for trig in refs {
			shape, ok := db.triggers[trig]
			if ok && worldstate.ref_enabled(ws, db, trig) {cross(vm, db, ws, trig, shape, actors[:], &live)}
		}
	}
	zones := make([dynamic]script.Form_ID, 0, len(ws.zones), context.temp_allocator)
	for id in ws.zones {append(&zones, id)}
	slice.sort(zones[:])
	for id in zones {
		z := &ws.zones[id]
		if z.left > 0 {
			z.left -= dt
			if z.left <= 0 {
				worldstate.set_deleted(ws, id, worldstate.ref_cell(ws, db, id))
				continue
			}
		}
		run_zone(vm, db, ws, id, z^, actors[:], &live, dt)
	}
	for id in db.placed_hazards {
		if z, _, ok := worldstate.hazard_zone(db, worldstate.ref_base(ws, db, id), 0); ok {
			z.left = 0
			run_zone(vm, db, ws, id, z, actors[:], &live, dt)
		}
	}
	gone := make([dynamic][2]script.Form_ID, context.temp_allocator)
	for key in ws.in_triggers {
		if key not_in live {append(&gone, key)}
	}
	for key in gone {
		delete_key(&ws.in_triggers, key)
		delete_key(&ws.zone_waits, key)
	}
}

// cross sends the enter and leave events of one trigger or zone.
@(private = "file")
cross :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, trig: script.Form_ID, shape: esm.Primitive, actors: []script.Form_ID, live: ^map[[2]script.Form_ID]bool) {
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
			delete_key(&ws.zone_waits, key)
			send(vm, trig, "OnTriggerLeave", actor)
		}
	}
}

// run_zone crosses an enabled zone in an attached cell like a trigger, and its spell hits each
// actor inside that zone_hits allows: on entry, then every `every` seconds. A once zone fires at
// the first such actor, on each within its burst, and goes.
@(private = "file")
run_zone :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, id: script.Form_ID, z: worldstate.Zone, actors: []script.Form_ID, live: ^map[[2]script.Form_ID]bool, dt: f32) {
	if worldstate.is_deleted(ws, id) || !worldstate.ref_enabled(ws, db, id) {return}
	if worldstate.ref_grid_cell(ws, db, id) not_in ws.attached {return}
	cross(vm, db, ws, id, z.shape, actors, live)
	if z.spell == 0 {return}
	c := vm.ctx
	for actor in actors {
		key := [2]script.Form_ID{id, actor}
		if key not_in ws.in_triggers || !worldstate.zone_hits(ws, db, z, actor) {continue}
		if z.every == 0 {
			at := worldstate.ref_pos(ws, db, id)
			for other in actors {
				near := smath.length3(worldstate.ref_pos(ws, db, other) - at) <= z.burst
				if near && worldstate.zone_hits(ws, db, z, other) {script.start_spell(&c, z.spell, other, z.caster)}
			}
			worldstate.set_deleted(ws, id, worldstate.ref_cell(ws, db, id))
			return
		}
		wait := ws.zone_waits[key] - dt
		if wait <= 0 {
			script.start_spell(&c, z.spell, actor, z.caster)
			wait = z.every
		}
		ws.zone_waits[key] = wait
	}
}
