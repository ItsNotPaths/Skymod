package main

// The in-world HUD driver: a thin, non-interactive session over the shared UI substrate (UI_Session
// + the `engine` host API), drawn every gameplay frame. Today it renders the crosshair reticle and
// the activation prompt ("Open Chest", "Open Riverwood Trader (Locked)", "Talk", …); it's the seed of
// the full hudmenu (compass, H/M/S bars) later. Like the load screen (loadui.odin) the session lives
// on Game and persists for the whole run; unlike it, the HUD owns the UI drawlist during ordinary
// gameplay frames. The screen itself is pure Lua (hud.lua) — this file only owns the session's
// lifetime and publishes the resolved activation target into the host each frame.

import "core:log"
import "../input"
import "../render"

// hud_init opens the persistent HUD session on hud.lua. baseui (chrome + reticle asset) and a font
// atlas are already ensured by loadui_init, which runs earlier in game_setup. ok=false (font/atlas
// failed) leaves g.hud.ok false and frame_hud becomes a no-op — the game still plays, just without
// the styled prompt.
hud_init :: proc(g: ^Game) -> bool {
	g.hud.host.act_button = "F" // the activate key (platform.Input.activate = F); Lua resolves its glyph
	return ui_session_open(&g.hud, &g.r, &g.v, g.base, "hud.lua")
}

hud_destroy :: proc(g: ^Game) {
	ui_session_close(&g.hud)
}

// frame_hud resolves what the crosshair points at, publishes it to the HUD host (engine.activation),
// draws the HUD, and fires the non-door activate STUB. Runs each gameplay frame before frame_render
// composites the UI drawlist. Doors are crossed by frame_traversal (proximity + F); this only shows
// their prompt. A no-op when the session failed to init.
frame_hud :: proc(g: ^Game) {
	if !g.hud.ok {
		return
	}
	// Dev overlay open (tilde) = cursor free / imgui panels up: hide the HUD so no stray reticle sits
	// behind the panels. Clearing the drawlist is what actually removes last frame's quads.
	if g.show_overlay {
		render.set_ui_drawlist(&g.r, {}, {}, {}, {})
		return
	}

	tgt := resolve_activation(g)
	g.hud.host.act_present = tgt.present
	g.hud.host.act_kind = activate_kind_tag[tgt.kind]
	g.hud.host.act_name = tgt.name
	g.hud.host.act_dest = tgt.dest
	g.hud.host.act_locked = tgt.locked

	// Activate (F): doors cross via frame_traversal. For a non-door target, log a stub so the input
	// path is proven end-to-end now — real container/dialogue menus hook in here later.
	if tgt.present && tgt.kind != .Door && input.fired(&g.imgr, "Activate") {
		subject := tgt.name if tgt.name != "" else "(unnamed)"
		verb := "open" if tgt.kind == .Container else "activate"
		log.infof("activate: %s %q [%s] — no menu yet (stub)", verb, subject, activate_kind_tag[tgt.kind])
	}

	w, h := ui_screen_size()
	ui_session_draw(&g.hud, w, h)
}
