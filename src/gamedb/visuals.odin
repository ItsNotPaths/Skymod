package gamedb

// The visual records scripts and effects play: image space modifiers (IMAD), impacts (IPCT, IPDS)
// and visual effects (RFCT). Only what the sim needs to keep a visual's state; the art itself is
// the graphics plugin's to read.

import "../formats/esm"

// Visual_Effect is an RFCT: the art it plays and the shader it plays with it; 0 = none.
// (hole rfct-flags :tags (vfx records) :sev polish) an RFCT's flags (face target, attach to camera, inherit rotation; 32 vanilla attach to the camera) do not reach the graphics seam.
Visual_Effect :: struct {
	art, shader: Form_ID,
}

// imod_duration is how long an Apply of an IMAD plays, in seconds; 0 = a hold modifier, on until
// removed (FadeToBlackHoldImod).
imod_duration :: proc(db: ^DB, imod: Form_ID) -> f32 {
	return db.imod_durations[imod]
}

// impact_duration is the longest effect duration of an IPDS's impacts.
impact_duration :: proc(db: ^DB, set: Form_ID) -> f32 {
	longest: f32
	impacts, _ := db.impact_sets[set]
	for ipct in impacts {longest = max(longest, db.impact_durations[ipct])}
	return longest
}

// index_imod reads an IMAD's DNAM: animatable u32@0 (bit 0), duration f32@4. (SE Skyrim.esm: 111
// of 170 are animatable; the rest are hold modifiers.)
@(private)
index_imod :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	f, has := esm.find_field(fl, "DNAM")
	if !has || len(f.data) < 8 {return}
	animatable := u32((^u32le)(&f.data[0])^) & 1 != 0
	db.imod_durations[rec.form_id] = f32((^f32le)(&f.data[4])^) if animatable else 0
}

// index_impact reads an IPCT's effect duration, f32@0 of DATA.
@(private)
index_impact :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if f, has := esm.find_field(fl, "DATA"); has && len(f.data) >= 4 {
		db.impact_durations[rec.form_id] = f32((^f32le)(&f.data[0])^)
	}
}

// index_impact_set reads an IPDS's impacts: one PNAM per material, (MATT u32, IPCT u32).
@(private)
index_impact_set :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	impacts := make([dynamic]Form_ID, db.allocator)
	for f in fl {
		if f.type == "PNAM" && len(f.data) >= 8 {append(&impacts, esm.remap_form(fm, u32((^u32le)(&f.data[4])^)))}
	}
	if old, had := db.impact_sets[rec.form_id]; had {delete(old, db.allocator)} // an override replaces the list
	db.impact_sets[rec.form_id] = impacts[:]
}

// index_visual_effect reads an RFCT's DATA: ARTO u32@0, EFSH u32@4, flags u32@8.
@(private)
index_visual_effect :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	f, has := esm.find_field(fl, "DATA")
	if !has || len(f.data) < 8 {return}
	db.visual_effects[rec.form_id] = {
		art    = esm.remap_form(fm, u32((^u32le)(&f.data[0])^)),
		shader = esm.remap_form(fm, u32((^u32le)(&f.data[4])^)),
	}
}

@(private)
free_visual_indexes :: proc(db: ^DB) {
	delete(db.imod_durations)
	delete(db.impact_durations)
	for _, list in db.impact_sets {delete(list, db.allocator)}
	delete(db.impact_sets)
	delete(db.visual_effects)
}
