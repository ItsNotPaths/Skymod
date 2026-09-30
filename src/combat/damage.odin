package combat

// Weapon damage: what one landed hit takes from its target's Health. Table.damage is the vanilla
// formula; a plugin replaces it.

import "../plugin"

// WEAP DNAM animation types
HAND_TO_HAND :: u8(0)
BOW :: u8(7)
STAFF :: u8(8)
CROSSBOW :: u8(9)

// Attack is one weapon hit that landed: melee, a projectile or a bash, with what the hit and armor
// hooks (perks, as Lua) made of its numbers.
Attack :: struct {
	attacker, target, weapon: Form_ID,
	kind:                     Attack_Kind,
	roll:                     f32, // uniform in [0, 1): the crit roll
	damage:                   Part, // the weapon's damage
	armor_pen:                Part, // the target's armor rating
	crit_chance:              Part, // percent, from the attacker's CritChance
	crit_damage:              Part, // the weapon's crit damage (CRDT)
	power_mult:               Part, // a power attack's multiplier
	sneak_mult:               Part, // a sneak attack's multiplier
	armor:                    plugin.Span(Piece), // the target's worn armor
}

Attack_Kind :: bit_set[enum u8 {
	Power,
	Sneak, // the target had not detected the attacker
	Bash,
}]

// Part is what hooks made of one number: set replaces it, else (value + add) x mult.
Part :: struct {
	add, mult: f32,
	set:       f32,
	has_set:   bool,
}

KEEP :: Part{mult = 1}

// attack is a hit whose parts all keep their numbers.
attack :: proc "contextless" (attacker, target, weapon: Form_ID, kind: Attack_Kind = {}) -> Attack {
	return {
		attacker = attacker, target = target, weapon = weapon, kind = kind,
		damage = KEEP, armor_pen = KEEP, crit_chance = KEEP, crit_damage = KEEP, power_mult = KEEP, sneak_mult = KEEP,
	}
}

// Piece is one worn armor item and what the armor hooks made of its rating.
Piece :: struct {
	item:   Form_ID,
	rating: Part,
}

apply :: proc "contextless" (p: Part, v: f32) -> f32 {
	return p.set if p.has_set else (v + p.add) * p.mult
}

// (hole armor-base-factor :tags combat :sev polish) unsourced: fArmorBaseFactor 0.03 per worn piece (Skyrim.esm) is not applied; nothing says what it adds to.
// (hole crit-rules :tags combat :sev polish) unsourced: a crit adds CRDT damage after skill and before the power and sneak multipliers, and CRDT's crit % mult is unread (IronSword's is 0 and it still crits with Bladesman, UESP); nothing says what it scales. The crit spell is not cast.
// (hole bash-damage :tags (combat unclaimed) :sev gap :needs (hit-model)) a bash deals its weapon's damage: no bash formula (fShieldBashMin 0.05, fShieldBashMax 0.25, fShieldBashPCMax, fWeaponBashMax 0.25, all unsourced in shape) and no part for its perks (Mod_Bashing_Damage, 2 entries).
// (hole ranged-sneak-mult :tags combat :sev polish) unsourced: a bow, crossbow or staff sneak attack's multiplier; Skyrim.esm has no fCombatSneak GMST for them, so 2 (UESP: ranged sneak attacks deal double).
// (hole game-difficulty :tags (combat player save) :sev gap) no game difficulty: the save stores no level (user, 2026-09-29: it lives in the save), and fDiffMultHPByPC*/fDiffMultHPToPC* are not in Skyrim.esm (engine defaults; UESP: dealt 2, 1.5, 1, 0.75, 0.5, 0.25 and taken 0.5, 0.75, 1, 1.5, 2, 3 from Novice to Legendary).
// (hole block-damage :tags (combat unclaimed) :sev gap :needs (combat-damage actor-states)) a block cuts nothing: fBlockMax 0.7, fBlockWeaponBase 0.3, fBlockWeaponScaling 0.2, fBlockSkillMult 2, fBlockPowerAttackMult 0.66, Mod_Percent_Blocked (8), and the stamina drain fStaminaBlockDmgMult 0.25. No actor has a block state.
// (hole npc-damage-skill :tags combat :sev polish) unsourced: whether an NPC's weapon skill scales its damage with the player's fDamagePCSkillMin/Max; every actor uses them.
// damage_builtin is the Health `a` takes: its weapon's damage scaled by the attacker's skill, plus a
// crit's, times a power or sneak attack's multiplier, less what the target's armor stops.
@(private)
damage_builtin :: proc "c" (w: ^plugin.World, a: Attack, base: f32) -> f32 {
	slot: plugin.Equip_Slot
	if a.weapon == 0 || !plugin.record(w, a.weapon, .Equip_Slot, &slot) {slot = {}} // fists
	hit := weapon_damage(w, a, slot, base)
	if a.roll * 100 < apply(a.crit_chance, w.actor_value(w.data, a.attacker, "CritChance", .Value)) {
		hit += crit_damage(w, a, slot)
	}
	if .Power in a.kind {hit *= apply(a.power_mult, 1 + setting(w, "fPowerAttackDefaultBonus", 1))}
	if .Sneak in a.kind {hit *= apply(a.sneak_mult, sneak_mult(w, slot.weapon_type))}
	return hit * (1 - armor_cut(w, a))
}

