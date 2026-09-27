package gamedb

// Sound descriptors (SNDR), the sound markers' bases (SOUN) and sound categories (SNCT).

import "core:strings"
import "../formats/esm"

// (hole sound-conditions :tags (audio records) :sev gap) a descriptor's conditions (CTDA, on 336 vanilla SNDRs) and its Alternate Sound For (SNAM, 247) are not read: every descriptor plays its own files, always.

Sound_Loop :: enum u8 {
	None,
	Loop,
	Envelope_Fast,
	Envelope_Slow,
}

Sound_Descriptor :: struct {
	files:         []string, // ANAM variants, one picked per play: "sound\fx\...\x.wav", lowercased (owned)
	category:      Form_ID, // GNAM (SNCT)
	output:        Form_ID, // ONAM (SOPM)
	loop:          Sound_Loop, // LNAM
	freq_shift:    f32, // BNAM, a fraction of the file's rate: 0.1 plays 10% faster
	freq_variance: f32, // BNAM: up to this fraction faster or slower, per play
	priority:      u8,
	db_variance:   f32, // BNAM: up to this many dB quieter, per play
	attenuation:   f32, // BNAM: static attenuation, dB
}

// Sound_Output is an output model (SOPM): how a sound falls off with distance, and whether it pans.
Sound_Output :: struct {
	min, max:   f32, // ANAM, game units: the curve's first and last point
	curve:      [5]f32, // ANAM: the level at 5 even steps from min to max, 0..1
	attenuates: bool, // NAM1 bit 0
	pans:       bool, // MNAM 0 (mono / 3D); 1 is defined speaker output, which does not pan
}

// output_level is a sound's level at distance d under an output model.
output_level :: proc(o: Sound_Output, d: f32) -> f32 {
	if !o.attenuates || o.max <= o.min {return 1}
	t := clamp((d - o.min) / (o.max - o.min), 0, 1) * 4
	i := min(int(t), 3)
	return o.curve[i] + (o.curve[i + 1] - o.curve[i]) * (t - f32(i))
}

Sound_Category :: struct {
	parent: Form_ID, // PNAM
	volume: f32, // VNAM, 0..1
}

// sound_volume is a category's volume times its parents'.
sound_volume :: proc(db: ^DB, category: Form_ID) -> f32 {
	v := f32(1)
	c := category
	for hops := 0; c != 0 && hops < 8; hops += 1 {
		sc, ok := db.sound_categories[c]
		if !ok {break}
		v *= sc.volume
		c = sc.parent
	}
	return v
}

// Base_Sounds are the sounds a base form plays when used (a door or container opens, an
// activator is used, a plant harvested, an item picked up) and when done with (a door or container
// closes, an item is put down). A zero sound falls back to the DOBJ default named in `defaults`.
Base_Sounds :: struct {
	use, done: Form_ID,
	defaults:  [2]string, // DOBJ keys ("PUSW", "PDSW"), literals
}

// base_sound is the sound a base plays when used, or with done when done with; 0 for none.
base_sound :: proc(db: ^DB, base: Form_ID, done := false) -> Form_ID {
	bs, ok := db.base_sounds[base]
	if !ok {return 0}
	s := bs.done if done else bs.use
	return s if s != 0 else default_object(db, bs.defaults[1 if done else 0])
}

// index_base_sounds reads the sounds of a DOOR, CONT, ACTI, FLOR or item base. An item's own
// pickup and put-down (YNAM, ZNAM) fall back to its kind's DOBJ default.
@(private)
index_base_sounds :: proc(db: ^DB, rec: esm.Record, fl: []esm.Field, fm: ^esm.Form_Map) {
	sound :: proc(fl: []esm.Field, fm: ^esm.Form_Map, tag: string) -> Form_ID {
		v, ok := esm.subrecord_formid(fl, tag)
		return esm.remap_form(fm, v) if ok else 0
	}
	bs: Base_Sounds
	switch rec.type {
	case "DOOR": bs = {use = sound(fl, fm, "SNAM"), done = sound(fl, fm, "ANAM")}
	case "CONT": bs = {use = sound(fl, fm, "SNAM"), done = sound(fl, fm, "QNAM")}
	case "ACTI": bs = {use = sound(fl, fm, "VNAM")}
	case "FLOR": bs = {use = sound(fl, fm, "SNAM")}
	case "WEAP": bs = {defaults = {"PUSW", "PDSW"}}
	case "ARMO": bs = {defaults = {"PUSA", "PDSA"}}
	case "BOOK": bs = {defaults = {"PUSB", "PDSB"}}
	case "INGR": bs = {defaults = {"PUSI", "PDSI"}}
	case "MISC", "ALCH", "KEYM", "AMMO", "SLGM", "SCRL": bs = {defaults = {"PUSG", "PDSG"}}
	case: return
	}
	if bs.defaults[0] != "" {bs.use, bs.done = sound(fl, fm, "YNAM"), sound(fl, fm, "ZNAM")}
	if bs == {} {return}
	db.base_sounds[rec.form_id] = bs
}

