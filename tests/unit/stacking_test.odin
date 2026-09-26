package unit_tests

import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"

// Skyrim's stacking: a timed spell cast again replaces itself, the strongest timed potion of an
// effect wins, Peak Value Modifiers sharing a keyword keep the larger, a keyword dispel ends the
// matching spells, and instant effects always stack.
@(test)
test_effect_stacking :: proc(t: ^testing.T) {
	A :: gamedb.Form_ID(0x700)
	SPELL, OTHER, WEAK, STRONG :: gamedb.Form_ID(0x800), gamedb.Form_ID(0x801), gamedb.Form_ID(0x810), gamedb.Form_ID(0x811)
	PLAIN, PEAK, DISPEL, KW :: gamedb.Form_ID(0x900), gamedb.Form_ID(0x901), gamedb.Form_ID(0x902), gamedb.Form_ID(0x950)
	db: gamedb.DB
	db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	db.spells[SPELL] = {}
	db.spells[OTHER] = {}
	db.potions = make(map[gamedb.Form_ID]gamedb.Potion, context.temp_allocator)
	db.potions[WEAK] = {}
	db.potions[STRONG] = {}
	db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	db.magic_effects[PLAIN] = {}
	db.magic_effects[PEAK] = {info = {archetype = .Peak_Value_Modifier}, related = KW}
	db.magic_effects[DISPEL] = {info = {flags = esm.MGEF_DISPEL_WITH_KEYWORDS}}
	db.keywords = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.keywords[PLAIN] = {KW}
	db.keywords[DISPEL] = {KW}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	start :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, e: worldstate.Active_Effect) -> gamedb.Form_ID {
		if !worldstate.stack_effect(ws, db, e) {return 0}
		return worldstate.start_effect(ws, e)
	}
	live :: proc(ws: ^worldstate.World_State, h: gamedb.Form_ID) -> bool {return h != 0 && !ws.effects[h].ended}

	first := start(&ws, &db, {effect = PLAIN, spell = SPELL, target = A, duration = 10})
	other := start(&ws, &db, {effect = PLAIN, spell = OTHER, target = A, duration = 10})
	again := start(&ws, &db, {effect = PLAIN, spell = SPELL, target = A, duration = 10})
	testing.expect(t, !live(&ws, first) && live(&ws, other) && live(&ws, again), "a recast replaces itself; another spell adds")

	strong := start(&ws, &db, {effect = PLAIN, spell = STRONG, target = A, duration = 10, magnitude = 20})
	weak := start(&ws, &db, {effect = PLAIN, spell = WEAK, target = A, duration = 10, magnitude = 10})
	testing.expect(t, live(&ws, strong) && !live(&ws, weak), "the strongest potion wins")
	i1 := start(&ws, &db, {effect = PLAIN, spell = WEAK, target = A, magnitude = 5})
	i2 := start(&ws, &db, {effect = PLAIN, spell = WEAK, target = A, magnitude = 5})
	testing.expect(t, live(&ws, i1) && live(&ws, i2), "instant potions stack")

	big := start(&ws, &db, {effect = PEAK, spell = SPELL, target = A, lasts = true, magnitude = 50})
	small := start(&ws, &db, {effect = PEAK, spell = OTHER, target = A, lasts = true, magnitude = 30})
	testing.expect(t, live(&ws, big) && !live(&ws, small), "a PVM keeps the larger")

	start(&ws, &db, {effect = DISPEL, spell = OTHER, target = A})
	testing.expect(t, !live(&ws, other) && !live(&ws, again), "a keyword dispel ends the matching spells")
}
