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

// AV_Kind is how an actor value holds its amount against its capacity. Static: the value is its
// capacity, and effects move it. Latched: the amount is damage below the capacity, so it rides with it
// (Health at 80/100 fortified +50 reads 130/150; a skill fortified +20 reads 20 over its level).
// Pool: the amount is its own stock under the capacity, a soft cap only training checks (a mod's).
AV_Kind :: enum u8 {
	Static,
	Latched,
	Pool,
}

// SKILL_CAP is the cap training stops at (a pool's capacity) until something raises it.
SKILL_CAP :: f32(100)

// av_kind is an engine actor value's kind (a canonical name).
av_kind :: proc(av: string) -> AV_Kind {
	switch av {
	case "Health", "Magicka", "Stamina": return .Latched
	}
	for name in AV_NAMES[6:24] {
		if name == av {return .Latched} // the skills
	}
	return .Static
}

// skill_xp_of is a skill's XP rates from its AVIF (`skill` a canonical name).
skill_xp_of :: proc(db: ^DB, skill: string) -> (xp: esm.Skill_XP, ok: bool) {
	for name, i in AV_NAMES {
		if name != skill {continue}
		info := db.actor_value_info[db.actor_value_by_index[i32(i)]] or_return
		return info.skill, info.has_skill
	}
	return
}

// skill_advance_av is the actor value holding a skill's XP toward its next level (OneHanded ->
// OneHandedSkillAdvance, Pickpocket -> PickPocketSkillAdvance).
skill_advance_av :: proc(skill: string) -> (string, bool) {
	return actor_value_name(strings.concatenate({skill, "SkillAdvance"}, context.temp_allocator))
}

// actor_value_name is the AV_NAMES entry for a name in any case.
actor_value_name :: proc(name: string) -> (av: string, ok: bool) {
	buf: [AV_NAME_MAX]u8
	key := av_key(name, buf[:]) or_return
	return av_by_name[key]
}

AV_NAME_MAX :: 48

// av_key is `name` lower-cased into `buf`, the key of every actor value name table.
av_key :: proc(name: string, buf: []u8) -> (string, bool) {
	if len(name) > len(buf) {return "", false}
	for i in 0 ..< len(name) {
		b := name[i]
		buf[i] = b + 32 if b >= 'A' && b <= 'Z' else b
	}
	return string(buf[:len(name)]), true
}

// actor_value_base is the base an actor's records give actor value `av` (a canonical name),
// following ref → base and the NPC_'s templates, with `pick` standing in for a leveled template. Sources: CK wiki Class, UESP Mod File Format
// NPC_/CLAS, tes4skyrim (disassembly). Checked against the DNAM cache of every vanilla auto-calc
// NPC_ with a static level (ws.md, Workstream P).
actor_value_base :: proc(db: ^DB, form: Form_ID, av: string, pick: Form_ID = 0) -> f32 {
	if db == nil {return implicit_base(av)}
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	npc, ok := db.actors[base]
	if !ok {return implicit_base(av)}
	stats := template_part(db, base, esm.ACBS_TEMPLATE_STATS, pick)
	race, _ := race_of(db, template_part(db, base, esm.ACBS_TEMPLATE_TRAITS, pick).race)
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
		if name == av {return f32(template_part(db, base, esm.ACBS_TEMPLATE_AI_DATA, pick).ai[i])}
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
// chain while each link has the flag. At an LVLN the chain goes on from `pick`, the NPC_ it rolled
// (worldstate.actor_pick), and ends there when there is none.
template_part :: proc(db: ^DB, base: Form_ID, flag: u16, pick: Form_ID = 0) -> Actor_Base {
	return db.actors[template_form(db, base, flag, pick)]
}

// template_form is the NPC_ form template_part reads.
template_form :: proc(db: ^DB, base: Form_ID, flag: u16, pick: Form_ID = 0) -> Form_ID {
	form, pick := base, pick
	for hops := 0; hops < 8; hops += 1 {
		a, ok := db.actors[form]
		if !ok || a.template_flags & flag == 0 {break}
		next := a.template
		if next not_in db.actors {next, pick = pick, 0}
		if next not_in db.actors {break}
		form = next
	}
	return form
}

// actor_name is an NPC_'s display name: its own FULL, or its base-data template's (2,866 vanilla
// NPC_ take theirs that way), `pick` standing in for a leveled one.
actor_name :: proc(db: ^DB, base: Form_ID, pick: Form_ID = 0) -> string {
	return db.names[template_form(db, base, esm.ACBS_TEMPLATE_BASE_DATA, pick)]
}

// HUMAN_BOUNDS is the player's OBND, for an actor whose NPC_ and race carry none.
HUMAN_BOUNDS :: [2][3]f32{{-22, -14, 0}, {22, 14, 128}}

// (hole actor-bounds-missing :tags (player records) :sev gap) 15 vanilla races have no NPC_ with a nonzero OBND (hare, chicken, bear, troll, chaurus, frost atronach, the vampire races...), so they get human bounds; their skeleton or body mesh bounds would give the real size (build/out/wsP/bodies/obnd_se.txt).
// actor_bounds is an actor's OBND box at scale 1: its NPC_'s (through the traits template, `pick`
// standing in for a leveled one), else the first nonzero one of its race, else HUMAN_BOUNDS.
actor_bounds :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> [2][3]f32 {
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	npc, ok := db.actors[base]
	if !ok {return HUMAN_BOUNDS}
	part := template_part(db, base, esm.ACBS_TEMPLATE_TRAITS, pick)
	if part.bounds != {} {return part.bounds}
	return db.race_bounds[part.race] or_else HUMAN_BOUNDS
}

// leveled_template is the LVLN an NPC_'s template chain reaches (0 = none).
leveled_template :: proc(db: ^DB, base: Form_ID) -> Form_ID {
	a, ok := db.actors[base]
	for hops := 0; ok && a.template != 0 && hops < 8; hops += 1 {
		if a.template in db.leveled_lists {return a.template}
		a, ok = db.actors[a.template]
	}
	return 0
}

// record_level is the level an actor's records give it: its NPC_'s, through the stats template
// (`pick` standing in for a leveled one).
record_level :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> i32 {
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	npc, ok := db.actors[base]
	if !ok {return 1}
	return i32(actor_level(db, template_part(db, base, esm.ACBS_TEMPLATE_STATS, pick)))
}

// (hole pc-level-mult :tags (player records) :sev gap) a PC Level Mult NPC_'s level is floor(mult x player level) clamped to its calc band, but no source gives the rounding (601 vanilla NPC_, multipliers like x1.1), and this reads the player's record level, not worldstate.actor_level. Settle by disassembly (TESActorBaseData::GetLevel, RELOCATION_ID 14262 SE / 14384 AE).
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
// (hole skill-cap-share :tags (records player) :sev polish) past the 100 cap the game drops part of the excess; sharing all of it matches 11 of the 24 vanilla NPC_ that reach the cap (check: build/out/wsP/autocalc/rr.py).
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
