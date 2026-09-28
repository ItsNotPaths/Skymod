package unit_tests

import "core:testing"
import "../../src/gamedb"
import "../../src/worldhost"
import "../../src/worldstate"

// The world a plugin sees answers from worldstate.
@(test)
test_worldhost_answers :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	worldstate.set_awareness(&ws, 0xA1, 0x14, {0.7, true})
	worldstate.av_set_base(&ws, 0xA1, "Health", 80)

	d := worldhost.Data{context, &ws, &db}
	w := worldhost.world(&d)
	testing.expect_value(t, w.player, ws.player)
	a := w.awareness(w.data, 0xA1, 0x14)
	testing.expect(t, a.detected && a.level == 0.7, "awareness")
	testing.expect_value(t, w.actor_value(w.data, 0xA1, "Health", .Base), 80)
	testing.expect_value(t, w.faction_rank(w.data, 0xA1, 0xF1), -1)
	testing.expect(t, !w.hostile(w.data, 0xA1, 0x14) && !w.has_keyword(w.data, 0xA1, 0xE1) && !w.in_list(w.data, 0xE2, 0xA1), "nothing set")
	testing.expect_value(t, w.setting(w.data, "fNoSuchSetting", 3), 3)
}
