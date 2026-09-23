package script

// Quest.* — the quest-state store natives (docs/scripting-natives.md §B, the highest-leverage new
// store: ~25k call sites reach these through the transpiled Quest.pex wrappers SetStage/GetStage/…).
// `self` is the quest FormID. All state lives in the worldstate quest store (overlay only — the ESM
// baseline quest state isn't indexed yet, so an untouched quest reads as stage 0 / stopped).
//
// Quest state is world-fact, not scene geometry, so these do NOT mark_scene_dirty (nothing in the
// resident 3D scene changes when a stage advances; quest-driven ref enable/disable rides its own verb).

import "../gamedb"
import "../worldstate"

// quest_running merges baseline ⊕ overlay for run-state: an explicit Start/Stop (running_set) wins;
// otherwise an untouched quest defers to its baseline "Start Game Enabled" flag (so the invisible
// controller quests that run from a new game read IsRunning=true without a script touching them).
@(private)
quest_running :: proc(c: ^Call) -> bool {
	if q, ok := worldstate.quest_get(c.ws, c.self); ok && q.running_set {
		return q.running
	}
	return gamedb.quest_start_game_enabled(c.db, c.self)
}

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

// SetCurrentStageID(aiStageID) -> bool: advance a RUNNING quest to a stage. Returns false (no-op) if
// the stage isn't a defined stage of the quest, or if the quest isn't running — matching Papyrus
// ("returns true if stage exists and was set"; a stopped quest ignores it). Stage validation is
// skipped when the quest's baseline is unknown (unparsed / synthetic DB) so it still works there.
n_quest_set_stage :: proc(c: ^Call, args: []Value) -> Value {
	stage := u16(arg_i32(args, 0, 0))
	if exists, known := gamedb.quest_stage_exists(c.db, c.self, stage); known && !exists {
		return false
	}
	if !quest_running(c) {
		return false
	}
	worldstate.quest_set_stage(c.ws, c.self, stage)
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

// Start() -> bool: true if it wasn't already running (Papyrus returns whether the start took effect).
n_quest_start :: proc(c: ^Call, args: []Value) -> Value {
	was_running := false
	if q, ok := worldstate.quest_get(c.ws, c.self); ok {was_running = q.running}
	worldstate.quest_set_running(c.ws, c.self, true)
	return !was_running
}

n_quest_stop :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_running(c.ws, c.self, false)
	worldstate.unregister_updates(c.ws, c.self) // a stopped quest's updates stop too
	return nil
}

n_quest_reset :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_reset(c.ws, c.self)
	return nil
}

n_quest_set_active :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.quest_set_active(c.ws, c.self, arg_bool(args, 0, true))
	return nil
}

n_quest_is_running :: proc(c: ^Call, args: []Value) -> Value {
	return quest_running(c)
}

n_quest_is_active :: proc(c: ^Call, args: []Value) -> Value {
	if q, ok := worldstate.quest_get(c.ws, c.self); ok {return q.active}
	return false
}

// IsStopped() -> bool: a quest is stopped when it isn't running (baseline ⊕ overlay).
n_quest_is_stopped :: proc(c: ^Call, args: []Value) -> Value {
	return !quest_running(c)
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
	if q, ok := worldstate.quest_get(c.ws, c.self); ok {
		if q.completed {
			return true
		}
		for stage in q.done {
			if gamedb.quest_stage_completes(c.db, c.self, stage) {
				return true
			}
		}
	}
	return false
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
