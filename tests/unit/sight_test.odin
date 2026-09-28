package unit_tests

import "core:testing"
import "../../src/plugin"
import "../../src/sight"

// Fake_Sight: an NPC 0xA1 at the origin facing +y, a target 0xB1 100 units ahead or behind, and
// whatever one ray crosses.
Fake_Sight :: struct {
	behind: bool,
	hits:   []sight.Hit,
}

fake_sight_host :: proc(f: ^Fake_Sight) -> sight.Host {
	return {
		data = f,
		player = 0x14,
		space = true,
		body = proc "c" (data: rawptr, ref: sight.Form_ID) -> sight.Body {
			f := (^Fake_Sight)(data)
			y := f32(-100) if f.behind else 100
			return {loaded = true, actor = true, pos = {0, y if ref == 0xB1 else 0, 0}, hi = 128}
		},
		hits = proc "c" (data: rawptr, ray: sight.Ray, out: [^]sight.Hit, cap: int) -> int {
			f := (^Fake_Sight)(data)
			for h, i in f.hits {out[i] = h}
			return len(f.hits)
		},
		setting = proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32 {return fallback},
		awareness = proc "c" (data: rawptr, viewer, target: sight.Form_ID) -> f32 {return 0.25},
	}
}

@(test)
test_sight_model :: proc(t: ^testing.T) {
	f := Fake_Sight{hits = {{owner = 0xB1}}}
	h := fake_sight_host(&f)
	tb := sight.BUILTIN
	testing.expect_value(t, tb.level(&h, 0xA1, 0xB1, .Cone), 1)
	f.hits = {{cutout = true}, {owner = 0xB1}}
	testing.expect_value(t, tb.level(&h, 0xA1, 0xB1, .Raw), 1 - sight.CUTOUT_COVER) // a cutout dims
	f.hits = {{}, {owner = 0xB1}}
	testing.expect(t, !tb.has_los(&h, 0xA1, 0xB1), "a solid blocks")
	f = {behind = true, hits = {{owner = 0xB1}}}
	testing.expect_value(t, tb.level(&h, 0xA1, 0xB1, .Cone), 0) // outside the view cone
	testing.expect_value(t, tb.level(&h, 0xA1, 0xB1, .Raw), 1)
	testing.expect_value(t, tb.level(&h, 0xA1, 0xB1, .Detect), 0.25)
	testing.expect_value(t, tb.range(&h, 0xA1), 2500 * 2.1) // outdoors
}

// A plugin that replaces level changes what callers see; has_los stays the built-in.
@(test)
test_sight_plugin :: proc(t: ^testing.T) {
	p: plugin.Plugins
	defer plugin.destroy(&p)
	plugin.load(&p, {TEST_PLUGINS})
	tb := sight.BUILTIN
	plugin.apply(&p, sight.SEAM, sight.VERSION, &tb)
	f := Fake_Sight{hits = {{owner = 0xB1}}}
	h := fake_sight_host(&f)
	testing.expect_value(t, tb.level(&h, 0xA1, 0xB1, .Raw), 0)
	testing.expect(t, tb.has_los(&h, 0xA1, 0xB1), "has_los is still the built-in")
}
