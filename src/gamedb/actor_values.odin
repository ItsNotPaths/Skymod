package gamedb

import "base:runtime"
import "core:strings"
import "../formats/esm"
import "../formid"

// The engine's actor values. An actor value is its name here, in this case; MGEF, RACE, CLAS and
// CTDA store an index into this table. AVIF records do not give the names: 9 EDIDs differ (21 is
// AVMysticism) and 15 indices have no record at all.

AV_NAMES := [esm.ACTOR_VALUE_COUNT]string {
	"Aggression", "Confidence", "Energy", "Morality", "Mood", "Assistance",
	"OneHanded", "TwoHanded", "Marksman", "Block", "Smithing", "HeavyArmor",
	"LightArmor", "Pickpocket", "Lockpicking", "Sneak", "Alchemy", "Speechcraft",
	"Alteration", "Conjuration", "Destruction", "Illusion", "Restoration", "Enchanting",
	"Health", "Magicka", "Stamina", "HealRate", "MagickaRate", "StaminaRate",
	"SpeedMult", "InventoryWeight", "CarryWeight", "CritChance", "MeleeDamage", "UnarmedDamage",
	"Mass", "VoicePoints", "VoiceRate", "DamageResist", "PoisonResist", "FireResist",
	"ElectricResist", "FrostResist", "MagicResist", "DiseaseResist", "PerceptionCondition", "EnduranceCondition",
	"LeftAttackCondition", "RightAttackCondition", "LeftMobilityCondition", "RightMobilityCondition", "BrainCondition", "Paralysis",
	"Invisibility", "NightEye", "DetectLifeRange", "WaterBreathing", "WaterWalking", "IgnoreCrippledLimbs",
	"Fame", "Infamy", "JumpingBonus", "WardPower", "RightItemCharge", "ArmorPerks",
	"ShieldPerks", "WardDeflection", "Variable01", "Variable02", "Variable03", "Variable04",
	"Variable05", "Variable06", "Variable07", "Variable08", "Variable09", "Variable10",
	"BowSpeedBonus", "FavorActive", "FavorsPerDay", "FavorsPerDayTimer", "LeftItemCharge", "AbsorbChance",
	"Blindness", "WeaponSpeedMult", "ShoutRecoveryMult", "BowStaggerBonus", "Telekinesis", "FavorPointsBonus",
	"LastBribedIntimidated", "LastFlattered", "MovementNoiseMult", "BypassVendorStolenCheck", "BypassVendorKeywordCheck", "WaitingForPlayer",
	"OneHandedMod", "TwoHandedMod", "MarksmanMod", "BlockMod", "SmithingMod", "HeavyArmorMod",
	"LightArmorMod", "PickPocketMod", "LockpickingMod", "SneakMod", "AlchemyMod", "SpeechcraftMod",
	"AlterationMod", "ConjurationMod", "DestructionMod", "IllusionMod", "RestorationMod", "EnchantingMod",
	"OneHandedSkillAdvance", "TwoHandedSkillAdvance", "MarksmanSkillAdvance", "BlockSkillAdvance", "SmithingSkillAdvance", "HeavyArmorSkillAdvance",
	"LightArmorSkillAdvance", "PickPocketSkillAdvance", "LockpickingSkillAdvance", "SneakSkillAdvance", "AlchemySkillAdvance", "SpeechcraftSkillAdvance",
	"AlterationSkillAdvance", "ConjurationSkillAdvance", "DestructionSkillAdvance", "IllusionSkillAdvance", "RestorationSkillAdvance", "EnchantingSkillAdvance",
	"LeftWeaponSpeedMult", "DragonSouls", "CombatHealthRegenMult", "OneHandedPowerMod", "TwoHandedPowerMod", "MarksmanPowerMod",
	"BlockPowerMod", "SmithingPowerMod", "HeavyArmorPowerMod", "LightArmorPowerMod", "PickPocketPowerMod", "LockpickingPowerMod",
	"SneakPowerMod", "AlchemyPowerMod", "SpeechcraftPowerMod", "AlterationPowerMod", "ConjurationPowerMod", "DestructionPowerMod",
	"IllusionPowerMod", "RestorationPowerMod", "EnchantingPowerMod", "DragonRend", "AttackDamageMult", "HealRateMult",
	"MagickaRateMult", "StaminaRateMult", "WerewolfPerks", "VampirePerks", "GrabActorOffset", "Grabbed",
	"DEPRECATED05", "ReflectDamage",
}

