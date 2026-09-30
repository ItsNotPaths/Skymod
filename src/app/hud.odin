package main

// The in-world HUD driver: a thin, non-interactive session over the shared UI substrate (UI_Session
// + the `engine` host API), drawn every gameplay frame. Today it renders the crosshair reticle and
// the activation prompt ("Open Chest", "Open Riverwood Trader (Locked)", "Talk", …); it's the seed of
// the full hudmenu (compass, H/M/S bars) later. Like the load screen (loadui.odin) the session lives
// on Game and persists for the whole run; unlike it, the HUD owns the UI drawlist during ordinary
// gameplay frames. The screen itself is pure Lua (hud.lua) — this file only owns the session's
// lifetime and publishes the resolved activation target into the host each frame.

import "../actorstate"
import "../render"
import "../worldstate"

// hud_init opens the persistent HUD session on hud.lua. The baseui Lua is already written by
// loadui_init, which runs earlier in game_setup. ok=false (font/atlas
// failed) leaves g.hud.ok false and frame_hud becomes a no-op — the game still plays, just without
// the styled prompt.
hud_init :: proc(g: ^Game) -> bool {
	if !ui_session_open(&g.hud, &g.r, &g.v, g.base, "hud.lua") {
		return false
	}
	// engine.prompt (the prompt{} widget) resolves live bindings through the input manager —
	// set AFTER open (ui_session_open rebuilds the host struct).
	g.hud.host.imgr = &g.imgr
	g.hud.host.audio, g.hud.host.db = &g.audio, &g.db
	return true
}

hud_destroy :: proc(g: ^Game) {
	ui_session_close(&g.hud)
}

// frame_hud publishes the crosshair target (resolved by the sim into g.snap.act) to the HUD host (engine.activation) and draws the HUD. Runs each gameplay frame before
// frame_render composites the UI drawlist. Activate itself is handled in tick_interact; this only
// shows the prompt. A no-op when the session failed to init.
frame_hud :: proc(g: ^Game) {
	if !g.hud.ok || message_box_up(g) { // the box draws in the HUD's place
		return
	}
	// Dev overlay open (tilde) = cursor free / imgui panels up: hide the HUD so no stray reticle sits
	// behind the panels. Clearing the drawlist is what actually removes last frame's quads.
	if g.show_overlay {
		render.set_ui_drawlist(&g.r, {}, {}, {}, {})
		return
	}

	g.hud.host.snap = &g.snap
	g.hud.host.heading = g.cam.yaw
	tgt := g.snap.act
	g.hud.host.act_present = tgt.present
	g.hud.host.act_kind = activate_kind_tag[tgt.kind]
	g.hud.host.act_name = text(&g.snap, tgt.name)
	g.hud.host.act_dest = text(&g.snap, tgt.dest)
	g.hud.host.act_locked = tgt.locked

	w, h := ui_screen_size()
	ui_session_draw(&g.hud, w, h)
}

// Hud_View is what the HUD shows of the player: its meters, the foe it last hit, notifications.
Hud_View :: struct {
	health, magicka, stamina: Meter_View,
	combat: bool, // the player fights, or is fought
	sneaking:  bool,
	detection: f32, // 0..1: the most any actor has noticed the player
	detected:  bool, // some actor has detected the player
	foe:    Foe_View,
	notes:  [dynamic]Note_View, // oldest first
}

Meter_View :: struct {
	cur, max: f32,
}

Foe_View :: struct {
	present:  bool,
	name:     Text_Span,
	health:   Meter_View,
	age:      f32, // seconds since the player last hit it
	fighting: bool, // it fights the player
}

Note_View :: struct {
	text: Text_Span,
	age:  f32, // seconds since it was posted
}

view_hud :: proc(g: ^Game, s: ^Snapshot) {
	ws := &g.sim.ws
	meter :: proc(g: ^Game, actor: Form_ID, av: string) -> Meter_View {
		return {worldstate.av_current(&g.sim.ws, &g.db, actor, av), worldstate.av_max(&g.sim.ws, &g.db, actor, av)}
	}
	h := &s.hud
	h.health = meter(g, ws.player, "Health")
	h.magicka = meter(g, ws.player, "Magicka")
	h.stamina = meter(g, ws.player, "Stamina")
	h.combat = worldstate.in_combat(ws, ws.player)
	h.sneaking = actorstate.current(&ws.states, ws.player) == actorstate.SNEAK
	h.detection, h.detected = 0, false
	for pair, a in ws.awareness {
		if pair[1] != ws.player {continue}
		h.detection = max(h.detection, a.level)
		h.detected ||= a.detected
	}
	h.foe = {}
	if f := ws.foe; f.ref != 0 {
		h.foe = {
			present  = true,
			name     = add_text(s, worldstate.display_name(ws, &g.db, f.ref)),
			health   = meter(g, f.ref, "Health"),
			age      = f32(ws.clock.played - f.at),
			fighting = ws.ai.fighting[f.ref] == ws.player,
		}
	}
	clear(&h.notes)
	for n in ws.notes {append(&h.notes, Note_View{add_text(s, n.text), f32(ws.clock.played - n.at)})}
}
