package script

import "../gamedb"
import "../worldstate"

register_projectiles :: proc(reg: ^Registry) {
	register(reg, "Weapon", "Fire", n_weapon_fire)
}

// Fire(akSource, akAmmo): the app launches it from the source's ProjectileNode.
n_weapon_fire :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.request_fire(c.ws, arg_form(args, 0), c.self, arg_form(args, 1))
	return nil
}

// projectile_hit is a flight striking a live actor: its damage, the weapon's enchantment, OnHit.
projectile_hit :: proc(c: ^Call, f: worldstate.Flight, target: Form_ID) {
	worldstate.report_crime(c.ws, c.db, f.shooter, target, .Assault, 0)
	damage_health(c, target, f.damage, f.shooter)
	slot, _ := gamedb.equip_slot_of(c.db, f.weapon)
	if e, ok := gamedb.enchantment_of(c.db, slot.enchantment); ok {
		start_effects(c, slot.enchantment, e.effects, false, target, f.shooter)
	}
	append(&c.ws.hits, worldstate.Hit{target, f.shooter, f.weapon, worldstate.ref_base(c.ws, c.db, f.ref)})
	if !worldstate.is_dead(c.ws, target) {append(&c.ws.barks, worldstate.Bark{speaker = target, subtype = worldstate.SUBTYPE_HIT})} // a grunt, dropped while it still says one
}
