package unit_tests

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import "../../src/formats/esm"
import "../../src/formula"
import "../../src/gamedb"
import "../../src/magictranslate"

// quoted is the string after `key = "` in `text`.
@(private = "file")
quoted :: proc(text, key: string) -> string {
	i := strings.index(text, fmt.tprintf("%s = \"", key))
	rest := text[i + len(key) + 4:]
	return rest[:strings.index_byte(rest, '"')]
}

@(private = "file")
eval_src :: proc(t: ^testing.T, src: string, vars: []string, values: []f64) -> f64 {
	f, err := formula.compile(src, vars, context.temp_allocator)
	testing.expectf(t, err == "", "%q: %s", src, err)
	return formula.eval(f, values)
}

// A translated effect's baked formulas move each AV as its archetype class does with the record's
// flags, for held and timed copies, with and without a taper, on both sides of an Absorb.
@(test)
test_magic_translate_terms :: proc(t: ^testing.T) {
	text, err := os.read_entire_file("src/script/effects/archetypevaluemodifier.lua", context.temp_allocator)
	testing.expect(t, err == nil, "read the Value Modifier class")
	cap, amt := quoted(string(text), "capacity"), quoted(string(text), "amount")
	CLASS_VARS := []string{"t", "m", "d", "held", "sign", "w", "tw", "tc", "td"}
	Key :: struct {
		av:        string,
		knob:      string,
		on_caster: bool,
	}
	for arch in ([]esm.Effect_Archetype{.Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier, .Absorb}) {
		for flags in ([]u32{0, esm.MGEF_RECOVER, esm.MGEF_DETRIMENTAL, esm.MGEF_RECOVER | esm.MGEF_DETRIMENTAL}) {
			for tw in ([]f32{0, 0.3}) {
				for lasting in ([]bool{false, true}) {
					info := esm.Magic_Effect_Info{archetype = arch, flags = flags, primary_av = 24, second_av = 26, second_av_weight = 0.5, taper_weight = tw, taper_curve = 2, taper_duration = 1}
					held := lasting || flags & esm.MGEF_RECOVER != 0
					class := make(map[Key]string, context.temp_allocator)
					#partial switch arch {
					case .Absorb:
						class[{"Health", "amount", false}] = amt
						class[{"Health", "amount", true}] = fmt.tprintf("-(%s)", amt)
					case .Dual_Value_Modifier:
						class[{"Stamina", "capacity", false}] = fmt.tprintf("w * %s", cap)
						class[{"Stamina", "amount", false}] = fmt.tprintf("w * %s", amt)
						fallthrough
					case:
						class[{"Health", "capacity", false}] = cap
						class[{"Health", "amount", false}] = amt
					}
					baked := magictranslate.effect_terms(info, held)
					for m in ([]f64{25}) {
						for d in ([]f64{0, 3}) {
							for step in 0 ..= 20 {
								tt := f64(step) * 0.25
								tt = tt if lasting else min(tt, d + 1)
								vals := []f64{tt, m, d, 1 if held else 0, -1 if flags & esm.MGEF_DETRIMENTAL != 0 else 1, 0.5, f64(tw), 2, 1}
								for k, src in class {
									want := eval_src(t, src, CLASS_VARS, vals)
									got: f64
									for b in baked {
										if b.av == k.av && b.knob == k.knob && b.on_caster == k.on_caster {
											got += eval_src(t, b.f, CLASS_VARS[:3], vals[:3])
										}
									}
									testing.expectf(t, math.abs(got - want) < 1e-4, "%v flags %X tw %v lasting %v d %v t %v %v: baked %v, class %v", arch, flags, tw, lasting, d, tt, k, got, want)
								}
							}
						}
					}
				}
			}
		}
	}
}

// MGEF conditions become the effect's magichit gate: an OR run binds tighter than AND, Subject reads the one hit
// and Target the caster, an Is/Has function reads as a boolean, an AV parameter by its name, and a
// form by its editor id. A keyword dispel runs after the gate passes.
@(test)
test_magic_translate_land :: proc(t: ^testing.T) {
	src: magictranslate.Source
	src.edids = make(map[gamedb.Form_ID]string, context.temp_allocator)
	src.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	src.edids[0x13794] = "ActorTypeUndead"
	src.db.form_by_edid["actortypeundead"] = 0x13794
	undead, _ := esm.condition_function_by_name("IsUndead")
	keyword, _ := esm.condition_function_by_name("HasKeyword")
	percent, _ := esm.condition_function_by_name("GetActorValuePercent")
	conds := []gamedb.Condition {
		{function = undead, op = .Equal, value = 1, flags = {.Or}},
		{function = keyword, op = .NotEqual, value = 0, param1 = 0x13794},
		{function = percent, op = .Less, value = 0.2, param1 = 24, run_on = .Target},
		{function = undead, op = .Equal, value = 0},
	}
	text, ok := magictranslate.land_lua(&src, conds, nil)
	testing.expect(t, ok, "every condition has a Lua form")
	testing.expect_value(t, text, `  hooks = {
    magichit = function(e)
      return (e.target:IsUndead() or e.target:HasKeyword("ActorTypeUndead"))
        and e.actor:GetActorValuePercent("Health") < 0.2
        and not e.target:IsUndead()
    end,
  },
`)
	gated, _ := magictranslate.land_lua(&src, conds[3:], {"kw.MagicInfluence"})
	testing.expect_value(t, gated, `  hooks = {
    magichit = function(e)
      if not (not e.target:IsUndead()) then return false end
      e.target:DispelTagged("kw.MagicInfluence")
    end,
  },
`)
}

