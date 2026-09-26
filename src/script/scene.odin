package script

// Scenes: a quest's scripted run of dialogue and actor actions in phases (SCEN). Quests move
// through them: a scene's phase and end fragments set stages, and 7,426 of 15,037 DIAL topics
// are scene lines. These natives queue and read; the VM plays them (slua.tick_scenes).

import "../gamedb"
import "../worldstate"

register_scene :: proc(reg: ^Registry) {
	register(reg, "Scene", "Start", n_scene_start)
	register(reg, "Scene", "ForceStart", n_scene_force_start)
	register(reg, "Scene", "Stop", n_scene_stop)
	register(reg, "Scene", "IsPlaying", n_scene_is_playing)
	register(reg, "Scene", "IsActionComplete", n_scene_is_action_complete)
	register(reg, "Scene", "GetOwningQuest", n_scene_get_owning_quest)
	register(reg, "ObjectReference", "GetCurrentScene", n_get_current_scene)
}

// scene_start queues `scene` to play from its first phase once its actors are free (the VM runs
// it, slua.tick_scenes). False when its quest does not run; a scene already queued stays as it is.
scene_start :: proc(c: ^Call, scene: Form_ID, force := false) -> bool {
	s, ok := gamedb.scene_of(c.db, scene)
	if !ok || !worldstate.quest_running(c.ws, c.db, s.quest) {return false}
	if scene not_in c.ws.scenes {c.ws.scenes[scene] = {phase = -1, force = force}}
	return true
}

// start_quest_scenes queues the scenes of `quest` that begin when it starts.
start_quest_scenes :: proc(c: ^Call, quest: Form_ID) {
	for scene, s in c.db.scenes {
		if s.quest == quest && s.flags & gamedb.SCENE_BEGIN_ON_QUEST_START != 0 {scene_start(c, scene)}
	}
}

n_scene_start :: proc(c: ^Call, args: []Value) -> Value {
	scene_start(c, c.self)
	return nil
}

n_scene_force_start :: proc(c: ^Call, args: []Value) -> Value {
	scene_start(c, c.self, force = true)
	return nil
}

n_scene_stop :: proc(c: ^Call, args: []Value) -> Value {
	if run, ok := &c.ws.scenes[c.self]; ok {run.stopping = true}
	return nil
}

n_scene_is_playing :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.scene_playing(c.ws, c.self)
}

n_scene_is_action_complete :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.scene_action_done(c.ws, c.self, u32(arg_i32(args, 0, 0)))
}

n_scene_get_owning_quest :: proc(c: ^Call, args: []Value) -> Value {
	return c.db.scenes[c.self].quest
}

n_get_current_scene :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.scene_of_actor(c.ws, c.db, c.self)
}
