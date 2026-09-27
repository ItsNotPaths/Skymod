package worldstate

import "core:math"
import "core:math/linalg"
import "../gamedb"

// Flight is a projectile that can still hit: its created ref (a PROJ base), who shot it, the
// weapon whose enchantment it carries, and the damage it deals. pos is the body origin and vel its
// velocity, as of the last tick. A flight that strikes anything but a live actor is spent: it
// leaves this list and its ref stays as clutter.
Flight :: struct {
	ref, shooter, weapon: Form_ID,
	damage:               f32,
	pos, vel:             [3]f32,
	travelled:            f32,
	launched:             bool, // its body got pos and vel (not saved: a load launches it again)
}

// Hit is an attack that landed, for OnHit: `source` is the weapon or spell, `projectile` the PROJ.
Hit :: struct {
	target, aggressor, source, projectile: Form_ID,
}

// Fire is a Weapon.Fire the app has not resolved yet: the source ref's ProjectileNode is in its model.
Fire :: struct {
	source, weapon, ammo: Form_ID,
}

request_fire :: proc(ws: ^World_State, source, weapon, ammo: Form_ID) {
	append(&ws.fires, Fire{source, weapon, ammo})
}

// launch creates a projectile's ref at pos, pointing along dir, and starts its flight.
launch :: proc(ws: ^World_State, db: ^gamedb.DB, proj, cell: Form_ID, pos, dir: [3]f32, shooter, weapon: Form_ID, damage: f32) {
	p, ok := gamedb.projectile_of(db, proj)
	if !ok {return}
	ref := create_ref(ws, proj, cell, pos, heading_rot(dir), 1)
	mark_scene_dirty(ws, ref)
	append(&ws.projectiles, Flight{ref = ref, shooter = shooter, weapon = weapon, damage = damage, pos = pos, vel = linalg.normalize(dir) * p.speed})
}

// heading_rot is a REFR rotation whose +Y points along dir. smath.trs turns +Y to
// (sin z, cos z cos x, -cos z sin x).
heading_rot :: proc(dir: [3]f32) -> [3]f32 {
	d := linalg.normalize(dir)
	return {math.atan2(-d.z, d.y), 0, math.atan2(d.x, math.sqrt(d.y * d.y + d.z * d.z))}
}
