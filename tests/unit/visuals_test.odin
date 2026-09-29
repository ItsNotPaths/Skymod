package unit_tests

import "core:os"
import "core:testing"
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
