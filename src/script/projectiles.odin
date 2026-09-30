package script

import "../gamedb"
import "../worldstate"

register_projectiles :: proc(reg: ^Registry) {
	register(reg, "Weapon", "Fire", n_weapon_fire)
}

// Fire(akSource, akAmmo): the app launches it from the source's ProjectileNode.
n_weapon_fire :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.request_fire(c.ws, arg_form(c, args, 0), c.self, arg_form(c, args, 1))
	return nil
}

// projectile_hit is a flight striking a live actor.
projectile_hit :: proc(c: ^Call, f: worldstate.Flight, target: Form_ID) {
	weapon_hit(c, f.shooter, target, f.weapon, {}, f.damage, worldstate.ref_base(c.ws, c.db, f.ref))
}

// queue_hit queues OnHit for what a flight struck, an actor or any other ref.
queue_hit :: proc(c: ^Call, f: worldstate.Flight, target: Form_ID) {
	append(&c.ws.hits, worldstate.Hit{target, f.shooter, f.weapon, worldstate.ref_base(c.ws, c.db, f.ref), {}})
}
