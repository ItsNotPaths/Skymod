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

// MGEF conditions become the land gate: an OR run binds tighter than AND, Subject reads the one hit
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
	testing.expect_value(t, text, `  land = function(e)
    return (e.target:IsUndead() or e.target:HasKeyword("ActorTypeUndead"))
      and e.actor:GetActorValuePercent("Health") < 0.2
      and not e.target:IsUndead()
  end,
`)
	gated, _ := magictranslate.land_lua(&src, conds[3:], {"kw.MagicInfluence"})
	testing.expect_value(t, gated, `  land = function(e)
    if not (not e.target:IsUndead()) then return false end
    e.target:DispelTagged("kw.MagicInfluence")
  end,
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
// becoming the rank's top, its tabs' conditions on their refs, its function on its part.
@(test)
test_magic_translate_perk :: proc(t: ^testing.T) {
	src: magictranslate.Source
	src.files = make(map[u32]string, context.temp_allocator)
	src.edids = make(map[gamedb.Form_ID]string, context.temp_allocator)
	src.db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	src.db.perks = make(map[gamedb.Form_ID]gamedb.Perk, context.temp_allocator)
	src.files[0] = "Skyrim.esm"
	RANK1, RANK2, SWORD :: gamedb.Form_ID(0xBABE4), gamedb.Form_ID(0x79342), gamedb.Form_ID(0x1E711)
	for n in ([?]struct {f: gamedb.Form_ID, e: string}{{RANK1, "Armsman00"}, {RANK2, "Armsman20"}, {SWORD, "WeapTypeSword"}}) {
		src.edids[n.f] = n.e
		src.db.form_by_edid[strings.to_lower(n.e, context.temp_allocator)] = n.f
	}
	has_perk, _ := esm.condition_function_by_name("HasPerk")
	keyword, _ := esm.condition_function_by_name("HasKeyword")
	sword := []gamedb.Perk_Tab{{tab = 1, conditions = {{function = keyword, op = .Equal, value = 1, param1 = u64(SWORD)}}}}
	src.db.perks[RANK1] = {next_rank = RANK2, entries = {{
		kind = .Entry_Point, point = .Mod_Attack_Damage, function = .Multiply_Value, values = {1.2, 0},
		tabs = {{tab = 0, conditions = {{function = has_perk, op = .Equal, value = 0, param1 = u64(RANK2)}}}, sword[0]},
	}}}
	src.db.perks[RANK2] = {entries = {
		{kind = .Entry_Point, point = .Mod_Attack_Damage, function = .Multiply_Value, values = {1.4, 0}, tabs = sword},
		{kind = .Entry_Point, point = .Mod_Armor_Rating, function = .Set_Value, values = {0, 0}},
		{kind = .Entry_Point, point = .Mod_Power_Attack_Stamina, function = .Multiply_Value, values = {0.75, 0}},
	}}
	testing.expect(t, magictranslate.perk_chain(&src, RANK2) == nil, "a later rank heads no chain")
	text, ok := magictranslate.perk_lua(&src, magictranslate.perk_chain(&src, RANK1))
	testing.expect(t, ok, "every entry has a Lua form")
	testing.expect_value(t, text, `-- Skyrim.esm PERK Armsman00
local rt = require('skymod.rt')
return rt.perk {
  ranks = { "Armsman00", "Armsman20" },
  hooks = {
    swing = function(s)
      if s.actor.av.Armsman00.value >= 2 and s.power then s.cost.mult = s.cost.mult * 0.75 end
    end,
    hit = function(h)
      if h.actor.av.Armsman00.value == 1 and h.source and h.source:HasKeyword("WeapTypeSword") then h.damage.mult = h.damage.mult * 1.2 end
      if h.actor.av.Armsman00.value >= 2 and h.source and h.source:HasKeyword("WeapTypeSword") then h.damage.mult = h.damage.mult * 1.4 end
    end,
    armor = function(a)
      if a.actor.av.Armsman00.value >= 2 then a.rating.set = 0 end
    end,
  },
}
`)
}
