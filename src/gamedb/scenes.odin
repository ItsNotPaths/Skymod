package gamedb

// Scenes (SCEN, xEdit): a quest's phases, the aliases that act in them, and the actions each alias
// runs from a start phase to an end phase (CK Scenes Tab).

import "../formats/esm"

// Scene flags (FNAM).
SCENE_BEGIN_ON_QUEST_START :: 0x01
SCENE_STOP_QUEST_ON_END :: 0x02
SCENE_REPEAT_WHILE_TRUE :: 0x08
SCENE_INTERRUPTIBLE :: 0x10

Scene :: struct {
	quest:      Form_ID, // PNAM
	flags:      u32,
	phases:     []Scene_Phase, // owned
	actors:     []Scene_Actor, // owned
	actions:    []Scene_Action, // owned
	conditions: []Condition, // the repeat conditions (owned)
}

Scene_Phase :: struct {
	start, completion: []Condition, // owned; no completion conditions = end when its actions are done
}

// Scene actor flags (LNAM) and behaviour flags (DNAM).
SCENE_ACTOR_NO_PLAYER_ACTIVATION :: 0x1
SCENE_ACTOR_OPTIONAL :: 0x2
SCENE_DEATH_END :: 0x02
SCENE_DIALOGUE_PAUSE :: 0x10
SCENE_DIALOGUE_END :: 0x20

Scene_Actor :: struct {
	alias:    i32, // ALID: the quest alias that plays it
	flags:    u32,
	behavior: u32,
}

Scene_Action_Kind :: enum u16 {
	Dialogue,
	Package,
	Timer,
}

// Scene action flags (FNAM).
SCENE_ACTION_LOOPING :: 0x10000

Scene_Action :: struct {
	kind:               Scene_Action_Kind,
	alias:              i32,
	index:              u32, // INAM: IsActionComplete and IsSceneActionComplete name it
	flags:              u32,
	start, end:         u32, // phases, from 0
	topic:              Form_ID, // Dialogue: its info stack
	loop_min, loop_max: f32, // Dialogue: seconds between looping lines
	packages:           []Form_ID, // Package (owned)
	seconds:            f32, // Timer
}

@(private)
index_scene :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	s: Scene
	phases := make([dynamic]Scene_Phase, db.allocator)
	actors := make([dynamic]Scene_Actor, db.allocator)
	actions := make([dynamic]Scene_Action, db.allocator)
	packages := make([dynamic]Form_ID, context.temp_allocator)
	in_phase, in_action := false, false
	phase_next := 0 // NEXT markers seen in the current phase: 0 start conditions, 1 completion
	have_start := false // the current action read its start phase SNAM
	for f, i in fl {
		u, _ := esm.field_u32(f)
		switch f.type {
		case "FNAM":
			if in_action {actions[len(actions) - 1].flags = u} else {s.flags = u}
		case "HNAM":
			in_phase = !in_phase
			if in_phase {
				append(&phases, Scene_Phase{})
				phase_next = 0
			}
		case "NEXT":
			if in_phase {phase_next += 1}
		case "CTDA":
			if i > 0 && len(esm.condition_run(fl, i - 1)) > 0 {continue} // inside a run already read
			conds := index_conditions(db, esm.condition_run(fl, i), fm)
			switch {
			case in_phase && phase_next == 0:
				phases[len(phases) - 1].start = conds
			case in_phase:
				phases[len(phases) - 1].completion = conds
			case:
				s.conditions = conds
			}
		case "ALID":
			if in_action {
				actions[len(actions) - 1].alias = i32(u)
			} else {
				append(&actors, Scene_Actor{alias = i32(u)})
			}
		case "LNAM":
			if !in_action && len(actors) > 0 {actors[len(actors) - 1].flags = u}
		case "DNAM":
			if !in_action && len(actors) > 0 {actors[len(actors) - 1].behavior = u}
		case "ANAM":
			if in_action {
				a := &actions[len(actions) - 1]
				a.packages = make([]Form_ID, len(packages), db.allocator)
				copy(a.packages, packages[:])
				clear(&packages)
			} else {
				kind := u16(f.data[0]) | u16(f.data[1]) << 8 if len(f.data) >= 2 else 0 // a u16
				append(&actions, Scene_Action{kind = Scene_Action_Kind(kind)})
				have_start = false
			}
			in_action = !in_action
		case "INAM":
			if in_action {actions[len(actions) - 1].index = u}
		case "SNAM":
			if !in_action {break}
			a := &actions[len(actions) - 1]
			if !have_start {
				a.start, have_start = u, true
			} else {
				a.seconds, _ = esm.field_f32(f)
			}
		case "ENAM":
			if in_action {actions[len(actions) - 1].end = u}
		case "DATA":
			if in_action {actions[len(actions) - 1].topic = esm.remap_form(fm, u)}
		case "DMAX":
			if in_action {actions[len(actions) - 1].loop_max, _ = esm.field_f32(f)}
		case "DMIN":
			if in_action {actions[len(actions) - 1].loop_min, _ = esm.field_f32(f)}
		case "PNAM":
			if in_action {append(&packages, esm.remap_form(fm, u))} else {s.quest = esm.remap_form(fm, u)}
		}
	}
	s.phases, s.actors, s.actions = phases[:], actors[:], actions[:]
	if old, existed := db.scenes[rec.form_id]; existed {free_scene(db, old)}
	db.scenes[rec.form_id] = s
}

scene_of :: proc(db: ^DB, scene: Form_ID) -> (Scene, bool) {
	return db.scenes[scene]
}

@(private)
free_scene :: proc(db: ^DB, s: Scene) {
	for p in s.phases {
		free_conditions(db, p.start)
		free_conditions(db, p.completion)
	}
	delete(s.phases, db.allocator)
	delete(s.actors, db.allocator)
	for a in s.actions {delete(a.packages, db.allocator)}
	delete(s.actions, db.allocator)
	free_conditions(db, s.conditions)
}

@(private)
free_scenes :: proc(db: ^DB) {
	for _, s in db.scenes {free_scene(db, s)}
	delete(db.scenes)
}
