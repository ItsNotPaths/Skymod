package script

// Scenes: a quest's scripted run of dialogue and actor actions in phases (SCEN). Quests move
// through them: a scene's phase and end fragments set stages, and 7,426 of 15,037 DIAL topics
// are scene lines. The first cut plays lines as subtitles through the dialogue placeholder.

// (hole scene-system :tags (quest dialogue) :sev blocker :needs (scene-records dialogue-system condition-functions)) Scene.Start does nothing: no phases, no actions, no scene lines, and no phase or end fragment runs, so a quest that advances in a scene stalls there. 1,706 SCEN in Skyrim.esm.

register_scene :: proc(reg: ^Registry) {
	register(reg, "Scene", "Start", n_scene_start)
	register(reg, "Scene", "ForceStart", n_scene_start)
}

// scene_start starts `scene` at its first phase; false when it cannot start.
scene_start :: proc(c: ^Call, scene: Form_ID) -> bool {
	return false
}

n_scene_start :: proc(c: ^Call, args: []Value) -> Value {
	scene_start(c, c.self)
	return nil
}
