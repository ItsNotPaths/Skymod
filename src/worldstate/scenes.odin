package worldstate

// Playing scenes (CK Category:Scenes). A scene waits until its actors are free, then runs its
// phases in order; each phase runs the actions that start in it until it completes.

import "../gamedb"

Scene_Run :: struct {
	phase:    i32, // the phase running; -1 before the first
	begun:    bool, // its Begin fragment ran; a scene that waits for its actors has not
	force:    bool, // ForceStart: it stops the scenes that hold its actors
	stopping: bool, // Stop was called: it ends at the next tick
	actions:  [dynamic]Action_Run, // the actions started this run
}

// Action_Run is one action of a playing scene. A dialogue action says `info`, response by
// response; a looping one waits `left` seconds with no info between lines.
Action_Run :: struct {
	index:    u32, // the action's INAM
	done:     bool, // IsActionComplete
	left:     f32, // seconds left on the timer, the response on screen, or the loop's wait
	info:     Form_ID,
	response: i32,
	speaker:  Form_ID,
}

scene_playing :: proc(ws: ^World_State, scene: Form_ID) -> bool {
	run, ok := ws.scenes[scene]
	return ok && run.begun
}

scene_action_done :: proc(ws: ^World_State, scene: Form_ID, index: u32) -> bool {
	run, ok := ws.scenes[scene]
	if !ok {return false}
	for a in run.actions {
		if a.index == index {return a.done}
	}
	return false
}

// scene_of_actor is the playing scene `ref` acts in; 0 when none. An actor is in one at a time.
scene_of_actor :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> Form_ID {
	if ref == 0 {return 0}
	for scene, run in ws.scenes {
		if !run.begun {continue}
		s := db.scenes[scene]
		for a in s.actors {
			if alias_ref(ws, s.quest, a.alias) == ref {return scene}
		}
	}
	return 0
}

@(private)
free_scene_runs :: proc(runs: ^map[Form_ID]Scene_Run) {
	for _, r in runs {delete(r.actions)}
	clear(runs)
}
