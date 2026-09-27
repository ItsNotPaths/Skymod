package worldstate

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
