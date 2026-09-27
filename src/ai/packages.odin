package ai

// Packages (PACK). An actor runs the first package it may run now. A package is a template's
// procedure tree with the instance's inputs; the engine walks the tree as data.

import "../gamedb"
import "../worldstate"

// (hole package-select :tags ai :sev blocker) nothing picks a package: wanted the first of alias packages (quest priority), scene packages, own PKID list, then the default package list (gamedb.actor_packages), whose schedule and conditions pass. Schedules: day of week only, hours in minutes, 265 cross midnight.
// select_package is the package an actor runs now; 0 is none.
select_package :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> Form_ID {
	return 0
}

Status :: enum u8 {
	Running,
	Done,
	Failed,
}

// Proc_Context is what a procedure sees: its actor, the agent it drives and the package node it runs.
Proc_Context :: struct {
	ws:    ^worldstate.World_State,
	db:    ^gamedb.DB,
	actor: Form_ID,
	agent: ^Agent,
	feet:  [3]f32,
	node:  int,
}

// (hole package-tree :tags ai :sev blocker :needs package-select) the procedure tree is never walked; decided: the engine walks it as data. Wanted Sequence (in order, each to completion), Stacked (first child whose conditions pass), Simultaneous (all at once), Random (one), node conditions, flag overrides, and the package's begin, end and change fragments.
// run_tree runs one tick of the agent's package.
run_tree :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// run_procedure runs one tick of a procedure leaf. The name is the PNAM string, so a mod can name its own.
run_procedure :: proc(c: ^Proc_Context, name: string) -> Status {
	switch name {
	case "Travel":                        return proc_travel(c)
	case "Sandbox":                       return proc_sandbox(c)
	case "Find", "Sit", "Sleep", "Eat", "Acquire": return proc_furniture(c, name)
	case "Patrol":                        return proc_patrol(c)
	case "UseIdleMarker":                 return proc_idle_marker(c)
	case "Wait", "HoldPosition":          return proc_wait(c)
	case "Wander":                        return proc_wander(c)
	case "LockDoors", "UnlockDoors":      return proc_doors(c, name == "LockDoors")
	}
	return lua_procedure(c, name)
}

// (hole lua-procedures :tags (ai script) :sev gap :needs package-tree) a procedure the engine does not know fails; decided: a mod can define one in Lua by its PNAM name. Also the other vanilla leaves (Follow, Escort, ForceGreet, Guard, KeepAnEyeOn, UseWeapon, ...) land here until their own holes build them.
lua_procedure :: proc(c: ^Proc_Context, name: string) -> Status {
	return .Failed
}

// (hole proc-travel :tags ai :sev blocker ) Travel never moves anyone: wanted aim the mover at the package location (NearRef, NearEditorLoc, AliasRef, InCell, NearLinkedRef, NearPackageStart, NearSelf) and finish on arrival.
proc_travel :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-sandbox :tags ai :sev blocker :needs furniture-markers) Sandbox does nothing: wanted wander inside the radius, and sit, eat, sleep or use idle markers as the package flags allow.
proc_sandbox :: proc(c: ^Proc_Context) -> Status {
	return .Running
}

// (hole proc-furniture :tags ai :sev gap :needs furniture-markers) Find, Sit, Sleep, Eat and Acquire do nothing: wanted find a free bed, chair or food by object type (Chairs 550, Food 505, Beds 417), walk to its marker, face its heading and hold it.
proc_furniture :: proc(c: ^Proc_Context, name: string) -> Status {
	return .Done
}

// (hole proc-patrol :tags ai :sev gap ) Patrol does nothing: wanted walk the linked-ref chain of patrol markers, waiting at each.
proc_patrol :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-idle-marker :tags ai :sev gap ) UseIdleMarker does nothing: wanted walk to the IDLM ref and play its idle (the idle itself is animation).
proc_idle_marker :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-wait :tags ai :sev gap) Wait and HoldPosition end at once; wanted: stand until the package or its node ends.
proc_wait :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-wander :tags ai :sev polish ) Wander does nothing (5 uses, all in Sit trees).
proc_wander :: proc(c: ^Proc_Context) -> Status {
	return .Done
}

// (hole proc-doors :tags ai :sev polish) LockDoors and UnlockDoors do nothing: wanted lock or unlock the doors of the package location's cell.
proc_doors :: proc(c: ^Proc_Context, lock: bool) -> Status {
	return .Done
}
