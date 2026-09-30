package main

import "core:math"
import "../combat"
import "../gamedb"
import "../physics"
import "../script"
import "../worldstate"

// (hole swing-cone :tags combat :sev polish) unsourced: how wide a swing reaches; it tests rays across SWING_CONE either side of the facing, at chest height.
SWING_CONE :: f32(math.PI / 6)
SWING_RAYS :: 5

// tick_swings lands the swings brains and the player asked for: the first live actor a ray from the
// attacker's chest meets inside its reach, the hand's WEAP reach x fCombatDistance (fists 1x).
tick_swings :: proc(g: ^Game) {
	defer clear(&g.sim.ws.swings)
	sp := active_space(g)
	if sp == nil || sp.phys == nil {return}
	c := script.Call{ws = &g.sim.ws, db = &g.db}
	for s in g.sim.ws.swings {
		weapon := worldstate.in_slot(c.ws, c.db, s.attacker, s.hand)
		slot, _ := gamedb.equip_slot_of(c.db, weapon)
		if slot.kind != .Weapon {weapon, slot = 0, {}}
		if cost := swing_stamina(c.db, s, weapon); cost > 0 {worldstate.av_damage(c.ws, c.db, s.attacker, "Stamina", cost)}
		reach := (slot.gear.reach if slot.gear.reach > 0 else 1) * gamedb.setting_float(c.db, "fCombatDistance", 141)
		switch target := swing_target(g, sp.phys, s.attacker, reach); {
		case live_actor(g, target): script.weapon_hit(&c, s.attacker, target, weapon, s.kind, slot.damage)
		case target != 0:           worldstate.damage_object(c.ws, c.db, target, slot.damage, true)
		}
	}
}

// (hole attack-stamina-rules :tags combat :sev polish) unsourced: a power attack costs (fStaminaAttackWeaponBase 20 + weight x fStaminaAttackWeaponMult 1) x fPowerAttackStaminaPenalty 2 (UESP: power attacks cost stamina, normal ones none), and whether a power bash adds fStaminaBashBase.
// swing_stamina is what a swing costs: nothing for a normal one; a power attack by its weapon's
// weight; a bash fStaminaBashBase 35, a power bash fStaminaPowerBashBase 55.
@(private = "file")
swing_stamina :: proc(db: ^gamedb.DB, s: worldstate.Swing, weapon: Form_ID) -> f32 {
	switch {
	case .Bash in s.kind && .Power in s.kind: return gamedb.setting_float(db, "fStaminaPowerBashBase", 55)
	case .Bash in s.kind:                     return gamedb.setting_float(db, "fStaminaBashBase", 35)
	case .Power in s.kind:
		weight, _ := gamedb.weight_of(db, weapon)
		base := gamedb.setting_float(db, "fStaminaAttackWeaponBase", 20) + weight * gamedb.setting_float(db, "fStaminaAttackWeaponMult", 1)
		return base * gamedb.setting_float(db, "fPowerAttackStaminaPenalty", 2)
	}
	return 0
}

// use_hand is the player pressing a hand's button: a melee weapon or fists swing, a bow or crossbow
// fires its ammo, anything else casts.
use_hand :: proc(g: ^Game, c: ^script.Call, hand: gamedb.Slot, target: Form_ID) {
	player := g.sim.ws.player
	held := worldstate.in_slot(c.ws, c.db, player, hand)
	slot, is_gear := gamedb.equip_slot_of(c.db, held)
	switch {
	case held != 0 && (!is_gear || slot.kind != .Weapon):
		script.cast_hand(c, player, hand, target)
	case slot.weapon_type == combat.BOW || slot.weapon_type == combat.CROSSBOW:
		if ammo := worldstate.in_slot(c.ws, c.db, player, .Ammo); ammo != 0 {worldstate.request_fire(c.ws, player, held, ammo)}
	case slot.weapon_type != combat.STAFF:
		worldstate.request_swing(c.ws, player, {}, hand)
	}
}

// swing_target is the nearest live actor or destructible ref a fan of rays from `attacker`'s chest
// meets within `reach`.
@(private = "file")
swing_target :: proc(g: ^Game, phys: ^physics.World, attacker: Form_ID, reach: f32) -> (best: Form_ID) {
	box := worldstate.actor_box(&g.sim.ws, &g.db, attacker)
	chest := worldstate.ref_pos(&g.sim.ws, &g.db, attacker)
	chest.z = box[0].z + (box[1].z - box[0].z) * 0.7
	yaw := worldstate.ref_rot(&g.sim.ws, &g.db, attacker).z
	nearest := f32(2)
	for i in 0 ..< SWING_RAYS {
		a := yaw + SWING_CONE * (f32(i) / f32(SWING_RAYS - 1) * 2 - 1)
		to := chest + [3]f32{math.sin(a), math.cos(a), 0} * reach
		for h in physics.ray_hits(phys, chest, to) {
			target := Form_ID(h.owner)
			if target == attacker || target == 0 {continue}
			_, destructible := gamedb.destructible_of(&g.db, worldstate.ref_base(&g.sim.ws, &g.db, target))
			if (live_actor(g, target) || destructible) && h.fraction < nearest {best, nearest = target, h.fraction}
			break
		}
	}
	return
}
