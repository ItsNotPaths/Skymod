package gamedb

// Music types (MUSC) and their tracks (MUST).

import "../formats/esm"

// (hole music-conditions :tags (audio records) :sev gap) a track's conditions (CITC/CTDA, on 48 vanilla MUSTs) are not read: every track of a type can play.

MUSIC_PLAYS_ONE :: 0x01 // FNAM: plays one track, then leaves
MUSIC_ABRUPT :: 0x02 // FNAM: starts without fading the music before it out
MUSIC_CYCLES :: 0x04 // FNAM: plays its tracks in order, not at random

Music_Type :: struct {
	flags:    u32, // FNAM, MUSIC_*
	priority: u16, // PNAM: the lowest number among the wanted types plays
	fade:     f32, // WNAM: seconds to fade the music before it out
	tracks:   []Form_ID, // TNAM, MUST (owned)
}

Music_Track_Kind :: enum u8 {
	Single,
	Palette, // plays one of its children, at random
	Silent, // plays nothing for its duration
}

Music_Track :: struct {
	kind:     Music_Track_Kind, // CNAM
	file:     string, // ANAM: "music\...\x.wav", lowercased (owned)
	duration: f32, // FLTV: a silent track's length, seconds
	children: []Form_ID, // SNAM: a palette's tracks (owned)
}

@(private)
index_music_type :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, seen := db.music_types[rec.form_id]; seen {delete(old.tracks, db.allocator)}
	t: Music_Type
	for f in fl {
		switch f.type {
		case "FNAM": t.flags, _ = esm.field_u32(f)
		case "PNAM": if len(f.data) >= 2 {t.priority = u16((^u16le)(&f.data[0])^)}
		case "WNAM": t.fade, _ = esm.field_f32(f)
		case "TNAM": t.tracks = form_list(f, fm, db.allocator)
		}
	}
	db.music_types[rec.form_id] = t
}

@(private)
index_music_track :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, seen := db.music_tracks[rec.form_id]; seen {free_music_track(db, old)}
	t: Music_Track
	for f in fl {
		switch f.type {
		case "CNAM":
			switch v, _ := esm.field_u32(f); v {
			case 0x23F678C3: t.kind = .Palette
			case 0xA1A9C4D5: t.kind = .Silent
			}
		case "ANAM": t.file = asset_path(f, "music\\", db.allocator)
		case "FLTV": t.duration, _ = esm.field_f32(f)
		case "SNAM": t.children = form_list(f, fm, db.allocator)
		}
	}
	db.music_tracks[rec.form_id] = t
}

// form_list reads a field that is an array of form ids, remapped.
@(private = "file")
form_list :: proc(f: esm.Field, fm: ^esm.Form_Map, allocator := context.allocator) -> []Form_ID {
	out := make([]Form_ID, len(f.data) / 4, allocator)
	for &o, i in out {o = esm.remap_form(fm, u32((^u32le)(&f.data[i * 4])^))}
	return out
}

@(private)
free_music_track :: proc(db: ^DB, t: Music_Track) {
	delete(t.file, db.allocator)
	delete(t.children, db.allocator)
}

@(private)
free_music_indexes :: proc(db: ^DB) {
	for _, t in db.music_types {delete(t.tracks, db.allocator)}
	delete(db.music_types)
	for _, t in db.music_tracks {free_music_track(db, t)}
	delete(db.music_tracks)
	delete(db.world_music)
}
