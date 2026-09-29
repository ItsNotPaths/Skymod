package script

// The host side of the combat seam's damage (src/combat).

import "../combat"
import "../worldhost"

combat_table := combat.BUILTIN // the built-in brain and damage, or a plugin's

// (hole combat-hit-spells :tags (combat magic) :sev gap) no perk casts on a hit: Apply_Combat_Hit_Spell (57 SE entries), Apply_Bashing_Spell (4) and Apply_Weapon_Swing_Spell (1) pick a spell (Select_Spell), and perk_value only changes a number.
// (hole attack-stamina :tags combat :sev gap :needs (combat-damage)) an attack costs no Stamina: fStaminaAttackWeaponBase 20 and fStaminaAttackWeaponMult 1, fPowerAttackStaminaPenalty 2, Mod_Power_Attack_Stamina (3), fStaminaBashBase 35, fStaminaPowerBashBase 55.
// land_attack is everything a landed weapon hit does to its target.
land_attack :: proc(c: ^Call, a: combat.Attack, base: f32) {
	wd := worldhost.Data{context, c.ws, c.db}
	w := worldhost.world(&wd)
	damage_health(c, a.target, combat_table.damage(&w, a, base), a.attacker)
}