// default_object is the form the DOBJ record names under an engine key ("PUSG", "DMWL").
default_object :: proc(db: ^DB, key: string) -> Form_ID {
	k: [4]u8
	copy(k[:], key)
	return db.defaults[k]
}

@(private)
index_sound_descriptor :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, seen := db.sounds[rec.form_id]; seen {free_sound(db, old)}
	s: Sound_Descriptor
	files := make([dynamic]string, db.allocator)
	for f in fl {
		switch f.type {
		case "ANAM":
			name := strings.to_lower(strings.trim_right_null(string(f.data)), context.temp_allocator)
			name = strings.trim_prefix(strings.trim_left(name, "\\"), "data\\") // "\data\sound\fx\..." and "fx\..." both name sound\fx\...
			if !strings.has_prefix(name, "sound\\") {name = strings.concatenate({"sound\\", name}, context.temp_allocator)}
			append(&files, strings.clone(name, db.allocator))
		case "GNAM":
			if v, vok := esm.field_u32(f); vok {s.category = esm.remap_form(fm, v)}
		case "ONAM":
			if v, vok := esm.field_u32(f); vok {s.output = esm.remap_form(fm, v)}
		case "LNAM":
			if len(f.data) >= 2 {
				switch f.data[1] {
				case 0x08: s.loop = .Loop
				case 0x10: s.loop = .Envelope_Fast
				case 0x20: s.loop = .Envelope_Slow
				}
			}
		case "BNAM":
			if len(f.data) < 6 {continue}
			s.freq_shift = f32(i8(f.data[0])) / 100
			s.freq_variance = f32(i8(f.data[1])) / 100
			s.priority = f.data[2]
			s.db_variance = f32(f.data[3])
			s.attenuation = f32(u16((^u16le)(&f.data[4])^)) / 100
		}
	}
	s.files = files[:]
	db.sounds[rec.form_id] = s
}

// index_sound_marker records a SOUN's descriptor (SDSC).
@(private)
index_sound_marker :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if v, vok := esm.subrecord_formid(fl, "SDSC"); vok {db.sound_markers[rec.form_id] = esm.remap_form(fm, v)}
}

@(private)
index_sound_output :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	o: Sound_Output
	if f, has := esm.find_field(fl, "ANAM"); has && len(f.data) >= 17 {
		o.min = f32((^f32le)(&f.data[4])^)
		o.max = f32((^f32le)(&f.data[8])^)
		for i in 0 ..< 5 {o.curve[i] = f32(f.data[12 + i]) / 100}
	}
	if f, has := esm.find_field(fl, "NAM1"); has && len(f.data) >= 1 {o.attenuates = f.data[0] & 1 != 0}
	if f, has := esm.find_field(fl, "MNAM"); has && len(f.data) >= 1 {o.pans = f.data[0] == 0}
	db.sound_outputs[rec.form_id] = o
}

@(private)
index_sound_category :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	c := Sound_Category{volume = 1}
	if v, vok := esm.subrecord_formid(fl, "PNAM"); vok {c.parent = esm.remap_form(fm, v)}
	if f, has := esm.find_field(fl, "VNAM"); has && len(f.data) >= 2 {c.volume = f32(u16((^u16le)(&f.data[0])^)) / 65535}
	db.sound_categories[rec.form_id] = c
}

// index_default_objects keeps every DOBJ pair (DNAM: 4-byte engine key, form).
@(private)
index_default_objects :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	dnam, has := esm.find_field(fl, "DNAM")
	if !has {return}
	for i := 0; i + 8 <= len(dnam.data); i += 8 {
		k: [4]u8
		copy(k[:], dnam.data[i:i + 4])
		db.defaults[k] = esm.remap_form(fm, u32((^u32le)(&dnam.data[i + 4])^))
	}
}

@(private)
free_sound :: proc(db: ^DB, s: Sound_Descriptor) {
	for f in s.files {delete(f, db.allocator)}
	delete(s.files, db.allocator)
}

@(private)
free_sound_indexes :: proc(db: ^DB) {
	for _, s in db.sounds {free_sound(db, s)}
	delete(db.sounds)
	delete(db.sound_markers)
	delete(db.sound_categories)
	delete(db.sound_outputs)
	delete(db.base_sounds)
	delete(db.defaults)
}
