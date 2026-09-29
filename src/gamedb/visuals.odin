package gamedb

// The visual records scripts and effects play: effect shaders (EFSH), art objects (ARTO), impacts
// (IPCT, IPDS), image space modifiers (IMAD) and visual effects (RFCT). The sim reads their
// durations; the graphics seam reads the rest through record views.

import "core:mem"
import "core:strings"
import "../formats/esm"

Effect_Shader :: struct {
	fill_texture, particle_texture, holes_texture, membrane_palette, particle_palette: string, // (owned)
	data:          esm.Effect_Shader_Data,
	addon_models:  Form_ID, // DEBR
	ambient_sound: Form_ID, // SNDR or SOUN
}

// Art_Kind is an ARTO's DNAM.
Art_Kind :: enum u32 {
	Magic_Casting,
	Magic_Hit,
	Enchantment,
}

Art_Object :: struct {
	model: string, // (owned)
	kind:  Art_Kind,
}

Impact :: struct {
	model:        string, // (owned)
	data:         esm.Impact_Data,
	decal:        esm.Decal,
	has_decal:    bool,
	texture_sets: [2]Form_ID, // DNAM, ENAM (TXST)
	sounds:       [2]Form_ID, // SNAM, NAM1
	hazard:       Form_ID, // NAM2
}

// Impact_Entry is one IPDS entry: the impact on a surface of `material` (MATT).
Impact_Entry :: struct {
	material, impact: Form_ID,
}

Imod :: struct {
	info:   esm.Imod_Info,
	curves: [esm.Imod_Curve][]esm.Keyframe, // (owned)
	tint:   []esm.Color_Keyframe, // TNAM (owned)
	fade:   []esm.Color_Keyframe, // NAM3 (owned)
}

// Visual_Effect is an RFCT: the art it plays and the shader it plays with it; 0 = none.
Visual_Effect :: struct {
	art, shader: Form_ID,
	flags:       u32, // RFCT_*
}

RFCT_FACE_TARGET :: 0x1
RFCT_ATTACH_TO_CAMERA :: 0x2
RFCT_INHERIT_ROTATION :: 0x4

// imod_duration is how long an Apply of an IMAD plays, in seconds; 0 = a hold modifier, on until
// removed (FadeToBlackHoldImod).
imod_duration :: proc(db: ^DB, imod: Form_ID) -> f32 {
	m, ok := db.imods[imod]
	return m.info.duration if ok && m.info.animatable else 0
}

// impact_duration is the longest effect duration of an IPDS's impacts.
impact_duration :: proc(db: ^DB, set: Form_ID) -> (longest: f32) {
	entries, _ := db.impact_sets[set]
	for e in entries {
		if i, ok := db.impacts[e.impact]; ok {longest = max(longest, i.data.duration)}
	}
	return
}

@(private)
index_effect_shader :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	e: Effect_Shader
	texts := [?]struct {tag: string, to: ^string} {
		{"ICON", &e.fill_texture}, {"ICO2", &e.particle_texture}, {"NAM7", &e.holes_texture},
		{"NAM8", &e.membrane_palette}, {"NAM9", &e.particle_palette},
	}
	for t in texts {
		if f, has := esm.find_field(fl, t.tag); has {t.to^ = own(db, esm.cstr(f.data))}
	}
	if f, has := esm.find_field(fl, "DATA"); has {
		e.data = esm.effect_shader_data(f.data)
		e.addon_models = data_form(fm, f.data, esm.EFSH_ADDON_MODELS_AT)
		e.ambient_sound = data_form(fm, f.data, esm.EFSH_AMBIENT_SOUND_AT)
	}
	if old, had := db.effect_shaders[rec.form_id]; had {free_effect_shader(db, old)}
	db.effect_shaders[rec.form_id] = e
}

@(private)
index_art_object :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	a := Art_Object{model = own(db, esm.model_path(fl))}
	if f, has := esm.find_field(fl, "DNAM"); has && len(f.data) >= 4 {a.kind = Art_Kind(u32((^u32le)(&f.data[0])^))}
	if old, had := db.art_objects[rec.form_id]; had {delete(old.model, db.allocator)}
	db.art_objects[rec.form_id] = a
}

