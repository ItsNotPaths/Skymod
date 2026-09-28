package script_lua

// Scenes play here, one tick at a time (CK Category:Scenes). A queued scene waits until its actors
// are free, then runs its Begin fragment and its phases in order. A phase whose start conditions
// fail is skipped; one that starts runs its start fragment, then its actions, and completes when
// its completion conditions pass or, with none, when every action that ends in it is done.

import "core:math/rand"
import "core:slice"
import script ".."
import "../../audio"
import "../../conditions"
import "../../dialogue"
import "../../formats/esm"
import "../../formid"
import "../../gamedb"
import "../../worldstate"

tick_scenes :: proc(vm: ^VM, dt: f32) {
	ws := vm.ctx.ws
	scenes := make([dynamic]script.Form_ID, 0, len(ws.scenes), context.temp_allocator)
	for scene in ws.scenes {append(&scenes, scene)}
	slice.sort(scenes[:])
	for scene in scenes {
		if scene in ws.scenes {step_scene(vm, scene, dt)} // an earlier scene may have ended it
	}
}

Behavior :: enum {
	Play,
	Pause,
	End,
}

// step_scene plays one tick of a scene. Fragments run Lua that may start or stop scenes, so the
// run is looked up again after each.
@(private = "file")
step_scene :: proc(vm: ^VM, scene: script.Form_ID, dt: f32) {
	ws, db := vm.ctx.ws, vm.ctx.db
	s := db.scenes[scene]
	run := &ws.scenes[scene]
	if run.stopping || !worldstate.quest_running(ws, db, s.quest) {
		end_scene(vm, scene)
		return
	}
	if !run.begun {
		if !actors_free(vm, scene, s, run.force) {return}
		run.begun = true
		record_fragment(vm, scene, 0, 0) // Begin
		enter_phase(vm, scene, 0)
		return
	}
	if run.phase < 0 { // repeating
		enter_phase(vm, scene, 0)
		return
	}
	switch behavior(vm, s) {
	case .End:
		end_scene(vm, scene)
		return
	case .Pause:
		return
	case .Play:
	}
	advance_actions(vm, scene, s, dt)
	if phase_complete(vm, s, ws.scenes[scene]) {
		phase := ws.scenes[scene].phase
		record_fragment(vm, scene, u16(phase), esm.PHASE_ON_COMPLETION)
		if scene in ws.scenes {enter_phase(vm, scene, phase + 1)}
	}
}

// actors_free: no actor the scene needs is in another scene. Another scene that is Interruptible
// (and this one is not), or any scene for a ForceStart, ends to free its actors.
@(private = "file")
actors_free :: proc(vm: ^VM, scene: script.Form_ID, s: gamedb.Scene, force: bool) -> bool {
	ws, db := vm.ctx.ws, vm.ctx.db
	for a in s.actors {
		if a.flags & gamedb.SCENE_ACTOR_OPTIONAL != 0 {continue}
		other := worldstate.scene_of_actor(ws, db, worldstate.alias_ref(ws, s.quest, a.alias))
		if other == 0 || other == scene {continue}
		interrupts := db.scenes[other].flags & gamedb.SCENE_INTERRUPTIBLE != 0 && s.flags & gamedb.SCENE_INTERRUPTIBLE == 0
		if !force && !interrupts {return false}
		end_scene(vm, other)
	}
	return true
}

// behavior applies the actors' behaviour flags: a death ends the scene when it says so, and an
// actor talking to the player pauses or ends it.
@(private = "file")
behavior :: proc(vm: ^VM, s: gamedb.Scene) -> Behavior {
	ws := vm.ctx.ws
	out := Behavior.Play
	for a in s.actors {
		ref := worldstate.alias_ref(ws, s.quest, a.alias)
		if ref == 0 {continue}
		if worldstate.is_dead(ws, vm.ctx.db, ref) && a.behavior & gamedb.SCENE_DEATH_END != 0 {return .End}
		if ws.talking != ref {continue}
		if a.behavior & gamedb.SCENE_DIALOGUE_END != 0 {return .End}
		if a.behavior & gamedb.SCENE_DIALOGUE_PAUSE != 0 {out = .Pause}
	}
	return out
}

