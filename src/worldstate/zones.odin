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
	player_only: bool, // it casts only on the controlled actor
	follow: Form_ID, // it moves with this ref (a cloak); 0: it stays
}

// UNITS_PER_FOOT turns a record's feet into world units: a unit is 0.5625 inches, so 64 are 3 feet.
UNITS_PER_FOOT :: f32(64.0 / 3)

// hazard_zone is the zone a HAZD record makes for `caster`, and the record.
hazard_zone :: proc(db: ^gamedb.DB, hazard, caster: Form_ID) -> (z: Zone, h: esm.Hazard, ok: bool) {
	h = gamedb.hazard_of(db, hazard) or_return
	r := h.radius * UNITS_PER_FOOT
	z = {shape = {half = r, kind = .Sphere}, left = h.lifetime, caster = caster, spell = h.spell, every = h.interval, player_only = h.flags & esm.HAZD_PLAYER_ONLY != 0}
	return z, h, true
}

// effect_hazard makes the hazard of a Spawn Hazard effect (its MGEF's associated item) where its
// target stands, with its caster. A hazard that inherits takes the effect's duration, or its
// entry's area. 0 when the effect names no hazard.
effect_hazard :: proc(ws: ^World_State, db: ^gamedb.DB, effect: Form_ID) -> Form_ID {
	e := ws.effects[effect] or_else {}
	mgef, _ := gamedb.magic_effect_of(db, e.effect)
	z, h, ok := hazard_zone(db, mgef.related, e.caster)
	if !ok {return 0}
	if h.flags & esm.HAZD_INHERIT_DURATION != 0 {z.left = e.duration}
	if items := gamedb.effect_items_of(db, e.spell); h.flags & esm.HAZD_INHERIT_RADIUS != 0 && e.item < len(items) {
		z.shape.half = f32(items[e.item].area) * UNITS_PER_FOOT
	}
	return make_zone(ws, db, mgef.related, e.target, z, int(h.limit))
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
	if z.player_only {return actor == ws.player}
	return z.caster == 0 || hostile(ws, db, z.caster, actor) || hostile(ws, db, actor, z.caster)
}
