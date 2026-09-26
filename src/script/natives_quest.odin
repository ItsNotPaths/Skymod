package script

// Quest.* — the quest-state store natives (docs/scripting-natives.md §B, the highest-leverage new
// store: ~25k call sites reach these through the transpiled Quest.pex wrappers SetStage/GetStage/…).
// `self` is the quest FormID. All state lives in the worldstate quest store (overlay only — the ESM
// baseline quest state isn't indexed yet, so an untouched quest reads as stage 0 / stopped).
//
// Quest state is world-fact, not scene geometry, so these do NOT mark_scene_dirty (nothing in the
// resident 3D scene changes when a stage advances; quest-driven ref enable/disable rides its own verb).

import "core:slice"
import "../formid"
import "../gamedb"
import "../worldstate"

register_quest :: proc(reg: ^Registry) {
	register(reg, "Quest", "SetCurrentStageID", n_quest_set_stage)
	register(reg, "Quest", "GetCurrentStageID", n_quest_get_stage)
	register(reg, "Quest", "GetRecentStageID", n_quest_get_recent_stage) // skymod extension (below)
	register(reg, "Quest", "IsStageDone", n_quest_is_stage_done)

	register(reg, "Quest", "SetObjectiveCompleted", n_quest_set_obj_completed)
	register(reg, "Quest", "SetObjectiveDisplayed", n_quest_set_obj_displayed)
	register(reg, "Quest", "SetObjectiveFailed", n_quest_set_obj_failed)
	register(reg, "Quest", "IsObjectiveCompleted", n_quest_is_obj_completed)
	register(reg, "Quest", "IsObjectiveDisplayed", n_quest_is_obj_displayed)
	register(reg, "Quest", "IsObjectiveFailed", n_quest_is_obj_failed)

	register(reg, "Quest", "Start", n_quest_start)
	register(reg, "Quest", "Stop", n_quest_stop)
	register(reg, "Quest", "Reset", n_quest_reset)
	register(reg, "Quest", "SetActive", n_quest_set_active)

	register(reg, "Quest", "IsRunning", n_quest_is_running)
	register(reg, "Quest", "IsActive", n_quest_is_active)
	register(reg, "Quest", "IsStopped", n_quest_is_stopped)
	register(reg, "Quest", "IsStarting", n_quest_is_starting)
	register(reg, "Quest", "IsStopping", n_quest_is_stopping)
	register(reg, "Quest", "IsCompleted", n_quest_is_completed)

	register(reg, "Quest", "CompleteQuest", n_quest_complete)
	register(reg, "Quest", "CompleteAllObjectives", n_quest_complete_all_obj)
	register(reg, "Quest", "FailAllObjectives", n_quest_fail_all_obj)
}

// ── stages ───────────────────────────────────────────────────────────────────

// SetCurrentStageID(aiStageID) -> bool: set a stage, starting the quest first if it is not running.
// Its fragments run inside the call (CK: the function "will also wait for those fragments to finish
// running before returning"). False, and nothing runs, for a stage that is not defined or is done
// already. Stage validation is skipped when the quest's baseline is unknown (synthetic DB).
n_quest_set_stage :: proc(c: ^Call, args: []Value) -> Value {
	stage := u16(arg_i32(args, 0, 0))
	if exists, known := gamedb.quest_stage_exists(c.db, c.self, stage); known && !exists {
		return false
	}
	if worldstate.quest_is_stage_done(c.ws, c.self, stage) {return false}
	if !worldstate.quest_running(c.ws, c.db, c.self) && !n_quest_start(c, nil).(bool) {return false}
	worldstate.quest_set_stage(c.ws, c.self, stage)
	append(&c.ws.quest_steps, worldstate.Quest_Step{quest = c.self, stage = stage})
	return true
}

n_quest_get_stage :: proc(c: ^Call, args: []Value) -> Value {
	return i32(worldstate.quest_stage(c.ws, c.self))
}

