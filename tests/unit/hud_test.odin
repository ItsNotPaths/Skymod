package unit_tests

// hud.lua: which meters show, the foe bar and the notification feed. worldstate.notify keeps the newest.

import "core:testing"
import lua "../../vendor/lua"
import "../../src/ui"
import ws "../../src/worldstate"

@(private = "file")
hud_tree :: proc(vm: ^ui.VM, engine_src: cstring) -> (ui.Node, bool) {
	src := engine_src
	install :: proc(vm: ^ui.VM) {lua.L_dostring(vm.L, (^cstring)(vm.user)^)}
	if !ui.open(vm, "", "hud.lua", &src, install) {return {}, false}
	return ui.frame(vm)
}

@(private = "file")
Found :: struct {
	bars:  [dynamic]ui.Align, // each bar fill's `from`
	texts: [dynamic]string,
}

@(private = "file")
collect :: proc(n: ^ui.Node, f: ^Found) {
	#partial switch n.kind {
	case .Bar:  append(&f.bars, n.from)
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
			combat = false, notes = {},
		} end,
	}`)
	testing.expect(t, ok)
	defer ui.destroy(&tree)
	f: Found
	defer delete(f.bars)
	defer delete(f.texts)
	collect(&tree, &f)
	testing.expect_value(t, len(f.bars), 0)
}

@(test)
test_hud_hurt_foe_and_notes :: proc(t: ^testing.T) {
	vm: ui.VM
	defer ui.close(&vm)
	tree, ok := hud_tree(&vm, `engine = {
		activation = function() return { present = false } end,
		hud = function() return {
			health = { cur = 40, max = 100 }, magicka = { cur = 50, max = 50 }, stamina = { cur = 80, max = 80 },
			combat = true,
			foe = { name = "Bandit", health = { cur = 10, max = 60 }, age = 10, fighting = true },
			notes = { { text = "old", age = 9 }, { text = "Quest started", age = 1 } },
		} end,
	}`)
	testing.expect(t, ok)
	defer ui.destroy(&tree)
	f: Found
	defer delete(f.bars)
	defer delete(f.texts)
	collect(&tree, &f)
	testing.expect_value(t, len(f.bars), 2) // the player's health and the foe's
	for b in f.bars {testing.expect_value(t, b, ui.Align.Center)}
	testing.expect(t, has(f.texts[:], "Bandit"))
	testing.expect(t, has(f.texts[:], "Quest started"))
	testing.expect(t, !has(f.texts[:], "old"))
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
