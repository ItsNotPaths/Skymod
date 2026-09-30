package unit_tests

// hud.lua: which meters show and how much of their fill, the compass letters in view, the sneak eye,
// the foe bar and the notification feed. worldstate.notify keeps the newest.

import "core:testing"
import lua "../../vendor/lua"
import "../../src/ui"
import ws "../../src/worldstate"

// LAYOUT stands in for the extracted interface/hudmenu_layout.lua: stage rects of the HUD art and
// of the instances hud.lua reads.
@(private = "file")
LAYOUT :: `
local function r(x, y, w, h) return { x = x, y = y, w = w, h = h } end
engine.layout = function() return {
	stage = { w = 1280, h = 720 },
	art = {
		["interface/hud/compass.dds"] = r(458, 58, 364, 27),
		["interface/hud/health_empty.dds"] = r(497, 619, 287, 21), ["interface/hud/health_full.dds"] = r(497, 619, 287, 21),
		["interface/hud/magicka_empty.dds"] = r(120, 615, 288, 23), ["interface/hud/magicka_full.dds"] = r(120, 615, 288, 23),
		["interface/hud/stamina_empty.dds"] = r(873, 615, 288, 23), ["interface/hud/stamina_full.dds"] = r(873, 615, 288, 23),
		["interface/hud/enemy_empty.dds"] = r(509, 84, 262, 34), ["interface/hud/enemy_full.dds"] = r(509, 84, 262, 34),
	},
	instances = {
		["HUDMovieBaseInstance.CompassShoutMeterHolder.Compass.CompassMask_mc"] = { rect = r(494, 43, 291, 60) },
		["HUDMovieBaseInstance.Health.HealthMeter_mc.HealthLeft"] = { rect = r(518, 620, 246, 15), moving = { Full = r(518, 620, 246, 15) } },
		["HUDMovieBaseInstance.Magica.MagickaMeter_mc"] = { rect = r(121, 617, 286, 20), moving = { Full = r(141, 616, 247, 17), Empty = r(-106, 616, 247, 17) } },
		["HUDMovieBaseInstance.EnemyHealth_mc"] = { rect = r(510, 85, 260, 41), moving = { Full = r(510, 85, 260, 13) } },
		["HUDMovieBaseInstance.EnemyHealth_mc.BracketsInstance.RolloverNameInstance"] = { rect = r(564, 94, 151, 31) },
	},
} end
`

@(private = "file")
hud_tree :: proc(vm: ^ui.VM, engine_src: cstring) -> (ui.Node, bool) {
	src := engine_src
	install :: proc(vm: ^ui.VM) {
		lua.L_dostring(vm.L, (^cstring)(vm.user)^)
		lua.L_dostring(vm.L, LAYOUT)
	}
	if !ui.open(vm, "", "hud.lua", &src, install) {return {}, false}
	return ui.frame(vm)
}

@(private = "file")
Found :: struct {
	images: [dynamic]ui.Node,
	texts:  [dynamic]string,
}

@(private = "file")
collect :: proc(n: ^ui.Node, f: ^Found) {
	#partial switch n.kind {
	case .Image: append(&f.images, n^)
	case .Text: append(&f.texts, n.text)
	}
	for &c in n.children {collect(&c, f)}
}

// crop_of is the crop of the drawn image `source`, and whether it was drawn.
@(private = "file")
crop_of :: proc(f: Found, source: string) -> ([2]f32, bool) {
	for n in f.images {if n.image == source {return n.crop, true}}
	return {}, false
}

@(private = "file")
has :: proc(list: []string, s: string) -> bool {
	for x in list {if x == s {return true}}
	return false
}

@(test)
test_hud_full_meters_hidden :: proc(t: ^testing.T) {
	vm: ui.VM
	defer ui.close(&vm)
	tree, ok := hud_tree(&vm, `engine = {
		activation = function() return { present = false } end,
		hud = function() return {
			health = { cur = 100, max = 100 }, magicka = { cur = 50, max = 50 }, stamina = { cur = 80, max = 80 },
			combat = false, heading = 0, notes = {},
		} end,
	}`)
	testing.expect(t, ok)
	defer ui.destroy(&tree)
	f: Found
	defer delete(f.images)
	defer delete(f.texts)
	collect(&tree, &f)
	_, drawn := crop_of(f, "interface/hud/health_empty.dds")
	testing.expect(t, !drawn) // full, out of combat
	_, drawn = crop_of(f, "interface/hud/compass.dds")
	testing.expect(t, drawn)
	testing.expect(t, has(f.texts[:], "N"))
	testing.expect(t, !has(f.texts[:], "S"))
	testing.expect(t, !has(f.texts[:], "HIDDEN")) // not sneaking
}

@(test)
test_hud_hurt_foe_and_notes :: proc(t: ^testing.T) {
	vm: ui.VM
	defer ui.close(&vm)
	tree, ok := hud_tree(&vm, `engine = {
		activation = function() return { present = false } end,
		hud = function() return {
			health = { cur = 40, max = 100 }, magicka = { cur = 50, max = 50 }, stamina = { cur = 80, max = 80 },
			combat = true, heading = 90, sneaking = true, detection = 1, detected = true,
			foe = { name = "Bandit", health = { cur = 10, max = 60 }, age = 10, fighting = true },
			notes = { { text = "old", age = 9 }, { text = "Quest started", age = 1 } },
		} end,
	}`)
	testing.expect(t, ok)
	defer ui.destroy(&tree)
	f: Found
	defer delete(f.images)
	defer delete(f.texts)
	collect(&tree, &f)
	// health at 40%: the chrome, then the full art cropped to the middle 40% of the fill box
	_, chrome := crop_of(f, "interface/hud/health_empty.dds")
	testing.expect(t, chrome)
	crop, fill := crop_of(f, "interface/hud/health_full.dds")
	testing.expect(t, fill)
	testing.expect(t, abs(crop[0] + crop[1] - 1) < 0.02) // centred
	testing.expect(t, abs((crop[1] - crop[0]) * 287 - 0.4 * 246) < 0.5)
	_, foe_bar := crop_of(f, "interface/hud/enemy_full.dds")
	testing.expect(t, foe_bar)
	testing.expect(t, has(f.texts[:], "Bandit"))
	testing.expect(t, has(f.texts[:], "Quest started"))
	testing.expect(t, !has(f.texts[:], "old"))
	testing.expect(t, has(f.texts[:], "DETECTED"))
	testing.expect(t, has(f.texts[:], "E")) // facing east: N and S just out of view, W behind
	testing.expect(t, !has(f.texts[:], "W"))
}

@(test)
test_notify_keeps_newest :: proc(t: ^testing.T) {
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)
	for i in 0 ..< ws.NOTES_KEPT + 2 {ws.notify(&s, i == ws.NOTES_KEPT + 1 ? "last" : "note")}
	testing.expect_value(t, len(s.notes), ws.NOTES_KEPT)
	testing.expect_value(t, s.notes[ws.NOTES_KEPT - 1].text, "last")
}
