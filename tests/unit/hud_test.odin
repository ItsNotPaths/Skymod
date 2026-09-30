package unit_tests

// hud.lua: which meters show, their chrome and fill, the compass letters in view, the sneak eye,
// the foe bar and the notification feed. worldstate.notify keeps the newest.

import "core:testing"
import lua "../../vendor/lua"
import "../../src/ui"
import ws "../../src/worldstate"

// LAYOUT stands in for the extracted interface/hudmenu_layout.lua: stage rects of the compass art and
// of the instances hud.lua reads.
@(private = "file")
LAYOUT :: `
local function r(x, y, w, h) return { x = x, y = y, w = w, h = h } end
engine.layout = function() return {
	stage = { w = 1280, h = 720 },
	art = {
		["interface/hud/compass.dds"] = r(458, 58, 364, 27),
	},
	instances = {
		["HUDMovieBaseInstance.CompassShoutMeterHolder.Compass.CompassMask_mc"] = { rect = r(494, 43, 291, 60) },
		["HUDMovieBaseInstance.Health.HealthMeter_mc.HealthLeft"] = { rect = r(518, 620, 246, 15), moving = { Full = r(518, 620, 246, 15) } },
		["HUDMovieBaseInstance.Magica.MagickaMeter_mc"] = { rect = r(121, 617, 286, 20), moving = { Full = r(141, 616, 247, 17), Empty = r(141, 616, 0.4, 12) } },
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
	images: [dynamic]string,
	bars:   [dynamic]ui.Node,
	texts:  [dynamic]string,
}

@(private = "file")
collect :: proc(n: ^ui.Node, f: ^Found) {
	#partial switch n.kind {
	case .Image: append(&f.images, n.image)
	case .Bar:   append(&f.bars, n^)
	case .Text: append(&f.texts, n.text)
	}
	for &c in n.children {collect(&c, f)}
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
	defer delete(f.bars)
	defer delete(f.texts)
	collect(&tree, &f)
	testing.expect(t, !has(f.images[:], "interface/hud/meter.dds")) // all full, out of combat
	testing.expect_value(t, len(f.bars), 0)
	testing.expect(t, has(f.images[:], "interface/hud/compass.dds"))
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
	defer delete(f.bars)
	defer delete(f.texts)
	collect(&tree, &f)
	// health at 40% and the foe at 1/6: each its chrome and a bar fill growing from the centre
	testing.expect(t, has(f.images[:], "interface/hud/meter.dds"))
	testing.expect(t, has(f.images[:], "interface/hud/enemy.dds"))
	testing.expect_value(t, len(f.bars), 2)
	for b in f.bars {testing.expect_value(t, b.from, ui.Align.Center)}
	if len(f.bars) == 2 {testing.expect_value(t, f.bars[0].value, 0.4)}
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
