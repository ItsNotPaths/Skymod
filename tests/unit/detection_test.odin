package unit_tests

import "base:runtime"
import "core:os"
import "core:testing"
import "../../src/detection"
import "../../src/plugin"
import "../../src/worldstate"

// The stub model: seen = detected at once; out of sight it fades and is lost after a while.
@(test)
test_detection_stub_model :: proc(t: ^testing.T) {
	judge := detection.BUILTIN.judge
	a := judge({}, {sight = 1 / 3.0}, 0.1)
	testing.expect_value(t, a, detection.Awareness{1, true})
	a = judge(a, {}, 1)
	testing.expect(t, a.detected && a.level < 1, "fading, still detected")
	a = judge(a, {}, 10)
	testing.expect_value(t, a, detection.Awareness{})
}

// Fake_Host sees everything in range and keeps what detection sets.
Fake_Host :: struct {
	world: plugin.World,
	ctx:  runtime.Context,
	sets: [dynamic]detection.Pair,
}

fake_host :: proc(h: ^Fake_Host) -> detection.Host {
	h.world = fake_world(h)
	return {
		&h.world,
		h,
		proc "c" (data: rawptr, viewer, target: detection.Form_ID) -> f32 {return 1},
		proc "c" (data: rawptr, viewer: detection.Form_ID) -> f32 {return 1000},
		proc "c" (data: rawptr, target: detection.Form_ID) -> f32 {return 1},
		proc "c" (data: rawptr, p: detection.Pair) {
			h := (^Fake_Host)(data)
			context = h.ctx
			append(&h.sets, p)
		},
	}
}

// detect runs one tick in which viewer 0xA2 (its group's turn at tick 6) looks at the player.
detect :: proc(t: ^testing.T, table: ^detection.Table, known: []detection.Pair, player_space: detection.Form_ID) -> []detection.Pair {
	h := Fake_Host{ctx = context, sets = make([dynamic]detection.Pair, context.temp_allocator)}
	actors := []plugin.Actor{{id = 0xA2, space = 1}, {id = 0x14, space = player_space, pos = {100, 0, 0}}}
	inp := detection.Input {
		host   = fake_host(&h),
		table  = table,
		tick   = 6,
		dt     = 1 / 60.0,
		actors = plugin.span(actors),
		known  = plugin.span(known),
	}
	table.tick(&inp)
	return h.sets[:]
}

// A viewer whose turn it is detects a target it sees in range; what it knew of one out of its
// space fades.
@(test)
test_detection_tick :: proc(t: ^testing.T) {
	table := detection.BUILTIN
	sets := detect(t, &table, {}, 1)
	testing.expect_value(t, len(sets), 1)
	testing.expect_value(t, sets[0], detection.Pair{0xA2, 0x14, {1, true}})

	sets = detect(t, &table, {{0xA2, 0x14, {1, true}}}, 2)
	testing.expect_value(t, len(sets), 1)
	testing.expect(t, sets[0].awareness.level < 1, "fades out of its space")

	sets = detect(t, &table, {{0xA2, 0x14, {0.5, true}}}, 1)
	testing.expect_value(t, len(sets), 2)
	testing.expect_value(t, sets[1], detection.Pair{0xA2, 0x14, {1, true}}) // the look, after the fade
}

// A plugin that replaces judge changes what the built-in tick sets.
@(test)
test_detection_plugin_judge :: proc(t: ^testing.T) {
	p: plugin.Plugins
	defer plugin.destroy(&p)
	load_test_plugins(&p)
	table := detection.BUILTIN
	plugin.apply(&p, detection.SEAM, detection.VERSION, &table)
	sets := detect(t, &table, {}, 1)
	testing.expect_value(t, len(sets), 1)
	testing.expect_value(t, sets[0].awareness, detection.Awareness{})
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