// enter_phase starts the first phase from `from` whose start conditions pass: its start fragment,
// then the actions that start in it. Past the last phase the scene repeats or ends.
@(private = "file")
enter_phase :: proc(vm: ^VM, scene: script.Form_ID, from: i32) {
	ws, db := vm.ctx.ws, vm.ctx.db
	s := db.scenes[scene]
	for p := from; int(p) < len(s.phases); p += 1 {
		ctx := script.condition_context(&vm.ctx, formid.PLAYER, 0, s.quest)
		if !conditions.all(&ctx, s.phases[p].start) {continue}
		run := &ws.scenes[scene]
		run.phase = p
		for &ar in run.actions {
			if action_of(s, ar.index).end < u32(p) {
				cut_line(vm, &ar)
				ar.pack = 0
			}
		}
		record_fragment(vm, scene, u16(p), esm.PHASE_ON_START)
		for a in s.actions {
			if a.start == u32(p) && scene in ws.scenes {start_action(vm, scene, s, a)}
		}
		return
	}
	ctx := script.condition_context(&vm.ctx, formid.PLAYER, 0, s.quest)
	if s.flags & gamedb.SCENE_REPEAT_WHILE_TRUE != 0 && conditions.all(&ctx, s.conditions) {
		run := &ws.scenes[scene]
		for &ar in run.actions {cut_line(vm, &ar)}
		clear(&run.actions)
		run.phase = -1 // the next tick starts it over; Begin and End run once
		return
	}
	end_scene(vm, scene)
}

// end_scene cuts the lines being said, runs the End fragment of a scene that began, and stops its
// quest when the scene says so.
@(private = "file")
end_scene :: proc(vm: ^VM, scene: script.Form_ID) {
	ws := vm.ctx.ws
	s := vm.ctx.db.scenes[scene]
	run := ws.scenes[scene]
	for &ar in run.actions {cut_line(vm, &ar)}
	delete(run.actions)
	delete_key(&ws.scenes, scene)
	if !run.begun {return}
	record_fragment(vm, scene, 1, 0) // End
	if s.flags & gamedb.SCENE_STOP_QUEST_ON_END != 0 {script.request_stop(&vm.ctx, s.quest)}
}

// start_action gives one action its first state. Actions on an empty alias or a dead or disabled
// actor are done at once (CK), as is a dialogue action with nothing to say.
@(private = "file")
start_action :: proc(vm: ^VM, scene: script.Form_ID, s: gamedb.Scene, a: gamedb.Scene_Action) {
	ws := vm.ctx.ws
	ref := worldstate.alias_ref(ws, s.quest, a.alias)
	ar := worldstate.Action_Run{index = a.index, speaker = ref}
	switch {
	case ref == 0 || worldstate.is_dead(ws, vm.ctx.db, ref) || !worldstate.ref_enabled(ws, vm.ctx.db, ref):
		ar.done = true
	case a.kind == .Timer:
		ar.left = a.seconds
	case a.kind == .Package:
		ar.pack = first_package(vm, ref, s.quest, a.packages)
		ar.done = ar.pack == 0
	case:
		ar.done = !speak(vm, &ar, a.topic)
	}
	run := &ws.scenes[scene]
	append(&run.actions, ar)
}

// first_package is the first package of an action's stack whose conditions pass; they are checked
// only when the action starts (CK Scenes Tab). The AI runs it and marks the action done.
@(private = "file")
first_package :: proc(vm: ^VM, actor, quest: script.Form_ID, stack: []script.Form_ID) -> script.Form_ID {
	for pack in stack {
		p := gamedb.package_of(vm.ctx.db, pack) or_continue
		ctx := script.condition_context(&vm.ctx, actor, 0, p.owner_quest if p.owner_quest != 0 else quest)
		if conditions.all(&ctx, p.conditions) {return pack}
	}
	return 0
}

