package worldstate

import "../gamedb"

// Awareness is what one actor knows of another: `level` 0..1 and whether that counts as detected.
// The detection model writes both; everyone else reads `detected`.
Awareness :: struct {
	level:    f32,
	detected: bool,
}

awareness :: proc(ws: ^World_State, viewer, target: Form_ID) -> Awareness {
	return ws.awareness[{viewer, target}]
}

// detected is GetDetected and IsDetectedBy: the viewer has detected the target.
detected :: proc(ws: ^World_State, viewer, target: Form_ID) -> bool {
	return ws.awareness[{viewer, target}].detected
}

// (hole detection-events :tags (ai dialogue) :sev gap) a pair turning detected or lost is not announced: no moment for AlertIdle / LostToNormal lines or for an NPC to turn and search.
// set_awareness stores a pair; a pair that knows nothing is dropped.
set_awareness :: proc(ws: ^World_State, viewer, target: Form_ID, a: Awareness) {
	if a == {} {
		delete_key(&ws.awareness, [2]Form_ID{viewer, target})
		return
	}
	ws.awareness[{viewer, target}] = a
}

// Noise is a sound that detection can hear: `owner` made it at `pos` in `space`. `loudness` is on
// the iSoundLevel scale that CreateDetectionEvent's aiSoundLevel uses.
Noise :: struct {
	owner, space: Form_ID,
	pos:          [3]f32,
	loudness:     f32,
}

Sound_Level :: enum {
	Silent,
	Normal,
}

// (hole sound-level-normal :tags (ai audio) :sev polish) unsourced: Skyrim.esm has only iSoundLevelSilent (10); iSoundLevelNormal 50 is a guess at the engine default.
sound_level :: proc(db: ^gamedb.DB, l: Sound_Level) -> f32 {
	switch l {
	case .Silent: return f32(gamedb.setting_int(db, "iSoundLevelSilent", 10))
	case .Normal: return f32(gamedb.setting_int(db, "iSoundLevelNormal", 50))
	}
	return 0
}

// make_noise is `owner` making a sound at the ref `at`.
make_noise :: proc(ws: ^World_State, db: ^gamedb.DB, owner, at: Form_ID, loudness: f32) {
	append(&ws.noises, Noise{owner, ref_space(ws, db, at), ref_pos(ws, db, at), loudness})
}
