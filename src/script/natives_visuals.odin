package script

// EffectShader, VisualEffect, impacts and ImageSpaceModifier write visual state
// (worldstate/visuals.odin); the graphics seam draws it. Nothing here calls render.

import "../worldstate"

// (hole camera-shake :tags vfx :sev gap) Game.ShakeCamera and ShakeController do nothing: main's camera does not shake and no pad rumbles.
// (hole screen-fade :tags (vfx ui) :sev gap) Game.FadeOutGame does nothing: main draws no fade over the frame.
// (hole impact-pick :tags (vfx physics) :sev gap) PlayImpactEffect plays at the node, not where its pick ray (afPickDir, afPickLength) meets a surface, and a plugin gets no surface material to choose the IPDS entry.
register_visuals :: proc(reg: ^Registry) {
	register(reg, "EffectShader", "Play", proc(c: ^Call, args: []Value) -> Value {
		play_on(c, .Shader, c.self, args, arg_f32(args, 1, -1))
		return nil
	})
	register(reg, "EffectShader", "Stop", proc(c: ^Call, args: []Value) -> Value {
		worldstate.stop_visual(c.ws, .Shader, c.self, visual_ref(c, args, 0))
		return nil
	})
	// A VisualEffect (RFCT) plays its art, and its shader with it.
	register(reg, "VisualEffect", "Play", proc(c: ^Call, args: []Value) -> Value {
		ve := c.db.visual_effects[c.self]
		secs := arg_f32(args, 1, -1)
		play_on(c, .Art, ve.art, args, secs, facing = visual_ref(c, args, 2))
		play_on(c, .Shader, ve.shader, args, secs)
		return nil
	})
	register(reg, "VisualEffect", "Stop", proc(c: ^Call, args: []Value) -> Value {
		ve := c.db.visual_effects[c.self]
		ref := visual_ref(c, args, 0)
		worldstate.stop_visual(c.ws, .Art, ve.art, ref)
		worldstate.stop_visual(c.ws, .Shader, ve.shader, ref)
		return nil
	})
	register(reg, "ObjectReference", "PlayImpactEffect", proc(c: ^Call, args: []Value) -> Value {
		set := arg_form(c, args, 0)
		worldstate.play_visual(c.ws, {kind = .Impact, form = set, ref = worldstate.resolve(c.ws, c.self), node = arg_str(args, 1), until = worldstate.impact_until(c.ws, c.db, set)})
		return true
	})
	register(reg, "ImageSpaceModifier", "Apply", proc(c: ^Call, args: []Value) -> Value {
		worldstate.play_visual(c.ws, {kind = .Imod, form = c.self, strength = arg_f32(args, 0, 1), until = worldstate.imod_until(c.ws, c.db, c.self)})
		return nil
	})
	register(reg, "ImageSpaceModifier", "Remove", proc(c: ^Call, args: []Value) -> Value {
		worldstate.stop_visual(c.ws, .Imod, c.self, 0)
		return nil
	})
	register(reg, "ImageSpaceModifier", "PopTo", proc(c: ^Call, args: []Value) -> Value {
		worldstate.stop_visual(c.ws, .Imod, c.self, 0)
		next := arg_form(c, args, 0)
		worldstate.play_visual(c.ws, {kind = .Imod, form = next, strength = arg_f32(args, 1, 1), until = worldstate.imod_until(c.ws, c.db, next)})
		return nil
	})
	// One cross-fade modifier is in force at a time; a new one fades the old out as it fades in.
	register(reg, "ImageSpaceModifier", "ApplyCrossFade", proc(c: ^Call, args: []Value) -> Value {
		fade := arg_f32(args, 0, 1)
		end_cross_fade(c.ws, fade)
		worldstate.play_visual(c.ws, {kind = .Imod, form = c.self, strength = 1, fade = fade, cross = true, until = worldstate.imod_until(c.ws, c.db, c.self)})
		return nil
	})
	register(reg, "ImageSpaceModifier", "RemoveCrossFade", proc(c: ^Call, args: []Value) -> Value {
		end_cross_fade(c.ws, arg_f32(args, 0, 1))
		return nil
	})
}

// play_on plays `form` on the ref in args[0] for `secs` seconds, or until stopped when secs <= 0.
@(private = "file")
play_on :: proc(c: ^Call, kind: worldstate.Visual_Kind, form: Form_ID, args: []Value, secs: f32, facing: Form_ID = 0) {
	ref := visual_ref(c, args, 0)
	if form == 0 || ref == 0 {return}
	until := c.ws.clock.played + f64(secs) if secs > 0 else 0
	worldstate.play_visual(c.ws, {kind = kind, form = form, ref = ref, facing = facing, until = until})
}

@(private = "file")
visual_ref :: proc(c: ^Call, args: []Value, i: int) -> Form_ID {
	return worldstate.resolve(c.ws, arg_form(c, args, i))
}

@(private = "file")
end_cross_fade :: proc(ws: ^worldstate.World_State, fade: f32) {
	for h, v in ws.visuals {
		if v.cross && v.until == 0 {worldstate.fade_visual(ws, h, fade)}
	}
}
