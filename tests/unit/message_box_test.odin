package unit_tests

// message_box.lua: each label is a button, a pick hands back its index, no labels gets one button.

import "core:testing"
import lua "../../vendor/lua"
import "../../src/ui"

@(private = "file")
open_box :: proc(vm: ^ui.VM, engine_src: cstring) -> bool {
	src := engine_src
	install :: proc(vm: ^ui.VM) {lua.L_dostring(vm.L, (^cstring)(vm.user)^)}
	return ui.open(vm, "", "message_box.lua", &src, install)
}

@(private = "file")
box_buttons :: proc(vm: ^ui.VM) -> (actions: [dynamic]string, tree: ui.Node) {
	tree, _ = ui.frame(vm)
	ui.measure(&tree)
	tree.screen = ui.Rect{0, 0, 1280, 720}
	ui.layout_children(&tree)
	fs: [dynamic]ui.Focusable
	defer delete(fs)
	ui.collect_focusables(ui.focus_root(&tree), &fs)
	for f in fs {append(&actions, f.action)}
	return
}

@(test)
test_message_box_pick :: proc(t: ^testing.T) {
	vm: ui.VM
	ok := open_box(&vm, `engine = { message_box = function() return { body = "Read it?", buttons = { "Yes", "No", "Later" } } end }`)
	testing.expect(t, ok)
	defer ui.close(&vm)

	actions, tree := box_buttons(&vm)
	defer ui.destroy(&tree)
	defer delete(actions)
	testing.expect_value(t, len(actions), 3)
	if len(actions) == 3 {
		ui.dispatch(&vm, actions[1])
		verb, picked := ui.take_result(&vm)
		testing.expect(t, picked)
		testing.expect_value(t, verb, "1")
	}
}

@(test)
test_message_box_default_button :: proc(t: ^testing.T) {
	vm: ui.VM
	ok := open_box(&vm, `engine = { message_box = function() return { body = "You feel rested.", buttons = {} } end }`)
	testing.expect(t, ok)
	defer ui.close(&vm)

	actions, tree := box_buttons(&vm)
	defer ui.destroy(&tree)
	defer delete(actions)
	testing.expect_value(t, len(actions), 1)
	if len(actions) == 1 {
		ui.dispatch(&vm, actions[0])
		verb, _ := ui.take_result(&vm)
		testing.expect_value(t, verb, "0")
	}
}
