package main

// The message box: an in-world Lua screen (message_box.lua) that shows a text and its buttons over
// the paused world, and hands the picked button index to whoever opened it.

import "core:log"
import "core:strconv"
import "core:strings"
import "core:time"
import "../input"
import "../ui"

Box_Text :: struct {
	body:    string,   // owned
	buttons: []string, // owned; empty = the screen's own default button
}

Box_Pick :: #type proc(g: ^Game, pick: int)

Message_Box :: struct {
	sess:    UI_Session,
	on_pick: Box_Pick,
}

message_box_init :: proc(g: ^Game) -> bool {
	if !ui_session_open(&g.box.sess, &g.r, &g.v, g.base, "message_box.lua") {return false}
	g.box.sess.host.imgr = &g.imgr
	g.box.sess.host.audio, g.box.sess.host.db = &g.audio, &g.db
	return true
}

message_box_destroy :: proc(g: ^Game) {
	box_text_free(&g.box.sess.host.box)
	ui_session_close(&g.box.sess)
}

message_box_up :: proc(g: ^Game) -> bool {
	return g.box.sess.host.box != nil
}

// message_box_open shows `body` with `buttons` and pauses the world. `on_pick` gets the picked index
// when the player picks; a second box replaces the first, which then gets no pick.
message_box_open :: proc(g: ^Game, body: string, buttons: []string, on_pick: Box_Pick) {
	if !g.box.sess.ok {
		log.warnf("[message] no message box screen; picked 0 for %q", body)
		on_pick(g, 0)
		return
	}
	box_text_free(&g.box.sess.host.box)
	labels := make([]string, len(buttons))
	for b, i in buttons {labels[i] = strings.clone(b)}
	g.box.sess.host.box = Box_Text{strings.clone(body), labels}
	g.box.on_pick = on_pick
	g.box.sess.start = time.tick_now()
	delete(g.box.sess.focus)
	g.box.sess.focus = ""
	park_for_menu(g)
}

// frame_message_box routes the menu keys and the mouse to the open box and draws it. Once the player
// picks, the box closes and the world runs again.
frame_message_box :: proc(g: ^Game) {
	if !message_box_up(g) {return}
	w, h := ui_screen_size()
	mx, my := ui_mouse_px(&g.p, w, h)
	nav := ui.Nav {
		up     = input.fired(&g.imgr, "MenuUp") || input.fired(&g.imgr, "MenuLeft"),
		down   = input.fired(&g.imgr, "MenuDown") || input.fired(&g.imgr, "MenuRight"),
		accept = input.fired(&g.imgr, "MenuAccept"),
	}
	verb, picked, ok := ui_session_step(&g.box.sess, w, h, nav, mx, my, g.p.input.select)
	pick := 0
	if !ok {
		log.error("[message] the message box screen failed; picked 0")
	} else if !picked {
		return
	} else {
		pick, _ = strconv.parse_int(verb)
	}
	on_pick := g.box.on_pick
	box_text_free(&g.box.sess.host.box)
	park_for_menu(g)
	on_pick(g, pick)
}

@(private = "file")
box_text_free :: proc(box: ^Maybe(Box_Text)) {
	b, ok := box.?
	if !ok {return}
	delete(b.body)
	for s in b.buttons {delete(s)}
	delete(b.buttons)
	box^ = nil
}