// GetRecentStageID -> int: SKYMOD EXTENSION (not in vanilla Papyrus). The stage most recently SET,
// vs GetCurrentStageID which returns the HIGHEST completed. Lets a script read the raw last-set stage
// when a later call set a lower one (e.g. a branch that steps a quest backward). Implemented-but-not-
// declared in the manifest — that's expected for skymod-native procs; it dispatches through call()
// like any other and auto-surfaces to the REPL once Quest is method-dispatchable (see note below).
n_quest_get_recent_stage :: proc(c: ^Call, args: []Value) -> Value {
	return i32(worldstate.quest_last_stage(c.ws, c.self))
}

n_quest_is_stage_done :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.quest_is_stage_done(c.ws, c.self, u16(arg_i32(args, 0, 0)))
}

// ── objectives ─────────────────────────────────────────────────────────────────

n_quest_set_obj_completed :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_objective(c.ws, c.self, u16(arg_i32(args, 0, 0)), .Completed, arg_bool(args, 1, true))
	return nil
}

// SetObjectiveDisplayed(aiObjective, abDisplayed=true, abForce=false). abForce only affects
// redundant re-display (a UI nicety) — no store effect here, so param 2 is ignored.
n_quest_set_obj_displayed :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_objective(c.ws, c.self, u16(arg_i32(args, 0, 0)), .Displayed, arg_bool(args, 1, true))
	return nil
}

n_quest_set_obj_failed :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_objective(c.ws, c.self, u16(arg_i32(args, 0, 0)), .Failed, arg_bool(args, 1, true))
	return nil
}

n_quest_is_obj_completed :: proc(c: ^Call, args: []Value) -> Value {
	return .Completed in worldstate.quest_objective(c.ws, c.self, u16(arg_i32(args, 0, 0)))
}

n_quest_is_obj_displayed :: proc(c: ^Call, args: []Value) -> Value {
	return .Displayed in worldstate.quest_objective(c.ws, c.self, u16(arg_i32(args, 0, 0)))
}

n_quest_is_obj_failed :: proc(c: ^Call, args: []Value) -> Value {
	return .Failed in worldstate.quest_objective(c.ws, c.self, u16(arg_i32(args, 0, 0)))
}

// ── run-state ────────────────────────────────────────────────────────────────

// Start() -> bool: whether the quest started. A quest with a story manager event starts only
// through the story manager (CK wiki, Quest Data Tab).
n_quest_start :: proc(c: ^Call, args: []Value) -> Value {
	return !story_only(c, c.self) && start_quest(c, c.self)
}

@(private = "file")
story_only :: proc(c: ^Call, quest: Form_ID) -> bool {
	qb, _ := gamedb.quest_baseline_of(c.db, quest)
	return qb.event != {}
}

n_quest_stop :: proc(c: ^Call, args: []Value) -> Value {
	request_stop(c, c.self)
	return nil
}

// request_stop runs the shut-down stages first, while the aliases are still filled; stop_quest
// follows them (the VM runs both once the native returns). A quest that is stopped, or stopping
// already, ignores it: shut-down stages often call Stop themselves.
request_stop :: proc(c: ^Call, quest: Form_ID) {
	if !worldstate.quest_running(c.ws, c.db, quest) {return}
	for step in c.ws.quest_steps {
		if step.quest == quest && step.stop {return}
	}
	queue_stages(c, quest, gamedb.STAGE_SHUT_DOWN)
	append(&c.ws.quest_steps, worldstate.Quest_Step{quest = quest, stop = true})
}

// stop_quest empties a quest's aliases and ends its registrations.
stop_quest :: proc(c: ^Call, quest: Form_ID) {
	worldstate.quest_set_running(c.ws, quest, false)
	worldstate.unregister_all(c.ws, quest)
	clear_aliases(c.ws, c.db, quest)
}

