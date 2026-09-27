package detection

// Detection: each loaded NPC looks at each loaded actor in its range ten times a second, and the
// model (model.odin) turns what it senses into the awareness store (worldstate.awareness). Only the
// app calls in; everything else reads the store.

import smath "../math"
import "../formid"
import "../gamedb"
import "../sight"
import "../worldstate"

Form_ID :: formid.Form_ID

GROUPS :: 6 // viewers take turns: at 60 Hz each looks every 0.1 s

// State is what detection keeps between ticks. Not saved.
State :: struct {
	tick: u64,
	last: map[Form_ID][3]f32, // actor -> where it stood last tick
}

// tick runs one group of viewers. `actors` are the loaded NPCs; the player is a target too.
tick :: proc(s: ^State, ws: ^worldstate.World_State, db: ^gamedb.DB, actors: map[Form_ID]bool, dt: f32) {
	s.tick += 1
	speeds := make(map[Form_ID]f32, context.temp_allocator)
	for a in actors {speeds[a] = speed(s, ws, db, a, dt)}
	speeds[formid.PLAYER] = speed(s, ws, db, formid.PLAYER, dt)
	clear(&s.last)
	for a in speeds {s.last[a] = worldstate.ref_pos(ws, db, a)}

	looked := make(map[[2]Form_ID]bool, context.temp_allocator)
	step := dt * GROUPS
	for viewer in actors {
		if !my_turn(s, viewer) || worldstate.is_dead(ws, viewer) {continue}
		reach := sight.range(ws, db, viewer)
		for target, v in speeds {
			if target == viewer || worldstate.is_dead(ws, target) {continue}
			d := worldstate.ref_distance(ws, db, viewer, target)
			if d > reach {continue}
			senses := Senses {
				sight    = sight.level(ws, db, viewer, target, .Cone),
				distance = d,
				speed    = v,
				sneaking = worldstate.is_sneaking(ws, target),
				light    = sight.light_at(ws, db, worldstate.ref_pos(ws, db, target)),
				noise    = heard(ws, db, viewer, target),
			}
			worldstate.set_awareness(ws, viewer, target, judge(worldstate.awareness(ws, viewer, target), senses, step))
			looked[{viewer, target}] = true
		}
	}
	fading := make([dynamic][2]Form_ID, context.temp_allocator)
	for k in ws.awareness {
		if my_turn(s, k[0]) && k not_in looked {append(&fading, k)}
	}
	for k in fading {
		worldstate.set_awareness(ws, k[0], k[1], judge(worldstate.awareness(ws, k[0], k[1]), {distance = worldstate.FAR_DISTANCE}, step))
	}
}

destroy :: proc(s: ^State) {
	delete(s.last)
}

@(private = "file")
my_turn :: proc(s: ^State, viewer: Form_ID) -> bool {
	return (u64(viewer) + s.tick) % GROUPS == 0
}

@(private = "file")
speed :: proc(s: ^State, ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID, dt: f32) -> f32 {
	was, ok := s.last[actor]
	return ok ? smath.length3(worldstate.ref_pos(ws, db, actor) - was) / dt : 0
}

// (hole noise-events :tags (ai audio) :sev gap) nothing is heard: every target is silent to every viewer.
@(private = "file")
heard :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID) -> f32 {
	return 0
}