@(private = "file")
av_by_name: map[string]string // lower-case -> AV_NAMES entry

@(init, private = "file")
index_av_names :: proc "contextless" () {
	context = runtime.default_context()
	for name in AV_NAMES {av_by_name[strings.to_lower(name)] = name}
}

@(fini, private = "file")
free_av_names :: proc "contextless" () {
	context = runtime.default_context()
	for k in av_by_name {delete(k)}
	delete(av_by_name)
}

// (hole mod-actor-values :tags (script mods) :sev gap) only AV_NAMES resolve: OnGameLoaded and rt.actor_value do not exist, so a mod cannot create an actor value (design in ws.md, Workstream P).
// actor_value_name is the AV_NAMES entry for a name in any case.
actor_value_name :: proc(name: string) -> (string, bool) {
	buf: [48]u8
	if len(name) > len(buf) {return "", false}
	for i in 0 ..< len(name) {
		b := name[i]
		buf[i] = b + 32 if b >= 'A' && b <= 'Z' else b
	}
	av, ok := av_by_name[string(buf[:len(name)])]
	return av, ok
}

// actor_value_base is the base an actor's records give actor value `av` (a canonical name),
// following ref → base and the NPC_'s templates. Sources: CK wiki Class, UESP Mod File Format
// NPC_/CLAS, tes4skyrim (disassembly). Checked against the DNAM cache of every vanilla auto-calc
// NPC_ with a static level (ws.md, Workstream P).
actor_value_base :: proc(db: ^DB, form: Form_ID, av: string) -> f32 {
	if db == nil {return implicit_base(av)}
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	npc, ok := db.actors[base]
	if !ok {return implicit_base(av)}
	stats := template_part(db, npc, esm.ACBS_TEMPLATE_STATS)
	race, _ := race_of(db, template_part(db, npc, esm.ACBS_TEMPLATE_TRAITS).race)
	switch av {
	case "Health":        return race.info.health + f32(stats.health_off) + f32(attribute_gain(db, stats, 0))
	case "Magicka":       return race.info.magicka + f32(stats.magicka_off) + f32(attribute_gain(db, stats, 1))
	case "Stamina":       return race.info.stamina + f32(stats.stamina_off) + f32(attribute_gain(db, stats, 2))
	case "SpeedMult":     return f32(stats.speed_mult)
	case "CarryWeight":   return race.info.carry_weight
	case "Mass":          return race.info.mass
	case "HealRate":      return race.info.health_rate
	case "MagickaRate":   return race.info.magicka_rate
	case "StaminaRate":   return race.info.stamina_rate
	case "UnarmedDamage": return race.info.unarmed_damage
	}
	for name, i in AV_NAMES[:6] {
		if name == av {return f32(template_part(db, npc, esm.ACBS_TEMPLATE_AI_DATA).ai[i])}
	}
	for name, i in AV_NAMES[6:24] {
		if name == av {return f32(skill_base(db, stats, race, i))}
	}
	return implicit_base(av)
}

// implicit_base is the base of an actor value no record sets (CK wiki: "usually 0 but in some
// cases can be 1 or 100"; the values are UESP's Actor Value Indices).
@(private)
implicit_base :: proc(av: string) -> f32 {
	switch av {
	case "AttackDamageMult": return 1
	case "SpeedMult", "HealRateMult", "MagickaRateMult", "StaminaRateMult": return 100
	}
	return 0
}

// template_part is the NPC_ that supplies the part `flag` names: the actor itself, or down its TPLT
// chain while each link has the flag. The chain ends at an LVLN (leveled-rolls).
template_part :: proc(db: ^DB, npc: Actor_Base, flag: u16) -> Actor_Base {
	a := npc
	for hops := 0; a.template_flags & flag != 0 && hops < 8; hops += 1 {
		next, ok := db.actors[a.template]
		if !ok {break}
		a = next
	}
	return a
}