// queue_stages queues the fragments of every stage of `quest` that has `flag`, in stage order.
queue_stages :: proc(c: ^Call, quest: Form_ID, flag: u8) {
	qb, _ := gamedb.quest_baseline_of(c.db, quest)
	stages := make([dynamic]u16, 0, 2, context.temp_allocator)
	for index, st in qb.stages {
		if st.flags & flag != 0 {append(&stages, index)}
	}
	slice.sort(stages[:])
	for index in stages {append(&c.ws.quest_steps, worldstate.Quest_Step{quest = quest, stage = index})}
}

n_quest_reset :: proc(c: ^Call, args: []Value) -> Value {
	if reset_quest(c, c.self) {clear_aliases(c.ws, c.db, c.self)}
	return nil
}

// reset_quest puts a quest back to its start: stopped, no stages done, and its and its aliases'
// scripts at their start values, to run OnInit again. A Run Once quest never resets (CK wiki,
// Quest Data Tab). Reports whether it reset.
reset_quest :: proc(c: ^Call, quest: Form_ID) -> bool {
	qb, _ := gamedb.quest_baseline_of(c.db, quest)
	if qb.run_once {return false}
	worldstate.quest_reset(c.ws, quest)
	worldstate.forget_scripts(c.ws, quest)
	for a in c.db.form_scripts[quest].aliases {
		if h, ok := formid.alias_handle(quest, u32(a.owner.alias)); ok {worldstate.forget_scripts(c.ws, h)}
	}
	append(&c.ws.reset_quests, quest)
	return true
}

n_quest_set_active :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_active(c.ws, c.self, arg_bool(args, 0, true))
	return nil
}

n_quest_is_running :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.quest_running(c.ws, c.db, c.self)
}

n_quest_is_active :: proc(c: ^Call, args: []Value) -> Value {
	if q, ok := worldstate.quest_get(c.ws, c.self); ok {return q.active}
	return false
}

// IsStopped() -> bool: a quest is stopped when it isn't running (baseline ⊕ overlay).
n_quest_is_stopped :: proc(c: ^Call, args: []Value) -> Value {
	return !worldstate.quest_running(c.ws, c.db, c.self)
}

// IsStarting/IsStopping are the momentary latent-transition states; we start/stop instantly, so
// neither is ever observably true — return false rather than the auto-stub's None (a bool query).
n_quest_is_starting :: proc(c: ^Call, args: []Value) -> Value {
	return false
}

n_quest_is_stopping :: proc(c: ^Call, args: []Value) -> Value {
	return false
}

// IsCompleted() -> bool: explicitly CompleteQuest'd, OR a reached (done) stage is flagged "Complete
// Quest" in the baseline (Papyrus derives completion from stage flags, not only the explicit call).
n_quest_is_completed :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.quest_completed(c.ws, c.db, c.self)
}

// ── bulk ───────────────────────────────────────────────────────────────────

n_quest_complete :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_completed(c.ws, c.self, true)
	return nil
}

// Complete/FailAllObjectives flag EVERY objective. `flag_all_objectives` reaches the full baseline
// (QOBJ) set when known, unioned with any the overlay already touched (so custom/synthetic objectives
// without a baseline entry still get flagged, and no-baseline quests degrade to touched-only).
n_quest_complete_all_obj :: proc(c: ^Call, args: []Value) -> Value {
	flag_all_objectives(c, .Completed)
	return nil
}

n_quest_fail_all_obj :: proc(c: ^Call, args: []Value) -> Value {
	flag_all_objectives(c, .Failed)
	return nil
}

@(private)
flag_all_objectives :: proc(c: ^Call, flag: worldstate.Objective_Flag) {
	if qb, ok := gamedb.quest_baseline_of(c.db, c.self); ok {
		for obj in qb.objectives {
			worldstate.quest_set_objective(c.ws, c.self, obj, flag, true)
		}
	}
	worldstate.quest_set_all_objectives(c.ws, c.self, flag) // + objectives the overlay already touched
}
