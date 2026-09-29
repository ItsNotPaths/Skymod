package main

// A UI substrate SESSION: the app-side bundle every player-UI screen needs — the live font atlas, the
// SDL3_gpu UI renderer (ui_render), the Lua VM running one screen, and the `engine` host data. Built
// once with ui_session_open, torn down with ui_session_close. Both the pre-world main menu (menu.odin,
// interactive) and the in-session load screen (loadui.odin, non-interactive) run on THIS one substrate —
// they differ only in their per-frame loop (the menu routes input + maps a result verb; the load screen
// just publishes progress and redraws). New screens reuse this rather than re-plumbing atlas+vm+render.
//
// The caller mounts the VFS and synthesizes/extracts the baseui files (baseui_ensure / extract_assets)
// before opening — the session only needs a built VFS to read the font + assets through.

import "core:strings"
import "core:time"
import "../font"
import "../platform"
import "../render"
import "../ui"
import "../vfs"

UI_Session :: struct {
	r:         ^render.Renderer,
	atlas:     font.Atlas,
	ren:       UI_Render,
	vm:        ui.VM,
	host:      UI_Host, // the `engine` table's app data (saves/credits + load progress)
	cmds:      [dynamic]ui.Draw_Cmd, // per-frame draw-cmd scratch (cleared each frame)
	phase_buf: [96]u8, // scratch for a formatted phase label (e.g. a city name) — no per-frame alloc
	start:     time.Tick, // animation clock origin, published to Lua as ui.time
	focus:     string, // owned: the focused node id, kept across frames (ui_session_step)
	ok:        bool,
}

// ui_session_open builds the atlas from `v`, wires the UI renderer, and opens the VM on `screen_rel`
// with the shared `engine` host API (UI_Host rides as vm.user). Sets the substrate font for the
// session (gameplay uses imgui, not the ui package, so this is safe to leave set). ok=false — a missing
// font/atlas/screen — leaves the session unusable (the caller decides how to degrade).
ui_session_open :: proc(s: ^UI_Session, r: ^render.Renderer, v: ^vfs.VFS, base, screen_rel: string) -> bool {
	s.r = r
	atlas, aok := baseui_build_atlas(v)
	if !aok {
		return false
	}
	s.atlas = atlas
	ui.set_font(&s.atlas)
	s.ren = ui_render_init(r, &s.atlas, v)
	s.host = UI_Host{base = base, vf = v}
	lua_root := baseui_lua_root(base, context.temp_allocator)
	if !ui.open(&s.vm, lua_root, screen_rel, &s.host, install_engine_api) {
		ui.set_font(nil)
		ui_render_destroy(&s.ren)
		font.destroy(&s.atlas)
		return false
	}
	s.start = time.tick_now()
	s.ok = true
	return true
}

// ui_session_close tears the session down (VM → host data → UI drawlist → renderer → font → atlas) and
// clears the renderer's stale UI quads so the next screen doesn't redraw them. Safe on a zero session.
ui_session_close :: proc(s: ^UI_Session) {
	delete(s.cmds)
	delete(s.focus)
	s.focus = ""
	if !s.ok {
		return
	}
	ui.close(&s.vm)
	ui_host_destroy(&s.host)
	render.set_ui_drawlist(s.r, {}, {}, {}, {})
	ui_render_destroy(&s.ren)
	ui.set_font(nil)
	font.destroy(&s.atlas)
	s.ok = false
}

// ui_session_draw renders one frame of the session's screen NON-interactively: publish the clock +
// viewport, ask Lua for the tree, lay it out, emit + hand the quads to the UI renderer. Interactive
// screens (the menu) drive the substrate directly instead (they also route input + dispatch actions);
// this is the shared convenience for screens that are a pure function of published state (the load screen).
ui_session_draw :: proc(s: ^UI_Session, w, h: f32) {
	// Bind THIS session's atlas: ui.set_font sets a package GLOBAL (the active glyph atlas emit bakes
	// into + computes UVs against), so with multiple live sessions (load screen + HUD) whichever opened
	// last owns it. Re-bind each draw or a session emits glyphs against another's atlas → garbled text
	// (the load screen sampling the HUD atlas after hud_init ran). Cheap; must precede ui.frame/emit.
	ui.set_font(&s.atlas)
	ui.set_time(&s.vm, time.duration_seconds(time.tick_since(s.start)))
	ui.set_viewport(&s.vm, w, h)
	tree, ok := ui.frame(&s.vm)
	if !ok {
		return
	}
	ui.measure(&tree)
	tree.screen = ui.Rect{0, 0, w, h}
	ui.layout_children(&tree)
	clear(&s.cmds)
	ui.emit(&tree, &s.cmds)
	ui_render_draw(&s.ren, s.cmds[:], {w, h})
	ui.destroy(&tree)
}

// ui_session_step runs one interactive frame: route the input to the screen's focusables, draw, then
// dispatch the activated action. `verb` is what the screen handed back with ui.exit (temp-allocated);
// ok=false means the screen failed to build its tree.
ui_session_step :: proc(s: ^UI_Session, w, h: f32, nav: ui.Nav, mx, my: f32, click: bool) -> (verb: string, has_verb, ok: bool) {
	ui.set_font(&s.atlas) // see ui_session_draw
	ui.set_time(&s.vm, time.duration_seconds(time.tick_since(s.start)))
	ui.set_viewport(&s.vm, w, h)
	ui.set_focus(&s.vm, s.focus)
	tree := ui.frame(&s.vm) or_return
	defer ui.destroy(&tree)
	ui.measure(&tree)
	tree.screen = ui.Rect{0, 0, w, h}
	ui.layout_children(&tree)
	focusables: [dynamic]ui.Focusable
	defer delete(focusables)
	ui.collect_focusables(ui.focus_root(&tree), &focusables)

	// Both results borrow the tree: keep the focus and dispatch before the deferred destroy.
	activated, new_focus := ui.route_input(focusables[:], s.focus, nav, mx, my, click)
	if s.focus != new_focus {
		delete(s.focus)
		s.focus = strings.clone(new_focus)
	}
	clear(&s.cmds)
	ui.emit(&tree, &s.cmds)
	ui_render_draw(&s.ren, s.cmds[:], {w, h})
	if nav.back {ui.back(&s.vm)}
	ui.dispatch(&s.vm, activated)
	verb, has_verb = ui.take_result(&s.vm)
	return verb, has_verb, true
}

// ui_mouse_px converts the platform's NDC cursor to UI pixel space (top-left origin).
ui_mouse_px :: proc(p: ^platform.Platform, w, h: f32) -> (f32, f32) {
	ndc := p.input.mouse_ndc
	return (ndc.x + 1) * 0.5 * w, (1 - ndc.y) * 0.5 * h
}
