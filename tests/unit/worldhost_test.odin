package unit_tests

import "core:os"
import "core:slice"
import "core:strings"
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
	testing.expect_value(t, w.actor_value(w.data, 0xA1, "Health", .Capacity), 80)
	testing.expect_value(t, w.faction_rank(w.data, 0xA1, 0xF1), -1)
	testing.expect(t, !w.hostile(w.data, 0xA1, 0x14) && !w.has_keyword(w.data, 0xA1, 0xE1) && !w.in_list(w.data, 0xE2, 0xA1), "nothing set")
	testing.expect_value(t, w.setting(w.data, "fNoSuchSetting", 3), 3)
}

// Plugins' saved data goes through the save file by plugin ID.
@(test)
test_plugin_blobs_saved :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ws.plugin_blobs[strings.clone("a.1")] = slice.clone([]u8{9, 8})
	path := "test_plugin_blobs.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect(t, slice.equal(ws.plugin_blobs["a.1"], []u8{9, 8}), "the blob is back")
}
