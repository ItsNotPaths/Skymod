package main

// The Lua main-menu session: mounts the menu's VFS, builds the live font atlas, opens the UI VM on
// main_menu.lua, and pumps the substrate's per-frame protocol (ui.frame → layout → ui.route_input →
// ui.dispatch → draw) until Lua hands back a result verb or the window closes. The menu is a pure
// function of the active profile — the pre-world loop (preworld.odin) re-runs this after the mod
// manager, so a profile switch/apply is reflected on return. Screen structure + behavior live
// entirely in Lua; the only menu↔engine contract is the result VERB (ui.exit) mapped to a boot
// action here. Returns ok=false on init failure so the caller falls back to the imgui boot menu.

import "core:strings"
import "core:time"
import sdl "vendor:sdl3"
import "../font"
import "../mods"
import "../platform"
import "../render"
import "../tools"
import "../ui"
import "../vfs"

@(private = "file")
MENU_CLEAR :: [4]f32{0, 0, 0, 1.0} // pure black — the 3D logo + UI composite over it

// run_lua_main_menu runs the synthesized built-in Lua menu until it hands back a verb or the window
// closes. ok=false means the menu couldn't initialize (no font/atlas/screen) → caller uses imgui.
run_lua_main_menu :: proc(
	p: ^platform.Platform,
	r: ^render.Renderer,
	base, src: string,
	profile: ^mods.Profile,
) -> (
	action: tools.Menu_Action,
	ok: bool,
) {
	if !baseui_ensure(base) {
		return .None, false
	}
	// The menu's own VFS (mods > vanilla Data > vanilla BSAs > mod BSAs): every UI asset — font,
	// credits, logos — resolves through it, so a mod overrides any of them uniformly. Cheap (BSA
	// headers); rebuilt each menu entry, so changes from the mod manager are reflected.
	v := mount_game_mods(src, base, profile)
	defer vfs.destroy(&v)
	baseui_extract_assets(&v, base) // install-time: convert SWF-embedded UI assets → DDS in bethassets

	atlas, aok := baseui_build_atlas(&v)
	if !aok {
		return .None, false
	}
	defer font.destroy(&atlas)
	ui.set_font(&atlas)
	defer ui.set_font(nil)

	lua_root := baseui_lua_root(base, context.temp_allocator)
	host := UI_Host {
		base = base,
		vf   = &v,
	}
	defer ui_host_destroy(&host)
	vm: ui.VM
	if !ui.open(&vm, lua_root, "main_menu.lua", &host, install_engine_api) {
		return .None, false
	}
	defer ui.close(&vm)

	ren := ui_render_init(r, &atlas, &v)
	defer ui_render_destroy(&ren)
	// Clear the renderer's UI drawlist on exit, or the next screen (loading/world) would redraw the
	// menu's stale quads in its post pass.
	defer render.set_ui_drawlist(r, {}, {}, {}, {})

	// The 3D menu logo (logo.nif behind the UI). Lua owns whether it draws (ui.menu_logo.enabled) —
	// read it once up front so a disabled logo isn't parsed/uploaded at all (only wire in the load when
	// the menu actually wants it; re-enabling is a Lua flag flip + this load kicks in).
	logo_cfg := menu_logo_cfg_default() // baked camera/light look; enabled/pos/scale come from Lua each frame
	menu_logo_read_lua(&vm, &logo_cfg)
	logo: Menu_Logo
	logo_ok := false
	if logo_cfg.enabled {
		logo, logo_ok = menu_logo_load(r, &v)
	}
	defer if logo_ok {menu_logo_destroy(r, &logo)}

	prev_hook := p.on_event
	p.on_event = menu_event_hook
	defer p.on_event = prev_hook

	// focus_id is OWNED (cloned into context.allocator) and persists across frames: the focusables it
	// is derived from borrow the per-frame tree, which is destroyed every iteration, so we must not
	// hold a borrowed id. Starts as the empty string's zero value (nil data) — delete is a no-op.
	focus_id: string
	defer delete(focus_id)
	cmds: [dynamic]ui.Draw_Cmd
	defer delete(cmds)
	start := time.tick_now() // animation clock (seconds since the menu opened), exposed to Lua as ui.time

	for platform.pump(p) {
		nav := menu_nav_take()
		render.ui_new_frame(r) // imgui NewFrame — MUST be matched by a Render (begin_frame) below,
		// EVERY iteration including the one we return on, or the next screen's NewFrame asserts.
		w, h := ui_screen_size()
		mx, my := menu_mouse_px(p, w, h)
		click := p.input.select

		// 1. Lua builds the tree (with last frame's focus + clock + viewport so widgets can style/animate).
		ui.set_time(&vm, time.duration_seconds(time.tick_since(start)))
		ui.set_viewport(&vm, w, h)
		ui.set_focus(&vm, focus_id)
		tree, tok := ui.frame(&vm)
		if !tok {
			if render.begin_frame(r, MENU_CLEAR) {render.end_frame(r)} // balance imgui, then bail
			return .None, false // broken UI → fall back to imgui
		}

		// 2. Lay it out and collect the focusables the engine routes to (scoped to a modal subtree).
		ui.measure(&tree)
		tree.screen = ui.Rect{0, 0, w, h}
		ui.layout_children(&tree)
		focusables: [dynamic]ui.Focusable
		ui.collect_focusables(ui.focus_root(&tree), &focusables)

		// 3. Route input → the activated action + the focus for next frame. Both BORROW the tree, so
		//    clone the focus into our owned buffer now and dispatch the action (step 5) before the
		//    tree is destroyed below.
		activated, new_focus := ui.route_input(focusables[:], focus_id, nav, mx, my, click)
		set_focus_owned(&focus_id, new_focus)

		// 4. Draw THIS frame's tree.
		clear(&cmds)
		ui.emit(&tree, &cmds)
		ui_render_draw(&ren, cmds[:], {w, h})

		// 5. Apply the activation while the tree `activated` borrows is still alive (state change shows
		//    next frame), THEN destroy the tree.
		if nav.back {
			ui.back(&vm)
		}
		ui.dispatch(&vm, activated)
		verb, rok := ui.take_result(&vm)

		ui.destroy(&tree)
		delete(focusables)

		// 6. Present (this Render balances the NewFrame above) BEFORE returning on a result. The 3D
		//    logo draws into the scene pass; the UI composites over it in end_frame. The menu Lua owns
		//    enabled/pos/scale (ui.menu_logo) so a mod can disable or move it; lighting is set BEFORE
		//    begin_frame (scene_begin pushes it) so the flat-fullbright env covers the logo.
		menu_logo_read_lua(&vm, &logo_cfg)
		if logo_ok {
			render.set_lighting(r, menu_logo_light(&logo_cfg))
			render.set_post(r, menu_logo_post()) // flat tonemap so the fullbright ambient isn't rolled off
		}
		if render.begin_frame(r, MENU_CLEAR) {
			if logo_ok {menu_logo_draw(r, &logo, &logo_cfg)}
			render.end_frame(r)
		}

		// Map the verb BEFORE freeing temp — `verb` is temp-allocated, so free_all would dangle it
		// (the bug that made "Mods"/"Continue"/"Quit" silently do nothing: the freed verb stopped
		// matching, so no boot action was returned).
		act: tools.Menu_Action
		mapped := false
		if rok {
			act, mapped = menu_map_verb(verb)
		}
		free_all(context.temp_allocator)
		if mapped {
			return act, true
		}
	}
	return .None, true // window closed / quit
}

