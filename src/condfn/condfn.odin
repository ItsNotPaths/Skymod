package condfn

// Condition functions from plugins: a plugin answers a CTDA function index, replacing the engine's
// function or adding one it does not have. This is a seam (ws.md Workstream H): the conditions
// evaluator asks Table.eval first and falls back to the engine's functions when it does not answer.
// A plugin keeps the Table it was given and calls it for the functions it does not answer, so
// several plugins chain in mod order.

import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_conditions"
VERSION :: u32(1)

// Call is one condition function call, its run-on object resolved.
Call :: struct {
	function:               u16,
	on:                     Form_ID, // the object the function runs on
	subject, target, quest: Form_ID,
	param1, param2:         u64, // a Form_ID when the parameter is a form, otherwise the raw number
	param3:                 i32, // the alias or event member; -1 = none
	text:                   plugin.Span(u8), // a String parameter
}

Answer :: struct {
	value:    f32,
	answered: bool, // false = not this plugin's function
}

// Host is what the engine answers; each proc gets `data` back.
Host :: struct {
	data:         rawptr,
	actor_value:  proc "c" (data: rawptr, actor: Form_ID, name: cstring) -> f32, // current value
	has_keyword:  proc "c" (data: rawptr, form, keyword: Form_ID) -> bool, // the form, its base or an alias holding it
	faction_rank: proc "c" (data: rawptr, actor, faction: Form_ID) -> i32, // -1 = not a member
	quest_stage:  proc "c" (data: rawptr, quest: Form_ID) -> i32,
	global:       proc "c" (data: rawptr, global: Form_ID) -> f32,
	base:         proc "c" (data: rawptr, ref: Form_ID) -> Form_ID,
}

Table :: struct {
	eval: proc "c" (h: ^Host, c: Call) -> Answer,
}

// BUILTIN answers nothing: every function is the engine's.
BUILTIN :: Table{none}

@(private = "file")
none :: proc "c" (h: ^Host, c: Call) -> Answer {
	return {}
}
