package combat

// Weapon damage: what one landed hit takes from its target's Health. Table.damage is the vanilla
// formula; a plugin replaces it.

import "../formats/esm"
import "../plugin"

HAND_TO_HAND :: u8(0) // WEAP DNAM animation type: fists

// Attack is one weapon hit that landed: melee, a projectile or a bash.
Attack :: struct {
	attacker, target, weapon: Form_ID,
}

// (hole armor-base-factor :tags combat :sev polish) unsourced: fArmorBaseFactor 0.03 per worn piece (Skyrim.esm) is not applied; nothing says what it adds to.
// (hole critical-hits :tags combat :sev gap) no hit is critical: nothing rolls, the decoded CRDT (Equip_Slot gear: crit damage, crit % mult, crit spell) is unread, and the hit hook has no crit_chance or crit_damage part for the perks (20 and 12 entries); fCombatUnarmedCritDamageMult 1.
// (hole attack-multipliers :tags combat :sev gap) an Attack has no power, sneak or bash kind, so no multiplier: power fPowerAttackDefaultBonus 1; sneak fCombatSneak*Mult per weapon type (3 one-hand, 2 two-hand, fCombatSneakHandMult 2); bash fShieldBashMin/Max, fWeaponBashMax; each wants a hit hook part for its perks (power 2, sneak 4, bash 2 entries). hit-model says which kind an attack is.
// (hole game-difficulty :tags (combat player save) :sev gap) no game difficulty: the save stores no level (user, 2026-09-29: it lives in the save), and fDiffMultHPByPC*/fDiffMultHPToPC* are not in Skyrim.esm (engine defaults; UESP: dealt 2, 1.5, 1, 0.75, 0.5, 0.25 and taken 0.5, 0.75, 1, 1.5, 2, 3 from Novice to Legendary).
// (hole block-damage :tags (combat unclaimed) :sev gap :needs (combat-damage actor-states)) a block cuts nothing: fBlockMax 0.7, fBlockWeaponBase 0.3, fBlockWeaponScaling 0.2, fBlockSkillMult 2, fBlockPowerAttackMult 0.66, Mod_Percent_Blocked (8), and the stamina drain fStaminaBlockDmgMult 0.25. No actor has a block state.
// (hole npc-damage-skill :tags combat :sev polish) unsourced: whether an NPC's weapon skill scales its damage with the player's fDamagePCSkillMin/Max; every actor uses them.
// damage_builtin is the Health `a` takes: its weapon's damage scaled by the attacker's skill, less
// what the target's armor stops.
@(private)
damage_builtin :: proc "c" (w: ^plugin.World, a: Attack, base: f32) -> f32 {
	return weapon_damage(w, a, base) * (1 - armor_cut(w, a.target))
}

// weapon_damage is `base` times the weapon skill's factor: fDamagePCSkillMin (engine default 1) at
// skill 0 to fDamagePCSkillMax at 100. Fists deal the attacker's UnarmedDamage.
@(private = "file")
weapon_damage :: proc "contextless" (w: ^plugin.World, a: Attack, base: f32) -> f32 {
	slot: plugin.Equip_Slot
	has := a.weapon != 0 && plugin.record(w, a.weapon, .Equip_Slot, &slot)
	if !has || slot.weapon_type == HAND_TO_HAND {return w.actor_value(w.data, a.attacker, "UnarmedDamage", .Value)}
	if slot.gear.skill < 0 {return base}
	lo, hi := setting(w, "fDamagePCSkillMin", 1), setting(w, "fDamagePCSkillMax", 1.5)
	return base * (lo + (hi - lo) * skill(w, a.attacker, slot.gear.skill) / 100)
}

// armor_cut is the share of a hit the target's armor stops: each worn piece's rating times its
// skill factor, plus DamageResist, at fArmorScalingFactor percent a point, up to fMaxArmorRating.
@(private = "file")
armor_cut :: proc "contextless" (w: ^plugin.World, target: Form_ID) -> f32 {
	rating := w.actor_value(w.data, target, "DamageResist", .Value)
	for item in plugin.items(w.worn(w.data, target)) {
		slot: plugin.Equip_Slot
		if !plugin.record(w, item, .Equip_Slot, &slot) || slot.gear.armor_rating == 0 {continue}
		rating += slot.gear.armor_rating * armor_factor(w, target, slot.gear.armor_type)
	}
	percent := min(rating * setting(w, "fArmorScalingFactor", 0.12), setting(w, "fMaxArmorRating", 80))
	return max(percent, 0) / 100
}

// armor_factor scales a piece's rating by the wearer's skill in its type: 1 at skill 0 to
// fArmorRatingPCMax at 100 for the player, fArmorRatingBase to fArmorRatingMax for an NPC.
@(private = "file")
armor_factor :: proc "contextless" (w: ^plugin.World, actor: Form_ID, type: esm.Armor_Type) -> f32 {
	lo, hi := f32(1), setting(w, "fArmorRatingPCMax", 1.4)
	if actor != w.player {lo, hi = setting(w, "fArmorRatingBase", 1), setting(w, "fArmorRatingMax", 2.5)}
	name: cstring = "HeavyArmor" if type == .Heavy else "LightArmor"
	return lo + (hi - lo) * w.actor_value(w.data, actor, name, .Value) / 100
}

// skill reads the actor value at `index` (esm.AV_NAMES).
@(private = "file")
skill :: proc "contextless" (w: ^plugin.World, actor: Form_ID, index: i32) -> f32 {
	if int(index) >= len(esm.AV_NAMES) {return 0}
	buf: [64]u8
	n := copy(buf[:len(buf) - 1], esm.AV_NAMES[index])
	buf[n] = 0
	return w.actor_value(w.data, actor, cstring(raw_data(buf[:])), .Value)
}

@(private = "file")
setting :: proc "contextless" (w: ^plugin.World, name: cstring, fallback: f32) -> f32 {
	return w.setting(w.data, name, fallback)
}