// menu_map_verb maps the Lua menu's result verb to a boot action. "load" resolves to Continue (the
// single quicksave slot); a richer verb ("load:<id>") arrives with save rotation.
@(private = "file")
menu_map_verb :: proc(verb: string) -> (tools.Menu_Action, bool) {
	switch verb {
	case "continue":
		return .Continue, true
	case "new_game":
		return .New, true
	case "mods":
		return .Mods, true
	case "quit":
		return .Quit, true
	}
	return .None, false
}

// menu_mouse_px converts the platform's NDC cursor to UI pixel space (top-left origin).
@(private = "file")
menu_mouse_px :: proc(p: ^platform.Platform, w, h: f32) -> (f32, f32) {
	ndc := p.input.mouse_ndc
	return (ndc.x + 1) * 0.5 * w, (1 - ndc.y) * 0.5 * h
}

// set_focus_owned replaces the owned focus id with a clone of `src` (which borrows the per-frame
// tree). Skips the realloc when the content is unchanged — the common case frame to frame — so the
// owned buffer stays valid and stable. `dst` starts as the empty string (nil data); delete is safe.
@(private = "file")
set_focus_owned :: proc(dst: ^string, src: string) {
	if dst^ == src {
		return
	}
	delete(dst^)
	dst^ = strings.clone(src)
}

// ── keyboard navigation (raw SDL events → the substrate's edge-triggered ui.Nav intent) ─────────
//
// The platform calls one Event_Hook per raw SDL event; this hook forwards to imgui (so the dev
// overlay keeps working) and records edge-triggered nav keys (down on this pump, not held), which
// the menu loop drains each frame with menu_nav_take. Mouse position + left-click come from
// platform's Input snapshot, so only the keyboard lives here.
//
// Note: platform.pump treats Esc as quit (returns false), so the menu uses Backspace for "back".

@(private = "file")
g_nav: ui.Nav

// menu_event_hook is wired as platform.on_event while the Lua menu runs. Forwards to imgui + records
// nav-key edges. Held repeats are ignored so one keypress moves the cursor one step.
menu_event_hook :: proc(ev: ^sdl.Event) {
	render.ui_process_event(ev)
	#partial switch ev.type {
	case .KEY_DOWN:
		if ev.key.repeat {
			return
		}
		#partial switch ev.key.scancode {
		case .UP, .W:
			g_nav.up = true
		case .DOWN, .S:
			g_nav.down = true
		case .RETURN, .KP_ENTER, .SPACE:
			g_nav.accept = true
		case .BACKSPACE:
			g_nav.back = true
		}
	}
}

// menu_nav_take returns the nav intent accumulated since the last call and clears it.
@(private = "file")
menu_nav_take :: proc() -> ui.Nav {
	v := g_nav
	g_nav = {}
	return v
}
