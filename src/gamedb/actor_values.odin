package gamedb

import "base:runtime"
import "core:strings"
import "../formats/esm"

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

// (hole actor-values :tags (player combat magic) :sev blocker) the base from NPC_, RACE and CLAS (auto-calc, race start, ACBS offsets, implicit defaults) is never computed, so every base reads 0 until SetActorValue writes one.
// actor_value_base is the base an actor's records give actor value `av`, following ref → base.
actor_value_base :: proc(db: ^DB, form: Form_ID, av: string) -> f32 {
	return 0
}
