package worldhost

import "../gamedb"
import "../plugin"

@(private)
view_effect_shader :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Effect_Shader, ok: bool) {
	e := db.effect_shaders[form] or_return
	v = {
		fill_texture = str(e.fill_texture), particle_texture = str(e.particle_texture), holes_texture = str(e.holes_texture),
		membrane_palette = str(e.membrane_palette), particle_palette = str(e.particle_palette),
		data = e.data, addon_models = e.addon_models, ambient_sound = e.ambient_sound,
	}
	return v, true
}

@(private)
view_art_object :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Art_Object, ok: bool) {
	a := db.art_objects[form] or_return
	return {model = str(a.model), kind = u32(a.kind)}, true
}

@(private)
view_impact :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Impact, ok: bool) {
	i := db.impacts[form] or_return
	v = {
		model = str(i.model), data = i.data, decal = i.decal, has_decal = i.has_decal,
		texture_sets = i.texture_sets, sounds = i.sounds, hazard = i.hazard,
	}
	return v, true
}

@(private)
view_impact_set :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Impact_Set, ok: bool) {
	entries := db.impact_sets[form] or_return
	out := make([]plugin.Impact_Entry, len(entries), context.temp_allocator)
	for e, i in entries {out[i] = {e.material, e.impact}}
	return {entries = plugin.span(out)}, true
}

@(private)
view_imod :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Image_Space_Modifier, ok: bool) {
	m := db.imods[form] or_return
	v = {info = m.info, tint = plugin.span(m.tint), fade = plugin.span(m.fade)}
	for c, k in m.curves {v.curves[k] = plugin.span(c)}
	return v, true
}

@(private)
view_visual_effect :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Visual_Effect, ok: bool) {
	e := db.visual_effects[form] or_return
	return {art = e.art, shader = e.shader, flags = e.flags}, true
}
