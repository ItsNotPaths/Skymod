package unit_tests

import "core:testing"
import "../../src/formats/esm"
import "../../src/formid"
import "../../src/gamedb"
import "../../src/worldstate"

// Resist Magic, then the effect's own resist, multiply; only Hostile effects; the player caps at
// fPlayerMaxResistance, an NPC can be immune; a weakness strengthens; a Poison spell uses
// PoisonResist; a spell can ignore resistance.
@(test)
test_effect_resistance :: proc(t: ^testing.T) {
	NPC :: gamedb.Form_ID(0x700)
	FIRE, BUFF, BOLT, IGNORING, VENOM :: gamedb.Form_ID(0x901), gamedb.Form_ID(0x902), gamedb.Form_ID(0x800), gamedb.Form_ID(0x801), gamedb.Form_ID(0x802)
	FIRE_RESIST :: i32(41)
	testing.expect_value(t, esm.AV_NAMES[FIRE_RESIST], "FireResist")
	db: gamedb.DB
	db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	db.magic_effects[FIRE] = {info = {flags = esm.MGEF_HOSTILE, resist_av = FIRE_RESIST}}
	db.magic_effects[BUFF] = {info = {resist_av = FIRE_RESIST}}
	db.spells = make(map[gamedb.Form_ID]gamedb.Spell, context.temp_allocator)
	db.spells[BOLT] = {}
	db.spells[IGNORING] = {info = {flags = esm.SPELL_IGNORE_RESISTANCE}}
	db.spells[VENOM] = {info = {type = .Poison}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	for a in ([]gamedb.Form_ID{NPC, ws.player}) {
		worldstate.av_set_base(&ws, a, "MagicResist", 50)
		worldstate.av_set_base(&ws, a, "FireResist", 50)
		worldstate.av_set_base(&ws, a, "PoisonResist", -50)
	}

	testing.expect_value(t, worldstate.resisted(&ws, &db, BOLT, FIRE, NPC, 100), 25)
	testing.expect_value(t, worldstate.resisted(&ws, &db, BOLT, BUFF, NPC, 100), 100)
	testing.expect_value(t, worldstate.resisted(&ws, &db, IGNORING, FIRE, NPC, 100), 100)
	testing.expect_value(t, worldstate.resisted(&ws, &db, VENOM, FIRE, NPC, 100), 150)

	worldstate.av_set_base(&ws, NPC, "FireResist", 120)
	worldstate.av_set_base(&ws, ws.player, "FireResist", 120)
	testing.expect_value(t, worldstate.resisted(&ws, &db, BOLT, FIRE, NPC, 100), 0)
	testing.expect(t, abs(worldstate.resisted(&ws, &db, BOLT, FIRE, ws.player, 100) - 7.5) < 1e-4, "the player caps at 85")
}
