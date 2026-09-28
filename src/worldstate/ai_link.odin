package worldstate

import "core:math"
import "../gamedb"

// AI_Link is what scripts ask of the AI and what the AI tells them. The script thread writes the
// asks and the AI drains them at its tick; the AI publishes the rest each tick. Not saved: after a
// load packages re-select and a path order is gone (the guard's IsPathingTo reads false).
AI_Link :: struct {
	evaluate:   Form_Set, // EvaluatePackage: select again now
	to_package: Form_Set, // MoveToPackageLocation
	paths:      map[Form_ID]Path_Order, // PathTo
	offsets:    map[Form_ID]Keep_Offset, // KeepOffsetFromActor
	packages:   map[Form_ID]Form_ID, // actor -> the package it runs (AI)
	loaded:     Form_Set, // actors with a capsule this tick (app)
	moving:     Form_Set, // actors walking this tick (AI)
	sitting:    Form_Set, // actors on a seat (AI)
	sleeping:   Form_Set, // actors asleep in a bed (AI)
	moves:      [dynamic]Location_Move, // NPCs that changed location since the VM last looked (AI)
	skipped:    f64, // game hours a wait or GameHour write skipped that the AI has not walked yet
}

// Location_Move is an actor going from one location to another: OnLocationChange and a CLOC story event.
Location_Move :: struct {
	actor, old, now: Form_ID,
}

// Path_Order is a PathTo: walk to `to`, at `speed` 0 (walk) .. 1 (run); the AI drops it on arrival.
Path_Order :: struct {
	to:    Form_ID,
	speed: f32,
}

// set_package_done notes that an actor finished a package, if the package runs once per day.
set_package_done :: proc(ws: ^World_State, db: ^gamedb.DB, actor, pack: Form_ID) {
	if p, ok := gamedb.package_of(db, pack); ok && p.flags & gamedb.PACK_ONCE_PER_DAY != 0 {ws.packages_done[{actor, pack}] = ws.clock.hours}
}

// package_target_ref is the ref a package's target data names for `subject`: a SpecificRef, its
// linked ref, an alias's ref (of `quest`), or itself.
package_target_ref :: proc(ws: ^World_State, db: ^gamedb.DB, t: gamedb.Package_Target, subject, quest: Form_ID) -> Form_ID {
	#partial switch t.kind {
	case .SpecificRef: return resolve(ws, t.form)
	case .LinkedRef:
		ref, _ := gamedb.linked_ref(db, subject, t.form)
		return ref
	case .RefAlias: return alias_ref(ws, quest, t.value)
	case .Self: return subject
	}
	return 0
}

// done_today is whether the actor finished this OncePerDay package on the current game day.
done_today :: proc(ws: ^World_State, actor, pack: Form_ID) -> bool {
	hour, ok := ws.packages_done[{actor, pack}]
	return ok && math.floor(hour / 24) == math.floor(ws.clock.hours / 24)
}

// (hole actor-states :tags (animation ai unclaimed) :sev blocker) no actor-state model: seated, sleeping, mounted, leaning, attacking and in-an-action live in scattered sets or nowhere. Wanted: one model that AI, scripts and conditions write and read and animation plays, not a copy of Havok behaviour graphs or Nemesis/Pandora patching.
// SEATED is the sit and sleep state "in the furniture"; getting in and out (1, 2, 4) are animation.
SEATED :: 3

// sit_state is GetSitting and GetSitState.
sit_state :: proc(ws: ^World_State, actor: Form_ID) -> i32 {
	return SEATED if actor in ws.ai.sitting else 0
}

// sleep_state is GetSleeping and GetSleepState.
sleep_state :: proc(ws: ^World_State, actor: Form_ID) -> i32 {
	return SEATED if actor in ws.ai.sleeping else 0
}

// Keep_Offset is a KeepOffsetFromActor: hold `offset` (x right, y ahead, z up) in the target's frame,
// turned `angle` from its heading; run while farther than `catch_up`, stop within `follow`.
Keep_Offset :: struct {
	target:           Form_ID,
	offset:           [3]f32,
	angle:            f32,
	catch_up, follow: f32,
}

// take removes `form` from a set and says whether it was there.
take :: proc(s: ^Form_Set, form: Form_ID) -> bool {
	if form not_in s {return false}
	delete_key(s, form)
	return true
}

// set_dont_move records SetDontMove and SetRestrained: while either holds, the actor stands.
set_dont_move :: proc(ws: ^World_State, actor: Form_ID, on: bool) {set_in_set(&ws.dont_move, actor, on)}
set_restrained :: proc(ws: ^World_State, actor: Form_ID, on: bool) {set_in_set(&ws.restrained, actor, on)}

held_still :: proc(ws: ^World_State, actor: Form_ID) -> bool {
	return actor in ws.dont_move || actor in ws.restrained
}

@(private)
destroy_ai_link :: proc(l: ^AI_Link) {
	delete(l.evaluate)
	delete(l.to_package)
	delete(l.paths)
	delete(l.offsets)
	delete(l.packages)
	delete(l.loaded)
	delete(l.moving)
	delete(l.sitting)
	delete(l.sleeping)
	delete(l.moves)
}
