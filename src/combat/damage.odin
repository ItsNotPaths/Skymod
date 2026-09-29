package combat

// Weapon damage: what one landed hit takes from its target's Health. Table.damage is the vanilla
// formula; a plugin replaces it.

import "../plugin"

// Attack is one weapon hit that landed: melee, a projectile or a bash.
Attack :: struct {
	attacker, target, weapon: Form_ID,
}

// (hole damage-perks :tags combat :sev gap :needs damage-perk-conditions) no perk changes a hit: Calculate_Weapon_Damage (9 SE entries), Mod_Attack_Damage (58; tabs owner, weapon, target), Mod_Incoming_Damage (17; owner, attacker, weapon) and Mod_Target_Damage_Resistance (6, armor penetration) are not run: the World has no perk entry-point call (script.perk_value).
// (hole armor-rating :tags (combat player) :sev gap) worn armor stops nothing: ARMO DNAM and its armor type are not decoded. Data: per piece rating x skill factor (player 1..fArmorRatingPCMax 1.4, NPC fArmorRatingBase 1..fArmorRatingMax 2.5, LightArmor or HeavyArmor), plus DamageResist and Mod_Armor_Rating (15); the cut is rating x fArmorScalingFactor 0.12 %, capped at fMaxArmorRating 80. fArmorBaseFactor 0.03 per piece is unsourced.
// (hole critical-hits :tags combat :sev gap) no hit is critical: WEAP CRDT (crit damage, crit % mult, crit spell) is not decoded, and Calculate_My_Critical_Hit_Chance (13) and Calculate_My_Critical_Hit_Damage (8) are not run; fCombatUnarmedCritDamageMult 1.
// (hole attack-multipliers :tags combat :sev gap) an Attack has no power, sneak or bash kind, so no multiplier: power fPowerAttackDefaultBonus 1 and Mod_Power_Attack_Damage (2); sneak fCombatSneak*Mult per weapon type (3 one-hand, 2 two-hand, fCombatSneakHandMult 2) and Mod_Sneak_Attack_Mult (4); bash fShieldBashMin/Max, fWeaponBashMax and Mod_Bashing_Damage (1). hit-model says which kind an attack is.
// (hole game-difficulty :tags (combat player save) :sev gap) no game difficulty: the save stores no level (user, 2026-09-29: it lives in the save), and fDiffMultHPByPC*/fDiffMultHPToPC* are not in Skyrim.esm (engine defaults; UESP: dealt 2, 1.5, 1, 0.75, 0.5, 0.25 and taken 0.5, 0.75, 1, 1.5, 2, 3 from Novice to Legendary).
// (hole block-damage :tags (combat unclaimed) :sev gap :needs (combat-damage actor-states)) a block cuts nothing: fBlockMax 0.7, fBlockWeaponBase 0.3, fBlockWeaponScaling 0.2, fBlockSkillMult 2, fBlockPowerAttackMult 0.66, Mod_Percent_Blocked (8), and the stamina drain fStaminaBlockDmgMult 0.25. No actor has a block state.
// (hole gear-stats :tags (combat player) :sev gap) a hit's base is the WEAP DATA damage alone: no skill factor (player fDamagePCSkillMin, engine default 1, to fDamagePCSkillMax 1.5; NPC unsourced, not in Skyrim.esm), no race UnarmedDamage for fists; WEAP DNAM skill is not decoded.
// damage_builtin is the Health `a` takes, from the damage its weapon (and ammo) base gives.
@(private)
damage_builtin :: proc "c" (w: ^plugin.World, a: Attack, base: f32) -> f32 {
	return base
}
