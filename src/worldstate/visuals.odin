package worldstate

import "core:strings"
import "../gamedb"

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

// IMPACT_MIN is the least time an impact stays in the store, so a slow frame still sees it; the
// drawer plays it out from its record.
IMPACT_MIN :: 1

// imod_until is when an Apply of `imod` now ends: 0 for a hold modifier, on until removed.
imod_until :: proc(ws: ^World_State, db: ^gamedb.DB, imod: Form_ID) -> f64 {
	d := gamedb.imod_duration(db, imod)
	return ws.clock.played + f64(d) if d > 0 else 0
}

// impact_until is when an impact of the IPDS `set` played now leaves the store.
impact_until :: proc(ws: ^World_State, db: ^gamedb.DB, set: Form_ID) -> f64 {
	return ws.clock.played + f64(max(gamedb.impact_duration(db, set), IMPACT_MIN))
}

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

// play_effect_visuals shows what a starting magic effect shows (effect_visuals).
play_effect_visuals :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) {
	for v in effect_visuals(ws, db, e) {
		if v.form != 0 {play_visual(ws, v)}
	}
}

// stop_effect_visuals stops what effect `h` showed, unless another running effect on its target
// shows the same.
stop_effect_visuals :: proc(ws: ^World_State, db: ^gamedb.DB, h: Form_ID) {
	e := ws.effects[h]
	others, _ := ws.effects_on[e.target]
	outer: for v in effect_visuals(ws, db, e) {
		if v.form == 0 {continue}
		for o in others {
			oe := ws.effects[o]
			if o == h || oe.ended {continue}
			for ov in effect_visuals(ws, db, oe) {
				if ov.kind == v.kind && ov.form == v.form {continue outer}
			}
		}
		stop_visual(ws, v.kind, v.form, v.ref)
	}
}

// effect_visuals is what a running magic effect shows: its MGEF hit shader and hit art on the
// target, and its image space modifier while the target is the player. 0 forms show nothing.
// (hole cast-visuals :tags (vfx magic) :sev gap) a cast shows no casting art or casting light on the caster, and a spell's projectile or touch landing plays no impact data set: Visual has no world position for a hit on terrain.
// (hole enchant-visuals :tags (vfx magic combat) :sev gap :needs (weapon-enchantments)) an enchanted weapon or item shows no enchant shader or enchant art.
@(private = "file")
effect_visuals :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> [3]Visual {
	me, _ := gamedb.magic_effect_of(db, e.effect)
	return {
		{kind = .Shader, form = me.art[.Hit_Shader], ref = e.target},
		{kind = .Art, form = me.art[.Hit_Art], ref = e.target},
		{kind = .Imod, form = me.art[.Imod] if e.target == ws.player else 0, strength = 1, until = imod_until(ws, db, me.art[.Imod])},
	}
}