// A potion becomes an rt.item on its record, its effects named with their numbers, a poison tagged.
@(test)
test_magic_translate_item :: proc(t: ^testing.T) {
	src: magictranslate.Source
	src.files = make(map[u32]string, context.temp_allocator)
	src.edids = make(map[gamedb.Form_ID]string, context.temp_allocator)
	src.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	src.files[0] = "Skyrim.esm"
	src.edids[0x73F38] = "DamageHealthLinger05"
	src.edids[0x3EB42] = "AlchDamageHealthDuration"
	src.db.form_by_edid["alchdamagehealthduration"] = 0x3EB42
	effects := []gamedb.Magic_Effect_Ref{{effect = 0x3EB42, magnitude = 3, duration = 20}}
	testing.expect_value(t, magictranslate.item_lua(&src, 0x73F38, "ALCH", effects, true), `-- Skyrim.esm ALCH DamageHealthLinger05
local rt = require('skymod.rt')
return rt.item {
  form = "Skyrim.esm:073F38",
  tags = { "poison" },
  applies = {
    { "AlchDamageHealthDuration", m = 3, d = "20s" },
  },
}
`)
}

// A perk chain becomes one rt.perk: each entry gated on the owner's rank, a HasPerk(<next rank>) == 0
// becoming the rank's top, its tabs' conditions on their refs, its function on its part, a hit
// spell as h.apply. An entry gated on a condition with no body yet (IsAttackType) is left out.
@(test)
test_magic_translate_perk :: proc(t: ^testing.T) {
	src: magictranslate.Source
	src.files = make(map[u32]string, context.temp_allocator)
	src.edids = make(map[gamedb.Form_ID]string, context.temp_allocator)
	src.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	src.db.perks = make(map[gamedb.Form_ID]gamedb.Perk, context.temp_allocator)
	src.files[0] = "Skyrim.esm"
	RANK1, RANK2, SWORD, BLEED :: gamedb.Form_ID(0xBABE4), gamedb.Form_ID(0x79342), gamedb.Form_ID(0x1E711), gamedb.Form_ID(0x3AF9B)
	for n in ([?]struct {f: gamedb.Form_ID, e: string}{{RANK1, "Armsman00"}, {RANK2, "Armsman20"}, {SWORD, "WeapTypeSword"}, {BLEED, "PerkBleedingSwordIron25"}}) {
		src.edids[n.f] = n.e
		src.db.form_by_edid[strings.to_lower(n.e, context.temp_allocator)] = n.f
	}
	has_perk, _ := esm.condition_function_by_name("HasPerk")
	keyword, _ := esm.condition_function_by_name("HasKeyword")
	attack_type, _ := esm.condition_function_by_name("IsAttackType")
	sword := []gamedb.Perk_Tab{{tab = 1, conditions = {{function = keyword, op = .Equal, value = 1, param1 = u64(SWORD)}}}}
	src.db.perks[RANK1] = {next_rank = RANK2, entries = {{
		kind = .Entry_Point, point = .Mod_Attack_Damage, function = .Multiply_Value, values = {1.2, 0},
		tabs = {{tab = 0, conditions = {{function = has_perk, op = .Equal, value = 0, param1 = u64(RANK2)}}}, sword[0]},
	}}}
	src.db.perks[RANK2] = {entries = {
		{kind = .Entry_Point, point = .Mod_Attack_Damage, function = .Multiply_Value, values = {1.4, 0}, tabs = sword},
		{kind = .Entry_Point, point = .Mod_Armor_Rating, function = .Set_Value, values = {0, 0}},
		{kind = .Entry_Point, point = .Mod_Power_Attack_Stamina, function = .Multiply_Value, values = {0.75, 0}},
		{kind = .Entry_Point, point = .Apply_Combat_Hit_Spell, function = .Select_Spell, form = BLEED},
		{kind = .Entry_Point, point = .Mod_Attack_Damage, function = .Multiply_Value, values = {3, 0}, tabs = {{tab = 0, conditions = {{function = attack_type, op = .Equal, value = 1}}}}},
	}}
	testing.expect(t, magictranslate.perk_chain(&src, RANK2) == nil, "a later rank heads no chain")
	text, ok := magictranslate.perk_lua(&src, magictranslate.perk_chain(&src, RANK1))
	testing.expect(t, ok, "every entry has a Lua form")
	testing.expect_value(t, text, `-- Skyrim.esm PERK Armsman00
local rt = require('skymod.rt')

local function cost(c)
  if c.actor.av.Armsman00.value >= 2 and c.power then c.cost.mult = c.cost.mult * 0.75 end
end

local function hit(h)
  if h.actor.av.Armsman00.value == 1 and h.source and h.source:HasKeyword("WeapTypeSword") then h.damage.mult = h.damage.mult * 1.2 end
  if h.actor.av.Armsman00.value >= 2 and h.source and h.source:HasKeyword("WeapTypeSword") then h.damage.mult = h.damage.mult * 1.4 end
  if h.actor.av.Armsman00.value >= 2 then h.apply("PerkBleedingSwordIron25") end
end

local function armor(a)
  if a.actor.av.Armsman00.value >= 2 then a.rating.set = 0 end
end

return rt.perk {
  ranks = { "Armsman00", "Armsman20" },
  hooks = { meleecost = cost, meleehit = hit, archhit = hit, armorhit = armor },
}
`)
}