@(private)
index_impact :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	i := Impact{model = own(db, esm.model_path(fl))}
	if f, has := esm.find_field(fl, "DATA"); has {i.data = esm.impact_data(f.data)}
	if f, has := esm.find_field(fl, "DODT"); has {i.decal, i.has_decal = esm.decal(f.data), true}
	links := [?]struct {tag: string, to: ^Form_ID} {
		{"DNAM", &i.texture_sets[0]}, {"ENAM", &i.texture_sets[1]}, {"SNAM", &i.sounds[0]}, {"NAM1", &i.sounds[1]}, {"NAM2", &i.hazard},
	}
	for l in links {
		if raw, has := esm.subrecord_formid(fl, l.tag); has {l.to^ = esm.remap_form(fm, raw)}
	}
	if old, had := db.impacts[rec.form_id]; had {delete(old.model, db.allocator)}
	db.impacts[rec.form_id] = i
}

// index_impact_set reads an IPDS's entries: one PNAM per material, (MATT u32, IPCT u32).
@(private)
index_impact_set :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	entries := make([dynamic]Impact_Entry, db.allocator)
	for f in fl {
		if f.type == "PNAM" && len(f.data) >= 8 {
			append(&entries, Impact_Entry{data_form(fm, f.data, 0), data_form(fm, f.data, 4)})
		}
	}
	if old, had := db.impact_sets[rec.form_id]; had {delete(old, db.allocator)} // an override replaces the list
	db.impact_sets[rec.form_id] = entries[:]
}

// index_imod reads an IMAD: DNAM, then each curve's keyframes from its own subrecord.
@(private)
index_imod :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	f, has := esm.find_field(fl, "DNAM")
	if !has {return}
	info, iok := esm.imod_info(f.data)
	if !iok {return}
	m := Imod{info = info}
	for tag, c in esm.IMOD_CURVE_TAGS {m.curves[c] = keyframes(db, fl, tag, esm.Keyframe)}
	m.tint = keyframes(db, fl, "TNAM", esm.Color_Keyframe)
	m.fade = keyframes(db, fl, "NAM3", esm.Color_Keyframe)
	if old, had := db.imods[rec.form_id]; had {free_imod(db, old)}
	db.imods[rec.form_id] = m
}

// index_visual_effect reads an RFCT's DATA: ARTO u32@0, EFSH u32@4, flags u32@8.
@(private)
index_visual_effect :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	f, has := esm.find_field(fl, "DATA")
	if !has || len(f.data) < 12 {return}
	db.visual_effects[rec.form_id] = {data_form(fm, f.data, 0), data_form(fm, f.data, 4), u32((^u32le)(&f.data[8])^)}
}

// data_form is the form ID at `at` in a data block; 0 past a short block's end.
@(private = "file")
data_form :: proc(fm: ^esm.Form_Map, d: []u8, at: int) -> Form_ID {
	return esm.remap_form(fm, u32((^u32le)(&d[at])^)) if at + 4 <= len(d) else 0
}

@(private = "file")
own :: proc(db: ^DB, s: string) -> string {
	return strings.clone(s, db.allocator) if s != "" else ""
}

// keyframes copies the packed keyframes of subrecord `tag` into DB memory; nil when absent.
@(private = "file")
keyframes :: proc(db: ^DB, fl: []esm.Field, tag: string, $T: typeid) -> []T {
	f, has := esm.find_field(fl, tag)
	if !has || len(f.data) < size_of(T) {return nil}
	out := make([]T, len(f.data) / size_of(T), db.allocator)
	mem.copy(raw_data(out), raw_data(f.data), len(out) * size_of(T))
	return out
}

@(private = "file")
free_effect_shader :: proc(db: ^DB, e: Effect_Shader) {
	for s in ([]string{e.fill_texture, e.particle_texture, e.holes_texture, e.membrane_palette, e.particle_palette}) {delete(s, db.allocator)}
}

@(private = "file")
free_imod :: proc(db: ^DB, m: Imod) {
	for c in m.curves {delete(c, db.allocator)}
	delete(m.tint, db.allocator)
	delete(m.fade, db.allocator)
}

@(private)
free_visual_indexes :: proc(db: ^DB) {
	for _, e in db.effect_shaders {free_effect_shader(db, e)}
	delete(db.effect_shaders)
	for _, a in db.art_objects {delete(a.model, db.allocator)}
	delete(db.art_objects)
	for _, i in db.impacts {delete(i.model, db.allocator)}
	delete(db.impacts)
	for _, list in db.impact_sets {delete(list, db.allocator)}
	delete(db.impact_sets)
	for _, m in db.imods {free_imod(db, m)}
	delete(db.imods)
	delete(db.visual_effects)
}
