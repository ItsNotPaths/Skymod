package worldstate

import "core:strings"

// Visuals: the effects scripts and magic start (shaders, art, impacts, image space modifiers), kept
// as state the graphics seam draws. Placed emitters are not here: they come with their refs.

// Visual_Kind is the record a visual plays.
Visual_Kind :: enum u8 {
	Shader, // EFSH on a ref
	Art,    // ARTO on a ref (VisualEffect)
	Impact, // IPDS at a ref's node
	Imod,   // IMAD on the screen
}

// Visual is one effect in force. Playing the same (kind, form, ref) again restarts it under a new
// handle, so the store stays bounded and the drawer sees a restart as a new handle.
Visual :: struct {
	kind:     Visual_Kind,
	form:     Form_ID,
	ref:      Form_ID, // 0 = the screen (Imod)
	facing:   Form_ID, // VisualEffect: the ref it faces (a beam's target)
	node:     string,  // Impact: the node it plays at; "" = the ref's root
	strength: f32,     // Imod
	cross:    bool,    // Imod: the one cross-fade modifier (ApplyCrossFade)
	fade:     f32,     // Imod cross-fade: seconds it ramps in after start and out before until
	start:    f64,     // clock.played seconds
	until:    f64,     // 0 = until stopped, or until its record's own art ends
}

// IMPACT_KEEP is how long an impact stays in the store: long enough for a drawer to see it.
// (hole visual-durations :tags (vfx records) :sev polish) an impact stays IMPACT_KEEP seconds, not its IPCT duration, and an Imod.Apply or a Play with no time stays until stopped: no EFSH, ARTO, IPCT or IMAD duration is decoded, so a load after the art ended can replay it.
IMPACT_KEEP :: 5

// play_visual starts `v` now, over any visual with the same kind, form and ref.
play_visual :: proc(ws: ^World_State, v: Visual) -> u32 {
	stop_visual(ws, v.kind, v.form, v.ref)
	ws.next_visual += 1
	nv := v
	nv.node = strings.clone(v.node)
	nv.start = ws.clock.played
	ws.visuals[ws.next_visual] = nv
	return ws.next_visual
}

// stop_visual removes the visual of `kind` and `form` on `ref`.
stop_visual :: proc(ws: ^World_State, kind: Visual_Kind, form, ref: Form_ID) {
	for h, v in ws.visuals {
		if v.kind == kind && v.form == form && v.ref == ref {
			remove_visual(ws, h)
			return
		}
	}
}

// stop_visuals_on removes every visual on `ref`: a deleted ref shows nothing.
stop_visuals_on :: proc(ws: ^World_State, ref: Form_ID) {
	gone := make([dynamic]u32, context.temp_allocator)
	for h, v in ws.visuals {if v.ref == ref {append(&gone, h)}}
	for h in gone {remove_visual(ws, h)}
}

// fade_visual ends the visual in `fade` seconds, ramping it out.
fade_visual :: proc(ws: ^World_State, h: u32, fade: f32) {
	v := &ws.visuals[h]
	v.fade = fade
	v.until = ws.clock.played + f64(fade)
}

// expire_visuals drops the visuals whose time is up. The tick calls it after the clock moves.
expire_visuals :: proc(ws: ^World_State) {
	gone := make([dynamic]u32, context.temp_allocator)
	for h, v in ws.visuals {if v.until > 0 && v.until <= ws.clock.played {append(&gone, h)}}
	for h in gone {remove_visual(ws, h)}
}

remove_visual :: proc(ws: ^World_State, h: u32) {
	delete(ws.visuals[h].node)
	delete_key(&ws.visuals, h)
}
