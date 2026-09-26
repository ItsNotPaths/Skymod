package worldstate

import "../gamedb"

// Objective_Flag / Objective_State mirror a quest objective's three independent runtime bits
// (an objective can be displayed AND completed, or displayed-then-failed). bit_set onto a byte so
// the save lowers it as a u8.
Objective_Flag :: enum u8 {
	Displayed,
	Completed,
	Failed,
}

Objective_State :: distinct bit_set[Objective_Flag;u8]

// Quest_State is a quest's runtime divergence from its ESM baseline (docs/scripting-natives.md §B):
// the current stage (INDX u16 — see the string-label design note), the set of stages that have run
// (IsStageDone), per-objective flags, and run-state. A fresh game has no entry for any quest (its
// baseline start-game-enabled state drives it); the store only records what a script has touched.
// `done`/`objectives` are owned maps — quest_free releases them on destroy/clear/load.
Quest_State :: struct {
	stage:       u16, // current stage id (raw last-set; GetRecentStageID)
	running:     bool, // Start/Stop — the quest instance is live (authoritative only if running_set)
	running_set: bool, // has Start/Stop been called? if not, IsRunning defers to the baseline SGE flag
	started:     bool, // has ever been Start()ed (distinguishes "never run" from "stopped")
	active:      bool, // SetActive — shown as the tracked quest in the log
	completed:   bool, // CompleteQuest — reached a completion stage
	done:        map[u16]bool, // stages that have executed
	objectives:  map[u16]Objective_State, // objective id -> its flags
}

// Quest_Step is a stage whose fragments must run, or a stop that waits for its shut-down stages.
Quest_Step :: struct {
	quest: Form_ID,
	stage: u16,
	stop:  bool,
}

// quest_free releases a Quest_State's owned nested maps (called on destroy/clear/load-replace).
@(private)
quest_free :: proc(q: ^Quest_State) {
	delete(q.done)
	delete(q.objectives)
}

// quest_upsert returns a mutable Quest_State for `quest`, creating + initialising its nested maps on
// first sight. The pointer is valid until the next quests insert — writers use it immediately.
@(private)
quest_upsert :: proc(ws: ^World_State, quest: Form_ID) -> ^Quest_State {
	if _, existed := ws.quests[quest]; !existed {
		ws.quests[quest] = Quest_State {
			done       = make(map[u16]bool),
			objectives = make(map[u16]Objective_State),
		}
	}
	return &ws.quests[quest]
}

// quest_get returns a (read) pointer to a quest's state without creating one (ok=false if untouched).
quest_get :: proc(ws: ^World_State, quest: Form_ID) -> (^Quest_State, bool) {
	q, ok := &ws.quests[quest]
	return q, ok
}

// quest_set_stage records the current stage + marks it done. It does NOT change run-state — Papyrus
// SetCurrentStageID advances a RUNNING quest but doesn't start one (the native gates on running).
quest_set_stage :: proc(ws: ^World_State, quest: Form_ID, stage: u16) {
	q := quest_upsert(ws, quest)
	q.stage = stage
	q.done[stage] = true
}

// quest_set_running is the explicit Start/Stop — it sets running AND running_set, so IsRunning now
// reads this value instead of deferring to the baseline Start-Game-Enabled flag.
quest_set_running :: proc(ws: ^World_State, quest: Form_ID, running: bool) {
	q := quest_upsert(ws, quest)
	q.running = running
	q.running_set = true
	if running {q.started = true} else {delete_key(&ws.quest_events, quest)}
}

quest_set_active :: proc(ws: ^World_State, quest: Form_ID, active: bool) {
	quest_upsert(ws, quest).active = active
}

quest_set_completed :: proc(ws: ^World_State, quest: Form_ID, completed: bool) {
	quest_upsert(ws, quest).completed = completed
}

// quest_set_objective flips one flag of one objective on/off (leaving the objective's other flags).
quest_set_objective :: proc(ws: ^World_State, quest: Form_ID, obj: u16, flag: Objective_Flag, on: bool) {
	q := quest_upsert(ws, quest)
	s := q.objectives[obj]
	if on {s += {flag}} else {s -= {flag}}
	q.objectives[obj] = s
}

