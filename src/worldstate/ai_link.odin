package worldstate

// AI_Link is what scripts ask of the AI and what the AI tells them. The script thread writes the
// asks and the AI drains them at its tick; the AI publishes the rest each tick. Not saved: after a
// load packages re-select and a path order is gone (the guard's IsPathingTo reads false).
AI_Link :: struct {
	evaluate:   Form_Set, // EvaluatePackage: select again now
	to_package: Form_Set, // MoveToPackageLocation
	paths:      map[Form_ID]Path_Order, // PathTo
	packages:   map[Form_ID]Form_ID, // actor -> the package it runs (AI)
	moving:     Form_Set, // actors walking this tick (AI)
	moves:      [dynamic]Location_Move, // NPCs that changed location since the VM last looked (AI)
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
	delete(l.packages)
	delete(l.moving)
	delete(l.moves)
}
