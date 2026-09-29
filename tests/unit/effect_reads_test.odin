package unit_tests

import "core:testing"
import "../../src/conditions"
import "../../src/gamedb"
import "../../src/worldstate"

_ :: conditions // links worldstate.condition_call

// Effect formulas read actor values, perk ranks, Level and condition functions by name. A term that reads the
// AV it feeds gets it without the terms still being summed (iEffectRecursionDepth 1).
@(test)
test_effect_reads :: proc(t: ^testing.T) {
	TARGET, CASTER :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	FX, PERK, RANK1, RANK2 :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x902), gamedb.Form_ID(0x903), gamedb.Form_ID(0x904)
	db: gamedb.DB
	db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	db.magic_effects[FX] = {info = {archetype = .Value_Modifier}}
	db.form_by_edid = make(map[string]gamedb.Form_ID, context.temp_allocator)
	db.form_by_edid["testperk"] = PERK
	db.form_by_edid["armsman00"] = RANK1
	db.perks = make(map[gamedb.Form_ID]gamedb.Perk, context.temp_allocator)
	db.perks[PERK] = {}
	db.perks[RANK1] = {next_rank = RANK2}
	db.perks[RANK2] = {}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.set_effect_class(&ws, &db, "archetypevaluemodifier", {
		{av = "Health", knob = .Capacity, src = "0.1 * target.av.Health.value"},
		{av = "Magicka", knob = .Capacity, src = "m * caster:HasPerk(\"TestPerk\") + (caster.av.Stamina.value >= 50)"},
		{av = "CarryWeight", knob = .Capacity, src = "10 * target.av.Armsman00.value + target.av.Armsman00.capacity"},
		{av = "Stamina", knob = .Capacity, src = "nobody.av.Health.value"}, // dropped: unknown subject
		{av = "Stamina", knob = .Capacity, src = "caster:HasPerk(\"NoSuchPerk\")"}, // dropped: unknown form
		{av = "Stamina", knob = .Capacity, src = "target.Health"}, // dropped: not av.<Name>.<part>
	}, true, true)
	testing.expect_value(t, len(ws.effect_classes["archetypevaluemodifier"].terms), 3)

	worldstate.av_set_base(&ws, TARGET, "Health", 100)
	worldstate.av_set_base(&ws, CASTER, "Stamina", 50)
	worldstate.start_effect(&ws, {effect = FX, target = TARGET, caster = CASTER, lasts = true, magnitude = 5})
	testing.expect_value(t, worldstate.av_max(&ws, &db, TARGET, "Health"), 110)
	testing.expect_value(t, worldstate.av_max(&ws, &db, TARGET, "Magicka"), 1)
	worldstate.perk_add(&ws, CASTER, PERK)
	testing.expect_value(t, worldstate.av_max(&ws, &db, TARGET, "Magicka"), 6)
	worldstate.perk_add(&ws, TARGET, RANK1)
	worldstate.perk_add(&ws, TARGET, RANK2)
	testing.expect_value(t, worldstate.av_current(&ws, &db, TARGET, "CarryWeight"), 22) // rank 2, a chain of 2
	testing.expect_value(t, len(ws.summing), 0)
}