// weapon_damage is `base` times the weapon skill's factor: fDamagePCSkillMin (engine default 1) at
// skill 0 to fDamagePCSkillMax at 100. Fists deal the attacker's UnarmedDamage.
@(private = "file")
weapon_damage :: proc "contextless" (w: ^plugin.World, a: Attack, slot: plugin.Equip_Slot, base: f32) -> f32 {
	if slot.weapon_type == HAND_TO_HAND {return apply(a.damage, w.actor_value(w.data, a.attacker, "UnarmedDamage", .Value))}
	if slot.gear.skill < 0 {return apply(a.damage, base)}
	lo, hi := setting(w, "fDamagePCSkillMin", 1), setting(w, "fDamagePCSkillMax", 1.5)
	return apply(a.damage, base) * (lo + (hi - lo) * skill(w, a.attacker, slot.gear.skill) / 100)
}

// crit_damage is what a crit adds: the weapon's CRDT damage, or for fists UnarmedDamage times
// fCombatUnarmedCritDamageMult.
@(private = "file")
crit_damage :: proc "contextless" (w: ^plugin.World, a: Attack, slot: plugin.Equip_Slot) -> f32 {
	if slot.weapon_type == HAND_TO_HAND {
		unarmed := w.actor_value(w.data, a.attacker, "UnarmedDamage", .Value)
		return apply(a.crit_damage, unarmed * setting(w, "fCombatUnarmedCritDamageMult", 1))
	}
	return apply(a.crit_damage, f32(slot.gear.crit_damage))
}

// sneak_mult is a sneak attack's multiplier for the weapon type: fCombatSneak*Mult.
@(private = "file")
sneak_mult :: proc "contextless" (w: ^plugin.World, weapon_type: u8) -> f32 {
	switch weapon_type {
	case HAND_TO_HAND:           return setting(w, "fCombatSneakHandMult", 2)
	case 1:                      return setting(w, "fCombatSneak1HSwordMult", 3)
	case 2:                      return setting(w, "fCombatSneak1HDaggerMult", 3)
	case 3:                      return setting(w, "fCombatSneak1HAxeMult", 3)
	case 4:                      return setting(w, "fCombatSneak1HMaceMult", 3)
	case 5:                      return setting(w, "fCombatSneak2HSwordMult", 2)
	case 6:                      return setting(w, "fCombatSneak2HAxeMult", 2) // battleaxes and warhammers
	case BOW, STAFF, CROSSBOW:   return 2
	}
	return 1
}

// armor_cut is the share of a hit the target's armor stops: each worn piece's rating times its
// skill factor, plus DamageResist, at fArmorScalingFactor percent a point, up to fMaxArmorRating.
@(private = "file")
armor_cut :: proc "contextless" (w: ^plugin.World, a: Attack) -> f32 {
	rating := w.actor_value(w.data, a.target, "DamageResist", .Value)
	for p in plugin.items(a.armor) {
		slot: plugin.Equip_Slot
		if !plugin.record(w, p.item, .Equip_Slot, &slot) {continue}
		rating += apply(p.rating, slot.gear.armor_rating * armor_factor(w, a.target, slot.gear.armor_type))
	}
	percent := min(apply(a.armor_pen, rating) * setting(w, "fArmorScalingFactor", 0.12), setting(w, "fMaxArmorRating", 80))
	return max(percent, 0) / 100
}

// armor_factor scales a piece's rating by the wearer's skill in its type: 1 at skill 0 to
// fArmorRatingPCMax at 100 for the player, fArmorRatingBase to fArmorRatingMax for an NPC.
@(private = "file")
armor_factor :: proc "contextless" (w: ^plugin.World, actor: Form_ID, type: plugin.Armor_Type) -> f32 {
	lo, hi := f32(1), setting(w, "fArmorRatingPCMax", 1.4)
	if actor != w.player {lo, hi = setting(w, "fArmorRatingBase", 1), setting(w, "fArmorRatingMax", 2.5)}
	name: cstring = "HeavyArmor" if type == .Heavy else "LightArmor"
	return lo + (hi - lo) * w.actor_value(w.data, actor, name, .Value) / 100
}

// skill reads the actor value at `index` (plugin.av_name).
@(private = "file")
skill :: proc "contextless" (w: ^plugin.World, actor: Form_ID, index: i32) -> f32 {
	name := plugin.av_name(index)
	if name == "" {return 0}
	buf: [64]u8
	n := copy(buf[:len(buf) - 1], name)
	buf[n] = 0
	return w.actor_value(w.data, actor, cstring(raw_data(buf[:])), .Value)
}

@(private = "file")
setting :: proc "contextless" (w: ^plugin.World, name: cstring, fallback: f32) -> f32 {
	return w.setting(w.data, name, fallback)
}
