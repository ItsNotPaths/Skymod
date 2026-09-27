package audio

// What starts a sound. Records name the sound; these say when.

import "core:math/rand"
import "../formid"
import "../gamedb"
import "../vfs"
import "../worldstate"

// HEAD_Z is how far above an actor's origin its voice comes from, game units.
HEAD_Z :: 110

// (hole music-events :tags (audio quest) :sev gap) no event music: discovering a location, clearing a dungeon, levelling up, succeeding and dying (DOBJ DFMS, DCMS, LUMS, SCMS, DTMS) push no music type.

// Music plays the wanted music type's tracks, one after another. The wanted type is the one with
// the lowest priority number among those scripts added, battle music while the player is in
// combat (DOBJ BTMS), and the player's cell's type, else its worldspace's.
Music :: struct {
	current: formid.Form_ID, // the type playing
	track:   Handle,
	next:    int, // the type's next track, when it cycles
	wait:    f32, // a silent track's seconds left
	played:  bool, // a track of this type has started
}

music_update :: proc(m: ^Music, a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, ws: ^worldstate.World_State, in_combat: bool, dt: f32) {
	if a.device == 0 {return}
	if want := wanted_music(a, db, ws, in_combat); want != m.current {
		t := db.music_types[want]
		stop(a, m.track, 0 if t.flags & gamedb.MUSIC_ABRUPT != 0 else max(t.fade, 0.01))
		m^ = {current = want}
	}
	if m.current == 0 || playing(a, m.track) {return}
	if m.wait > 0 {
		m.wait -= dt
		return
	}
	t := db.music_types[m.current]
	if len(t.tracks) == 0 {return}
	if m.played && t.flags & gamedb.MUSIC_PLAYS_ONE != 0 {
		music_remove(a, m.current) // done; a place's type stays silent until the place changes
		return
	}
	i := m.next % len(t.tracks) if t.flags & gamedb.MUSIC_CYCLES != 0 else rand.int_max(len(t.tracks))
	m.next += 1
	m.played = true
	track := db.music_tracks[t.tracks[i]]
	for hops := 0; track.kind == .Palette && len(track.children) > 0 && hops < 4; hops += 1 {
		track = db.music_tracks[rand.choice(track.children)]
	}
	switch track.kind {
	case .Silent:
		m.wait = track.duration
	case .Single:
		if s, ok := open(v, track.file); ok {m.track = play(a, s, gamedb.sound_volume(db, gamedb.default_object(db, "MDSC")))}
	case .Palette:
	}
}

@(private = "file")
wanted_music :: proc(a: ^Audio, db: ^gamedb.DB, ws: ^worldstate.World_State, in_combat: bool) -> formid.Form_ID {
	best, best_priority := formid.Form_ID(0), max(u16)
	consider :: proc(db: ^gamedb.DB, t: formid.Form_ID, best: ^formid.Form_ID, best_priority: ^u16) {
		if mt, ok := db.music_types[t]; ok && mt.priority < best_priority^ {best^, best_priority^ = t, mt.priority}
	}
	for t in music_wanted(a) {consider(db, t, &best, &best_priority)}
	if in_combat {consider(db, gamedb.default_object(db, "BTMS"), &best, &best_priority)}
	cell := db.cells[worldstate.ref_cell(ws, db, formid.PLAYER)]
	consider(db, cell.music if cell.music != 0 else db.world_music[cell.world_form_id], &best, &best_priority)
	return best
}

// (hole region-sounds :tags (audio world) :sev gap :needs (weather-select)) region sounds (REGN RDSA: 687 entries over 53 regions, each by weather and chance) do not play: nothing selects a weather.
// (hole acoustic-boxes :tags (audio world) :sev gap) placed acoustic spaces (125 ASPC refs, a box each) are not entered: only a cell's own space (XCAS) plays, and no space's reverb (RDAT) applies.

// Ambient is what plays because of where the listener is: the looping sound markers, activators and
// lights in earshot, and the loop of the player's cell's acoustic space.
Ambient :: struct {
	markers: map[formid.Form_ID]Handle, // placed SOUN refs playing now
	space:   formid.Form_ID, // the acoustic space whose loop plays
	loop:    Handle,
	frame:   int,
}

// MARKER_SCAN_FRAMES is how often ambient_update walks the attached cells for sound markers.
MARKER_SCAN_FRAMES :: 10