// Magic perk entries land in magichit and magiccost hooks: a spell tab's keyword and school tests are
// the effect's tags, its half-cost perk the spell's; a multiplier on magnitude lengthens an effect
// that a boost lengthens (boost), an add stays on m; Mod Incoming runs on the one hit.
@(test)
test_magic_translate_magic_perk :: proc(t: ^testing.T) {
	src: magictranslate.Source
	src.files = make(map[u32]string, context.temp_allocator)
	src.edids = make(map[gamedb.Form_ID]string, context.temp_allocator)
	src.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	src.db.perks = make(map[gamedb.Form_ID]gamedb.Perk, context.temp_allocator)
	src.files[0] = "Skyrim.esm"
	PERK, FIRE :: gamedb.Form_ID(0x581E7), gamedb.Form_ID(0x1CEAD)
	for n in ([?]struct {f: gamedb.Form_ID, e: string}{{PERK, "AugmentedFlames"}, {FIRE, "MagicDamageFire"}}) {
		src.edids[n.f] = n.e
		src.db.form_by_edid[strings.to_lower(n.e, context.temp_allocator)] = n.f
	}
	illusion: u64
	for name, i in esm.AV_NAMES {if name == "Illusion" {illusion = u64(i)}}
	has_kw, _ := esm.condition_function_by_name("EPMagic_SpellHasKeyword")
	has_skill, _ := esm.condition_function_by_name("EPMagic_SpellHasSkill")
	casting, _ := esm.condition_function_by_name("SpellHasCastingPerk")
	src.db.perks[PERK] = {entries = {
		{kind = .Entry_Point, point = .Mod_Spell_Magnitude, function = .Multiply_Value, values = {1.25, 0}, tabs = {{tab = 1, conditions = {{function = has_kw, op = .Equal, value = 1, param1 = u64(FIRE)}}}}},
		{kind = .Entry_Point, point = .Mod_Spell_Magnitude, function = .Add_Value, values = {8, 0}, tabs = {{tab = 1, conditions = {{function = has_skill, op = .Equal, value = 1, param1 = illusion}}}}},
		{kind = .Entry_Point, point = .Mod_Spell_Cost, function = .Multiply_Value, values = {0.5, 0}, tabs = {{tab = 1, conditions = {{function = casting, op = .Equal, value = 1, param1 = u64(PERK)}}}}},
		{kind = .Entry_Point, point = .Mod_Incoming_Spell_Magnitude, function = .Multiply_Value, values = {0.5, 0}},
	}}
	text, ok := magictranslate.perk_lua(&src, magictranslate.perk_chain(&src, PERK))
	testing.expect(t, ok, "every entry has a Lua form")
	testing.expect_value(t, text, `-- Skyrim.esm PERK AugmentedFlames
local rt = require('skymod.rt')

local function cast(c)
  if c.actor.av.AugmentedFlames.value >= 1 and c.source and c.source:HasTag("casting.AugmentedFlames") then c.cost.mult = c.cost.mult * 0.5 end
end

local function effect(e)
  local boost = e.effect:HasTag("power.duration") and e.d or e.m
  if e.actor and e.actor.av.AugmentedFlames.value >= 1 and e.source and e.effect:HasTag("kw.MagicDamageFire") then boost.mult = boost.mult * 1.25 end
  if e.actor and e.actor.av.AugmentedFlames.value >= 1 and e.source and e.effect:HasTag("school.illusion") then e.m.add = e.m.add + 8 end
  if e.target.av.AugmentedFlames.value >= 1 then boost.mult = boost.mult * 0.5 end
end

return rt.perk {
  ranks = { "AugmentedFlames" },
  hooks = { magiccost = cast, magichit = effect },
}
`)
}
