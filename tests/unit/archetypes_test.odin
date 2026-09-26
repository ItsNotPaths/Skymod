package unit_tests

import "core:math"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"

// The engine archetypes as terms: a Recover fortify holds capacity while it runs, fire's taper
// adds its linger, a dual modifier moves the second AV by its weight, Absorb moves health to the
// caster, and an unrecovered timed modifier adds its magnitude each second.
@(test)
test_effect_archetypes :: proc(t: ^testing.T) {
	TARGET, CASTER :: gamedb.Form_ID(0x700), gamedb.Form_ID(0x701)
	FORTIFY, FIRE, SHOCK, ABSORB, RESTORE :: gamedb.Form_ID(0x901), gamedb.Form_ID(0x902), gamedb.Form_ID(0x903), gamedb.Form_ID(0x904), gamedb.Form_ID(0x905)
	HEALTH, MAGICKA :: i32(24), i32(25)
	harm :: esm.MGEF_DETRIMENTAL
	db: gamedb.DB
	db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	db.magic_effects[FORTIFY] = {info = {archetype = .Peak_Value_Modifier, flags = esm.MGEF_RECOVER, primary_av = HEALTH}}
	db.magic_effects[FIRE] = {info = {archetype = .Value_Modifier, flags = harm, primary_av = HEALTH, taper_weight = 0.3, taper_curve = 2, taper_duration = 1}}
	db.magic_effects[SHOCK] = {info = {archetype = .Dual_Value_Modifier, flags = harm, primary_av = HEALTH, second_av = MAGICKA, second_av_weight = 0.5}}
	db.magic_effects[ABSORB] = {info = {archetype = .Absorb, flags = harm, primary_av = HEALTH}}
	db.magic_effects[RESTORE] = {info = {archetype = .Value_Modifier, primary_av = MAGICKA}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	for a in ([]gamedb.Form_ID{TARGET, CASTER}) {
		worldstate.av_set_base(&ws, a, "Health", 100)
		worldstate.av_set_base(&ws, a, "Magicka", 100)
	}
	health :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, a: gamedb.Form_ID) -> f32 {return worldstate.av_current(ws, db, a, "Health")}
	run :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, h: gamedb.Form_ID, seconds: int) {
		for _ in 0 ..< seconds * 4 {worldstate.advance_effect(ws, db, h, 0.25)}
	}

	fort := worldstate.start_effect(&ws, {effect = FORTIFY, target = TARGET, caster = TARGET, duration = 2, magnitude = 50})
	run(&ws, &db, fort, 1)
	testing.expect_value(t, worldstate.av_max(&ws, &db, TARGET, "Health"), 150)
	run(&ws, &db, fort, 2)
	testing.expect_value(t, worldstate.av_max(&ws, &db, TARGET, "Health"), 100)

	fire := worldstate.start_effect(&ws, {effect = FIRE, target = TARGET, caster = CASTER, taper = 1, magnitude = 30})
	run(&ws, &db, fire, 2)
	testing.expect(t, math.abs(health(&ws, &db, TARGET) - 67) < 0.01, "30 at once, then 30 * 0.3 * 1 / 3 over the linger") // 100 - 33

	worldstate.av_restore(&ws, TARGET, "Health", 100)
	shock := worldstate.start_effect(&ws, {effect = SHOCK, target = TARGET, caster = CASTER, magnitude = 20})
	run(&ws, &db, shock, 1)
	testing.expect_value(t, health(&ws, &db, TARGET), 80)
	testing.expect_value(t, worldstate.av_current(&ws, &db, TARGET, "Magicka"), 90)

	worldstate.av_damage(&ws, &db, CASTER, "Health", 40)
	absorb := worldstate.start_effect(&ws, {effect = ABSORB, target = TARGET, caster = CASTER, magnitude = 15})
	run(&ws, &db, absorb, 1)
	testing.expect_value(t, health(&ws, &db, TARGET), 65)
	testing.expect_value(t, health(&ws, &db, CASTER), 75)

	restore := worldstate.start_effect(&ws, {effect = RESTORE, target = TARGET, caster = TARGET, duration = 2, magnitude = 3})
	run(&ws, &db, restore, 3)
	testing.expect_value(t, worldstate.av_current(&ws, &db, TARGET, "Magicka"), 96)
}
