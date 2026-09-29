package worldstate

import "core:slice"
import "../formats/esm"
import "../gamedb"

// Zone is a volume made at runtime (rt.zone, a hazard): a created ref with a shape. Actors cross it
// as they cross an authored trigger (OnTriggerEnter, OnTriggerLeave). It may cast a spell on the
// actors inside that are hostile to its caster.
Zone :: struct {
	shape:  esm.Primitive,
	left:   f32,     // seconds until it goes; 0: until deleted
	caster: Form_ID, // 0: it casts on every actor
	spell:  Form_ID, // 0: it casts nothing
	every:  f32,     // seconds between casts on one actor inside; 0: once (a rune), then it goes
	burst:  f32,     // a once zone casts on each actor within this of it
}

// make_zone creates a zone of `base` where `at` stands. Past `limit` zones of that base and caster
// (0 = no limit), the oldest go.
make_zone :: proc(ws: ^World_State, db: ^gamedb.DB, base, at: Form_ID, z: Zone, limit := 0) -> Form_ID {
	if limit > 0 {
		same := make([dynamic]Form_ID, context.temp_allocator)
		for id, other in ws.zones {
			if other.caster == z.caster && ref_base(ws, db, id) == base {append(&same, id)}
		}
		slice.sort(same[:]) // created ids grow: the first is the oldest
		for id in same[:max(len(same) - limit + 1, 0)] {set_deleted(ws, id, ref_cell(ws, db, id))}
	}
	id := create_ref(ws, base, ref_cell(ws, db, at), ref_pos(ws, db, at), ref_rot(ws, db, at), 1)
	ws.zones[id] = z
	return id
}

// zone_hits reports whether a zone's spell lands on `actor`.
zone_hits :: proc(ws: ^World_State, db: ^gamedb.DB, z: Zone, actor: Form_ID) -> bool {
	if actor == z.caster || is_dead(ws, db, actor) {return false}
	return z.caster == 0 || hostile(ws, db, z.caster, actor) || hostile(ws, db, actor, z.caster)
}
