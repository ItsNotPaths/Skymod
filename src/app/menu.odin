package main

// The Lua main-menu loop: a GENERIC engine driver, not menu-specific logic. Each frame it asks the
// Lua VM for the composed tree (ui._frame), lays it out, routes raw input (mouse hover/click,
// keyboard up/down/accept, Backspace) to whichever focusable node it lands on, tells Lua which action
// fired, exposes the focused id (so Lua widgets style themselves), reads back a result verb, and
// draws via the SDL3_gpu UI path. It has NO knowledge of "continue"/dialogs/saves — those are Lua.
//
// The only menu↔engine contract is the result VERB the menu's Lua hands back via ui.exit, mapped to a
// boot action here. Returns ok=false on init failure so the caller falls back to the imgui boot menu.

import "core:strings"
import "core:time"
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
	if !ensure_ui_content(base) {
		return .None, false
	}
	// The menu's own VFS (mods > vanilla Data > vanilla BSAs > mod BSAs): every UI asset — font,
	// credits, logos — resolves through it, so a mod overrides any of them uniformly. Cheap (BSA
	// headers); rebuilt each menu entry, so changes from the mod manager are reflected.
	v := mount_game_mods(src, base, profile)
	defer vfs.destroy(&v)
	ui_content_extract_assets(&v, base) // install-time: convert SWF-embedded UI assets → DDS in bethassets

	atlas, aok := ui_content_build_atlas(&v)
	if !aok {
		return .None, false
	}
	defer font.destroy(&atlas)
	ui.set_font(&atlas)
	defer ui.set_font(nil)

	lua_root := ui_lua_root(base, context.temp_allocator)
	vm: UI_VM
	if !ui_vm_open(&vm, base, &v, lua_root, "main_menu.lua") {
		return .None, false
	}
	defer ui_vm_destroy(&vm)

	ren := ui_render_init(r, &atlas, &v)
	defer ui_render_destroy(&ren)
	// Clear the renderer's UI drawlist on exit, or the next screen (loading/world) would redraw the
	// menu's stale quads in its post pass.
	defer render.set_ui_drawlist(r, {}, {}, {}, {})

	// The 3D menu logo (logo.nif behind the UI). Lua owns whether it draws (ui.menu_logo.enabled) —
	// read it once up front so a disabled logo isn't parsed/uploaded at all (only wire in the load when
	// the menu actually wants it; re-enabling is a Lua flag flip + this load kicks in).
	logo_cfg := menu_logo_cfg_default() // baked camera/light look; enabled/pos/scale come from Lua each frame
	ui_vm_get_logo(&vm, &logo_cfg.enabled, &logo_cfg.pos, &logo_cfg.scale, &logo_cfg.ambient, &logo_cfg.lift)
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
		ui_vm_set_time(&vm, time.duration_seconds(time.tick_since(start)))
		ui_vm_set_viewport(&vm, w, h)
		ui_vm_set_focus(&vm, focus_id)
		tree, tok := ui_vm_frame(&vm)
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
		activated, new_focus := route_input(focusables[:], focus_id, nav, mx, my, click)
		set_focus_owned(&focus_id, new_focus)

		// 4. Draw THIS frame's tree.
		clear(&cmds)
		ui.emit(&tree, &cmds)
		ui_render_draw(&ren, cmds[:], {w, h})

		// 5. Apply the activation while the tree `activated` borrows is still alive (state change shows
		//    next frame), THEN destroy the tree.
		if nav.back {
			ui_vm_back(&vm)
		}
		ui_vm_dispatch(&vm, activated)
		verb, rok := ui_vm_take_result(&vm)

		ui.destroy(&tree)
		delete(focusables)

		// 6. Present (this Render balances the NewFrame above) BEFORE returning on a result. The 3D
		//    logo draws into the scene pass; the UI composites over it in end_frame. The menu Lua owns
		//    enabled/pos/scale (ui.menu_logo) so a mod can disable or move it; lighting is set BEFORE
		//    begin_frame (scene_begin pushes it) so the flat-fullbright env covers the logo.
		ui_vm_get_logo(&vm, &logo_cfg.enabled, &logo_cfg.pos, &logo_cfg.scale, &logo_cfg.ambient, &logo_cfg.lift)
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

// route_input is the generic focus model: mouse hover sets focus; arrows/W-S step over enabled
// focusables; click activates the hovered item; accept activates the focused one. Returns the
// activated action ("" if none) and the (id-based) focus for next frame. BOTH strings borrow `fs`
// (and thus the tree) — the caller must consume them before destroying the tree.
@(private = "file")
route_input :: proc(
	fs: []ui.Focusable,
	cur_focus: string,
	nav: Menu_Nav,
	mx, my: f32,
	click: bool,
) -> (activated: string, focus: string) {
	if len(fs) == 0 {
		return "", ""
	}
	cur := index_of_id(fs, cur_focus)

	hovered := -1
	for f, i in fs {
		if !f.disabled && ui.contains(f.rect, mx, my) {
			hovered = i
		}
	}
	if hovered >= 0 {
		cur = hovered
	}
	if nav.up {
		cur = step_enabled(fs, cur, -1)
	}
	if nav.down {
		cur = step_enabled(fs, cur, +1)
	}
	if cur < 0 || cur >= len(fs) || fs[cur].disabled {
		cur = first_enabled(fs)
	}
	focus = fs[cur].id if cur >= 0 else ""

	if click && hovered >= 0 {
		return fs[hovered].action, focus
	}
	if nav.accept && cur >= 0 && !fs[cur].disabled {
		return fs[cur].action, focus
	}
	return "", focus
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

@(private = "file")
index_of_id :: proc(fs: []ui.Focusable, id: string) -> int {
	if id == "" {
		return -1
	}
	for f, i in fs {
		if f.id == id {
			return i
		}
	}
	return -1
}

// step_enabled moves `dir` from `cur` (wrapping), skipping disabled focusables.
@(private = "file")
step_enabled :: proc(fs: []ui.Focusable, cur, dir: int) -> int {
	n := len(fs)
	if n == 0 {
		return -1
	}
	i := cur if cur >= 0 else (0 if dir > 0 else n - 1)
	for _ in 0 ..< n {
		i = (i + dir + n) % n
		if !fs[i].disabled {
			return i
		}
	}
	return cur
}

@(private = "file")
first_enabled :: proc(fs: []ui.Focusable) -> int {
	for f, i in fs {
		if !f.disabled {
			return i
		}
	}
	return -1
}