ambient_update :: proc(am: ^Ambient, a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, ws: ^worldstate.World_State) {
	if a.device == 0 {return}
	if space := db.cells[worldstate.ref_cell(ws, db, formid.PLAYER)].acoustic; space != am.space {
		stop(a, am.loop)
		am.space, am.loop = space, play_descriptor(a, v, db, db.acoustic_loops[space])
	}
	am.frame += 1
	if am.frame % MARKER_SCAN_FRAMES != 0 {return}
	want := make(map[formid.Form_ID]bool, context.temp_allocator)
	for cell in ws.attached {
		for r in db.cell_refs[cell] {
			sndr := db.sound_markers[r.base] or_else db.base_sounds[r.base].loop // a marker, else an activator's or light's loop
			d := db.sounds[sndr]
			if sndr == 0 || d.loop == .None || !worldstate.ref_enabled(ws, db, r.form_id) {continue}
			out := db.sound_outputs[d.output]
			dist := distance(a, r.pos)
			_, playing := am.markers[r.form_id]
			// Stops a little past where it starts, so a marker at the edge does not flutter.
			if gamedb.output_level(out, dist) == 0 && !(playing && out.attenuates && dist < out.max * 1.1) {continue}
			want[r.form_id] = true
			if !playing {am.markers[r.form_id] = play_descriptor(a, v, db, sndr, r.pos)}
		}
	}
	gone := make([dynamic]formid.Form_ID, context.temp_allocator)
	for ref in am.markers {
		if ref not_in want {append(&gone, ref)}
	}
	for ref in gone {
		stop(a, am.markers[ref])
		delete_key(&am.markers, ref)
	}
}

ambient_destroy :: proc(am: ^Ambient) {
	delete(am.markers)
}

// (hole drop-sounds :tags (audio ui) :sev gap) putting an item down makes no sound: nothing drops an item into the world yet.
// activate_sound plays the sound of a ref's base where the ref is, when it is used (a door or
// container opens, an item is picked up), or with done when done with (a container closes).
activate_sound :: proc(a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, ws: ^worldstate.World_State, ref: formid.Form_ID, done := false) {
	play_descriptor(a, v, db, gamedb.base_sound(db, worldstate.ref_base(ws, db, ref), done), worldstate.ref_pos(ws, db, ref))
}

// (hole impact-sounds :tags (audio combat) :sev gap) a hit makes no sound: IPDS (220) and IPCT (515) are not decoded, and no surface material picks the row. Melee hits wait on combat-damage.
impact_sound :: proc(db: ^gamedb.DB, source, target: formid.Form_ID, pos: [3]f32) {}

// (hole anim-sounds :tags (audio animation unclaimed) :sev gap :needs (hkx-porter)) no animation plays a sound: SoundPlay/SoundStop/SoundPlayAt annotations (727 SNDR names over 800 SE clips; 90 of 183 dragon clips), weaponSwing (the WEAP attack sound) and FootLeft/FootRight (FSTS/FSTP footstep sets, by gait and ground material; not decoded) have no animation to fire them.
anim_sound :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, actor: formid.Form_ID, event: string) {}

// (hole ui-sounds :tags (audio ui) :sev gap) menus are silent: Skyrim's menus play SNDRs by editor ID (UIMenuOK...), and the Lua UI has no call to play one.
ui_sound :: proc(db: ^gamedb.DB, edid: string) {}

// say plays one response of a topic info in the speaker's voice, at the dialogue category's
// volume (DOBJ DDSC): placed at the speaker's head under the 3D dialogue model (DOP2), else flat.
// The voice file is the info's own, else that of the info it shares (DNAM). Its handle and
// length in seconds; 0, 0 when the line has no voice file.
say :: proc(a: ^Audio, v: ^vfs.VFS, db: ^gamedb.DB, ws: ^worldstate.World_State, speaker, info: formid.Form_ID, number: u8, placed: bool) -> (Handle, f32) {
	if a.device == 0 {return 0, 0}
	at: Maybe(Placement)
	if placed {
		p := Placement{worldstate.ref_pos(ws, db, speaker) + {0, 0, HEAD_Z}, db.sound_outputs[gamedb.default_object(db, "DOP2")]}
		if gamedb.output_level(p.output, distance(a, p.pos)) == 0 {return 0, 0} // out of earshot
		at = p
	}
	voice := worldstate.actor_voice(ws, db, speaker)
	s, ok := open(v, gamedb.voice_path(db, voice, info, number))
	if shared := db.infos[info].shared; !ok && shared != 0 {s, ok = open(v, gamedb.voice_path(db, voice, shared, number))}
	if !ok {return 0, 0}
	secs := seconds(s)
	return play(a, s, gamedb.sound_volume(db, gamedb.default_object(db, "DDSC")), at = at), secs
}
