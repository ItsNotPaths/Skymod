package main

import "core:math"
import "../gamedb"
import "../physics"
import "../script"
import "../worldstate"

// (hole swing-cone :tags combat :sev polish) unsourced: how wide a swing reaches; it tests rays across SWING_CONE either side of the facing, at chest height.
SWING_CONE :: f32(math.PI / 6)
SWING_RAYS :: 5

// tick_swings lands the swings brains asked for: the first live actor a ray from the attacker's
// chest meets inside its reach, the right-hand weapon's WEAP reach x fCombatDistance (fists 1x).
tick_swings :: proc(g: ^Game) {
	defer clear(&g.sim.ws.swings)
	sp := active_space(g)
	if sp == nil || sp.phys == nil {return}
	c := script.Call{ws = &g.sim.ws, db = &g.db}
	for s in g.sim.ws.swings {
		weapon := worldstate.in_slot(c.ws, c.db, s.attacker, .RightHand)
		slot, _ := gamedb.equip_slot_of(c.db, weapon)
		if slot.kind != .Weapon {weapon, slot = 0, {}}
		reach := (slot.gear.reach if slot.gear.reach > 0 else 1) * gamedb.setting_float(c.db, "fCombatDistance", 141)
		if target := swing_target(g, sp.phys, s.attacker, reach); target != 0 {
			script.weapon_hit(&c, s.attacker, target, weapon, s.kind, slot.damage)
		}
	}
}

// swing_target is the nearest live actor a fan of rays from `attacker`'s chest meets within `reach`.
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
			if live_actor(g, target) && h.fraction < nearest {best, nearest = target, h.fraction}
			break
		}
	}
	return
}