// (hole pc-level-mult :tags (player records) :sev gap :needs (leveling)) a PC Level Mult NPC_'s level is floor(mult x player level) clamped to its calc band, but no source gives the rounding (601 vanilla NPC_, multipliers like x1.1), and the player's level is its ACBS level until leveling exists.
// actor_level is an NPC_'s level: its ACBS level, or its multiple of the player's, within its calc
// band (a calc max of 0 is no cap).
actor_level :: proc(db: ^DB, stats: Actor_Base) -> int {
	if stats.flags & esm.ACBS_PC_LEVEL_MULT == 0 {return max(int(stats.level), 1)}
	player := max(int(db.actors[formid.PLAYER_BASE].level), 1)
	lvl := max(int(f32(stats.level) / 1000 * f32(player)), int(stats.calc_min))
	if stats.calc_max > 0 {lvl = min(lvl, int(stats.calc_max))}
	return max(lvl, 1)
}

// attribute_gain is what auto-calc adds to health (0), magicka (1) or stamina (2): the class share of
// iAVDhmsLevelUp points per level above 1, and fNPCHealthLevelBonus per level on health.
@(private)
attribute_gain :: proc(db: ^DB, stats: Actor_Base, which: int) -> int {
	if stats.flags & esm.ACBS_AUTO_CALC_STATS == 0 {return 0}
	levels := actor_level(db, stats) - 1
	class, _ := class_of(db, stats.class)
	weights := [3]u8{class.info.health_weight, class.info.magicka_weight, class.info.stamina_weight}
	gain: [3]int
	share(int(setting_int(db, "iAVDhmsLevelUp", 10)) * levels, weights[:], gain[:])
	if which == 0 {gain[0] += int(setting_float(db, "fNPCHealthLevelBonus", 5)) * levels}
	return gain[which]
}

// skill_base is skill `i` (0..17): with auto-calc, iAVDSkillStart plus the race bonus plus the class
// share of iAVDSkillsLevelUp points per level above 1, capped at 100 with the excess shared among
// the rest; without it, the DNAM value plus its offset.
// (hole skill-cap-share :tags records :sev polish) past the 100 cap the game drops part of the excess; sharing all of it matches 11 of the 24 vanilla NPC_ that reach the cap.
@(private)
skill_base :: proc(db: ^DB, stats: Actor_Base, race: Race, i: int) -> int {
	if stats.flags & esm.ACBS_AUTO_CALC_STATS == 0 {return int(stats.skills[i]) + int(stats.skill_offsets[i])}
	class, _ := class_of(db, stats.class)
	skills: [esm.NPC_SKILLS]int
	for &s in skills {s = int(setting_int(db, "iAVDSkillStart", 15))}
	for k in 0 ..< race.info.bonus_count {
		b := race.info.bonuses[k]
		if b.skill >= 6 && b.skill < 24 {skills[b.skill - 6] += int(b.bonus)}
	}
	weights := class.info.skill_weights
	left := int(setting_int(db, "iAVDSkillsLevelUp", 8)) * (actor_level(db, stats) - 1)
	for left > 0 {
		add: [esm.NPC_SKILLS]int
		share(left, weights[:], add[:])
		left = 0
		for &s, k in skills {
			if weights[k] == 0 {continue}
			s += add[k]
			if s >= 100 {left += s - 100; s = 100; weights[k] = 0}
		}
	}
	return skills[i]
}

// share adds `points` to `out` by `weights`: floor(points / sum) x w to each, then the rest in
// rounds, round r giving one to each weight >= r, heavier first and ties to the higher index (UESP
// Mod File Format/CLAS; its prose says lower index, its example table and the data say higher).
@(private)
share :: proc(points: int, weights: []u8, out: []int) {
	sum := 0
	for w in weights {sum += int(w)}
	if sum == 0 || points <= 0 {return}
	sets := points / sum
	for w, i in weights {out[i] += sets * int(w)}
	order: [esm.NPC_SKILLS]int
	n := len(weights)
	for i in 0 ..< n {
		order[i] = i
		for j := i; j > 0 && heavier(weights, order[j], order[j - 1]); j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	left := points - sets * sum
	for r := 1; left > 0; r += 1 {
		for i in order[:n] {
			if left > 0 && int(weights[i]) >= r {out[i] += 1; left -= 1}
		}
	}
}

@(private)
heavier :: proc(weights: []u8, a, b: int) -> bool {
	return weights[a] > weights[b] || (weights[a] == weights[b] && a > b)
}