// advance_actions moves the actions of the running phase on by `dt`: timers run down, lines go
// response by response, and a looping line waits, then speaks again.
@(private = "file")
advance_actions :: proc(vm: ^VM, scene: script.Form_ID, s: gamedb.Scene, dt: f32) {
	run := &vm.ctx.ws.scenes[scene]
	for &ar in run.actions {
		a := action_of(s, ar.index)
		if a.end < u32(run.phase) {continue}
		ar.left -= dt
		if ar.left > 0 {continue}
		switch {
		case a.kind == .Timer:
			ar.done = true
		case ar.info != 0:
			ar.response += 1
			lines := dialogue.responses(vm.ctx.db, ar.info)
			if int(ar.response) < len(lines) {
				ar.left = say_line(vm, ar.speaker, ar.info, int(ar.response))
				continue
			}
			cut_line(vm, &ar)
			ar.done = true
			if a.flags & gamedb.SCENE_ACTION_LOOPING != 0 {ar.left = rand.float32_range(a.loop_min, max(a.loop_min, a.loop_max) + 0.001)}
		case a.flags & gamedb.SCENE_ACTION_LOOPING != 0 && ar.speaker != 0 && !worldstate.is_dead(vm.ctx.ws, vm.ctx.db, ar.speaker):
			speak(vm, &ar, a.topic)
		}
	}
}

// speak starts the line the speaker says for `topic`; false when there is none.
@(private = "file")
speak :: proc(vm: ^VM, ar: ^worldstate.Action_Run, topic: script.Form_ID) -> bool {
	c := script.condition_context(&vm.ctx, 0, 0)
	info := dialogue.pick(&c, ar.speaker, topic)
	if info == 0 {return false}
	dialogue.said(&c, ar.speaker, info)
	ar.info, ar.response = info, 0
	ar.left = say_line(vm, ar.speaker, info, 0)
	return true
}

// (hole cut-line-voice :tags (dialogue audio) :sev polish) a scene line cut short (cut_line) or a bark whose speaker dies keeps its voice playing to the end: the saved run holds no audio handle.
// say_line starts one response in the speaker's voice, placed at the speaker, and is how long the
// line stays up: its voice's length, else its text's; 0 past the last response.
say_line :: proc(vm: ^VM, speaker, info: script.Form_ID, response: int) -> f32 {
	lines := dialogue.responses(vm.ctx.db, info)
	if response >= len(lines) {return 0}
	if vm.ctx.audio != nil {
		c := vm.ctx
		// (hole lip-sync-voice-map :tags (threading animation audio unclaimed) :sev gap :needs (lip-converter)) main has no speaker-to-voice map, so face curves cannot follow a playing line. Wanted: audio keeps each speaker's playing line (it has a.speaking) and reports its playback time, which the face sampler reads.
		if h, secs := audio.say(c.audio, c.vfs, c.db, c.ws, speaker, info, lines[response].number, placed = true); h != 0 {return secs}
	}
	return dialogue.line_seconds(lines[response].text)
}

// cut_line ends the line an action is saying, its end fragment included.
@(private = "file")
cut_line :: proc(vm: ^VM, ar: ^worldstate.Action_Run) {
	if ar.info == 0 {return}
	c := script.condition_context(&vm.ctx, 0, 0)
	dialogue.finished(&c, ar.speaker, ar.info)
	ar.info = 0
}

@(private = "file")
phase_complete :: proc(vm: ^VM, s: gamedb.Scene, run: worldstate.Scene_Run) -> bool {
	if run.phase < 0 || int(run.phase) >= len(s.phases) {return false}
	if done := s.phases[run.phase].completion; len(done) > 0 {
		ctx := script.condition_context(&vm.ctx, formid.PLAYER, 0, s.quest)
		return conditions.all(&ctx, done)
	}
	for ar in run.actions {
		if action_of(s, ar.index).end == u32(run.phase) && !ar.done {return false}
	}
	return true
}

@(private = "file")
action_of :: proc(s: gamedb.Scene, index: u32) -> gamedb.Scene_Action {
	for a in s.actions {
		if a.index == index {return a}
	}
	return {}
}
