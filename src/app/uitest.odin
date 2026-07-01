package main

// --uitest: loads the built-in Lua UI through the substrate VM (framework → screen → ui._frame → node
// tree) and renders it with the imgui-DrawList backend (the dev fallback path — no font atlas, so
// text uses imgui's font). A render-path + Lua-loader smoke test with no install/world. The real
// player menu (SDL3_gpu atlas path + input routing) is run_lua_main_menu, reached from the boot menu.

import "core:log"
import "../platform"
import "../render"
import "../ui"

run_ui_test :: proc() {
	p, ok := platform.init("SkyMod — UI test", WINDOW_W, WINDOW_H)
	if !ok {
		return
	}
	defer platform.shutdown(&p)
	r, rok := render.init(p.window)
	if !rok {
		return
	}
	defer render.shutdown(&r)
	render.ui_init(&r)
	defer render.ui_shutdown(&r)
	p.on_event = render.ui_process_event

	// dir = "" → the #load-embedded framework + screen (no install needed for the smoke test).
	vm: UI_VM
	if !ui_vm_open(&vm, "", nil, "", "main_menu.lua") {
		log.error("ui: failed to open the UI VM")
		return
	}
	defer ui_vm_destroy(&vm)

	cmds: [dynamic]ui.Draw_Cmd
	defer delete(cmds)

	logged := false
	for platform.pump(&p) {
		render.ui_new_frame(&r)
		w, h := ui_screen_size()
		tree, tok := ui_vm_frame(&vm)
		if !tok {
			break
		}
		ui.measure(&tree)
		tree.screen = ui.Rect{0, 0, w, h}
		ui.layout_children(&tree)
		clear(&cmds)
		ui.emit(&tree, &cmds)
		if !logged && len(cmds) > 0 {
			log.infof("uitest: main_menu loaded — screen %.0fx%.0f, %d draw cmds", w, h, len(cmds))
			logged = true
		}
		ui_render_imgui(cmds[:])
		ui.destroy(&tree)
		if render.begin_frame(&r, {0.05, 0.06, 0.08, 1.0}) {
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)
	}
}
