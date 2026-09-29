package unit_tests

import "core:os"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"

// Playing a visual again restarts it under a new handle, a timed one expires, and a save keeps the
// rest under handles never used before.
@(test)
test_visuals :: proc(t: ^testing.T) {
	SHADER :: gamedb.Form_ID(0x30)
	IMPACT :: gamedb.Form_ID(0x31)
	ACTOR :: gamedb.Form_ID(0x40)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	first := worldstate.play_visual(&ws, {kind = .Shader, form = SHADER, ref = ACTOR})
	again := worldstate.play_visual(&ws, {kind = .Shader, form = SHADER, ref = ACTOR})
	testing.expect(t, again != first && first not_in ws.visuals, "a replay restarts")
	worldstate.play_visual(&ws, {kind = .Impact, form = IMPACT, ref = ACTOR, node = "NPC Head", until = 1})

	path := "test_visuals.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect_value(t, len(ws.visuals), 2)
	testing.expect(t, again not_in ws.visuals, "a load gives new handles")
	for h, v in ws.visuals {
		testing.expect(t, h > again, "a handle is never reused")
		if v.kind == .Impact {testing.expect_value(t, v.node, "NPC Head")}
	}

	ws.clock.played = 1
	worldstate.expire_visuals(&ws)
	testing.expect_value(t, len(ws.visuals), 1)
	for _, v in ws.visuals {testing.expect_value(t, v.kind, worldstate.Visual_Kind.Shader)}
}

// A magic effect shows its hit shader on its target while it runs, and its IMAD only on the player,
// for the IMAD's duration. The shader stays while another running effect on the target shows it.
@(test)
test_effect_visuals :: proc(t: ^testing.T) {
	FROST :: gamedb.Form_ID(0x30)
	FROST_SHADER :: gamedb.Form_ID(0x31)
	FROST_IMOD :: gamedb.Form_ID(0x32)
	NPC :: gamedb.Form_ID(0x40)
	db: gamedb.DB
	db.magic_effects = make(map[gamedb.Form_ID]gamedb.Magic_Effect, context.temp_allocator)
	fx: gamedb.Magic_Effect
	fx.art[.Hit_Shader] = FROST_SHADER
	fx.art[.Imod] = FROST_IMOD
	db.magic_effects[FROST] = fx
	db.imods = make(map[gamedb.Form_ID]gamedb.Imod, context.temp_allocator)
	db.imods[FROST_IMOD] = {info = {animatable = true, duration = 3}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ws.player = 0x14

	a := worldstate.start_effect(&ws, {effect = FROST, target = NPC})
	b := worldstate.start_effect(&ws, {effect = FROST, target = NPC})
	for h in ([]gamedb.Form_ID{a, b}) {worldstate.play_effect_visuals(&ws, &db, ws.effects[h])}
	testing.expect_value(t, len(ws.visuals), 1) // the shader; no IMAD off the player

	worldstate.end_effect(&ws, a)
	worldstate.stop_effect_visuals(&ws, &db, a)
	testing.expect_value(t, len(ws.visuals), 1)
	worldstate.end_effect(&ws, b)
	worldstate.stop_effect_visuals(&ws, &db, b)
	testing.expect_value(t, len(ws.visuals), 0)

	worldstate.play_effect_visuals(&ws, &db, {effect = FROST, target = ws.player})
	testing.expect_value(t, len(ws.visuals), 2)
	ws.clock.played = 3
	worldstate.expire_visuals(&ws)
	testing.expect_value(t, len(ws.visuals), 1) // the IMAD played out; the shader lasts with the effect
}

// EFSH DATA decodes by xEdit's field order; a short older block leaves the later fields zero.
@(test)
test_effect_shader_data :: proc(t: ^testing.T) {
	d: [400]u8
	put :: proc(d: []u8, at: int, v: u32) {(^u32le)(&d[at])^ = u32le(v)}
	put(d[:], 56, 0x0005_4192) // edge color 146, 65, 5
	put(d[:], 132, transmute(u32)f32(0.4)) // particle lifetime
	put(d[:], 316, 0x00FF_0000) // fill color key 3: blue
	put(d[:], 384, esm.EFSH_LIGHTING)
	put(d[:], 392, transmute(u32)f32(2)) // fill texture scale v
	e := esm.effect_shader_data(d[:])
	testing.expect_value(t, e.edge.color, [4]u8{146, 65, 5, 0})
	testing.expect_value(t, e.particle.lifetime, 0.4)
	testing.expect_value(t, e.fill.color_keys[2], [4]u8{0, 0, 255, 0})
	testing.expect_value(t, e.flags, u32(esm.EFSH_LIGHTING))
	testing.expect_value(t, e.fill.scale[1], 2)
	short := esm.effect_shader_data(d[:344])
	testing.expect_value(t, short.flags, 0)
	testing.expect_value(t, short.particle.lifetime, 0.4)
}
