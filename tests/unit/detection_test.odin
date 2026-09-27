package unit_tests

import "core:os"
import "core:testing"
import "../../src/detection"
import "../../src/worldstate"

// The stub model: seen = detected at once; out of sight it fades and is lost after a while.
@(test)
test_detection_stub_model :: proc(t: ^testing.T) {
	a := detection.judge({}, {sight = 1 / 3.0}, 0.1)
	testing.expect_value(t, a, worldstate.Awareness{1, true})
	a = detection.judge(a, {}, 1)
	testing.expect(t, a.detected && a.level < 1, "fading, still detected")
	a = detection.judge(a, {}, 10)
	testing.expect_value(t, a, worldstate.Awareness{})
}

// Awareness is saved per viewer and target; a pair that knows nothing is not stored.
@(test)
test_awareness_saved :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	worldstate.set_awareness(&ws, 0xA1, 0x14, {0.7, true})
	worldstate.set_awareness(&ws, 0xA2, 0x14, {})
	testing.expect_value(t, len(ws.awareness), 1)

	path := "test_awareness.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect(t, worldstate.detected(&ws, 0xA1, 0x14), "the viewer still detects the player")
	testing.expect(t, !worldstate.detected(&ws, 0x14, 0xA1), "awareness is one way")
}
