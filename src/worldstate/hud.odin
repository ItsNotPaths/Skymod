package worldstate

import "core:strings"

// What the HUD reads that no other system keeps. Not saved.

// Note is a Debug.Notification line, posted at `at` (clock.played).
Note :: struct {
	text: string, // owned
	at:   f64,
}

NOTES_KEPT :: 8

// Foe is the actor the player last hit, at `at` (clock.played): the HUD's enemy health bar.
Foe :: struct {
	ref: Form_ID,
	at:  f64,
}

// notify posts a notification. Only the newest NOTES_KEPT stay.
notify :: proc(ws: ^World_State, text: string) {
	if len(ws.notes) == NOTES_KEPT {
		delete(ws.notes[0].text)
		ordered_remove(&ws.notes, 0)
	}
	append(&ws.notes, Note{strings.clone(text), ws.clock.played})
}

destroy_notes :: proc(ws: ^World_State) {
	for n in ws.notes {delete(n.text)}
	delete(ws.notes)
}
