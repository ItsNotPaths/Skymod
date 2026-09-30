package script

// The host side of the combat seam's damage (src/combat).

import "core:math/rand"
import "../combat"
import "../gamedb"
import "../plugin"
import "../worldhost"
import "../worldstate"

combat_table := combat.BUILTIN // the built-in brain and damage, or a plugin's

// (hole combat-hit-spells :tags (combat magic) :sev gap) no perk casts on a hit: Apply_Combat_Hit_Spell (57 SE entries), Apply_Bashing_Spell (4) and Apply_Weapon_Swing_Spell (1) pick a spell (Select_Spell); translated, each is a hit hook that calls ApplyEffect.
// weapon_hit is a weapon hit landing on a live actor, melee or ranged (`projectile` its PROJ): an
// assault unless a friend lets it go, the damage (a sneak attack when the target had not detected the attacker), the weapon's
// enchantment, OnHit, a noise and the target's grunt.
weapon_hit :: proc(c: ^Call, attacker, target, weapon: Form_ID, kind: combat.Attack_Kind, base: f32, projectile: Form_ID = 0) {
	forgiven := worldstate.friend_hit(c.ws, c.db, target, attacker)
	if !forgiven {worldstate.report_crime(c.ws, c.db, attacker, target, .Assault, 0)}
	kind := kind
	if !worldstate.awareness(c.ws, target, attacker).detected {kind += {.Sneak}}
	land_attack(c, attacker, target, weapon, kind, base, projectile != 0)
	slot, _ := gamedb.equip_slot_of(c.db, weapon)
	if e, ok := gamedb.enchantment_of(c.db, slot.enchantment); ok {
		start_effects(c, slot.enchantment, e.effects, false, target, attacker)
	}
	append(&c.ws.hits, worldstate.Hit{target, attacker, weapon, projectile, kind})
	if !forgiven {worldstate.strike(c.ws, target, attacker)}
	worldstate.make_noise(c.ws, c.db, attacker, target, worldstate.sound_level(c.db, .Normal))
	if !worldstate.is_dead(c.ws, c.db, target) {append(&c.ws.barks, worldstate.Bark{speaker = target, to = attacker, subtype = worldstate.SUBTYPE_HIT})} // a grunt, dropped while it still says one
}

// land_attack is everything a landed weapon hit does to its target. The meleehit or archhit hooks
// (perks, as Lua) fill its parts or stop it, the armorhit hooks each worn piece's rating, then the
// combat seam's damage composes them.
land_attack :: proc(c: ^Call, attacker, target, weapon: Form_ID, kind: combat.Attack_Kind, base: f32, ranged: bool) {
	a := combat.attack(attacker, target, weapon, kind)
	a.roll = rand.float32()
	h := c.ws.hooks
	if h.weapon_hit != nil && !h.weapon_hit(h.data, &a, ranged) {return}
	a.armor = plugin.span(worn_armor(c, target))
	wd := worldhost.Data{context, c.ws, c.db}
	w := worldhost.world(&wd)
	damage_health(c, target, combat_table.damage(&w, a, base), attacker)
}

// worn_armor is the armor `wearer` has on, each piece's rating through the armorhit hooks.
@(private = "file")
worn_armor :: proc(c: ^Call, wearer: Form_ID) -> []combat.Piece {
	out := make([dynamic]combat.Piece, context.temp_allocator)
	h := c.ws.hooks
	for w in worldstate.equipment(c.ws, c.db, wearer).worn {
		slot, _ := gamedb.equip_slot_of(c.db, w.item)
		if slot.kind != .Armor {continue}
		p := combat.Piece{w.item, combat.KEEP}
		if h.armor_hit != nil {h.armor_hit(h.data, wearer, w.item, &p.rating)}
		append(&out, p)
	}
	return out[:]
}