// quest_set_all_objectives applies `flag` to EVERY objective the quest has touched (Complete/Fail-all).
// It can only reach objectives already in the map — objectives a script never referenced are unknown
// to the overlay (the ESM objective list isn't indexed yet).
quest_set_all_objectives :: proc(ws: ^World_State, quest: Form_ID, flag: Objective_Flag) {
	q, ok := quest_get(ws, quest)
	if !ok {return}
	for obj, s in q.objectives {
		q.objectives[obj] = s + {flag}
	}
}

// quest_reset clears a quest's runtime state back to baseline (stage 0, no done stages/objectives,
// stopped) — Papyrus Reset re-initialises the quest. Keeps the entry (empty) so nested maps persist.
quest_reset :: proc(ws: ^World_State, quest: Form_ID) {
	q := quest_upsert(ws, quest)
	clear(&q.done)
	clear(&q.objectives)
	q.stage = 0
	q.running = false
	q.running_set = true // Reset explicitly stops the quest — an override of the baseline, not a defer
	q.started = false
	q.active = false
	q.completed = false
}

// quest_stage / quest_is_stage_done / quest_objective are the read helpers (overlay only — baseline
// quest state isn't indexed yet, so an untouched quest reads as stage 0 / not-done / no flags).
// Papyrus GetCurrentStageID is the HIGHEST completed stage, not the last one set — so we return the
// max over the done-set (a quest set to 40 then 20 reports 40). `q.stage` keeps the raw last-set value.
quest_stage :: proc(ws: ^World_State, quest: Form_ID) -> u16 {
	q, ok := quest_get(ws, quest)
	if !ok {return 0}
	highest: u16
	for stage in q.done {
		if stage > highest {highest = stage}
	}
	return highest
}

// quest_last_stage returns the RAW last-set stage — the argument of the most recent SetCurrentStageID,
// even if a later call set a LOWER one — as opposed to quest_stage's highest-completed. 0 if untouched.
// A skymod extension: vanilla Papyrus only exposes the highest (GetCurrentStageID).
quest_last_stage :: proc(ws: ^World_State, quest: Form_ID) -> u16 {
	if q, ok := quest_get(ws, quest); ok {return q.stage}
	return 0
}

quest_is_stage_done :: proc(ws: ^World_State, quest: Form_ID, stage: u16) -> bool {
	if q, ok := quest_get(ws, quest); ok {return q.done[stage]}
	return false
}

quest_objective :: proc(ws: ^World_State, quest: Form_ID, obj: u16) -> Objective_State {
	if q, ok := quest_get(ws, quest); ok {return q.objectives[obj]}
	return {}
}

// ── inventory store (owner FormID -> item FormID -> count) ─────────────────────────────────────
// Overlay-only: the ESM baseline container/NPC contents aren't indexed, so counts are DELTAS from the
// baseline (a fresh game reads 0 for everything). A baseline-inventory index later makes these absolute.

// quest_running merges baseline and overlay: an explicit Start/Stop wins; otherwise an untouched
// quest defers to its "Start Game Enabled" flag, so the controller quests that run from a new game
// read as running without a script touching them.
quest_running :: proc(ws: ^World_State, db: ^gamedb.DB, quest: Form_ID) -> bool {
	if q, ok := quest_get(ws, quest); ok && q.running_set {return q.running}
	return gamedb.quest_start_game_enabled(db, quest)
}

// quest_completed: CompleteQuest was called, or a reached stage is flagged "Complete Quest".
quest_completed :: proc(ws: ^World_State, db: ^gamedb.DB, quest: Form_ID) -> bool {
	q, ok := quest_get(ws, quest)
	if !ok {return false}
	if q.completed {return true}
	for stage in q.done {
		if gamedb.quest_stage_completes(db, quest, stage) {return true}
	}
	return false
}
