package conditions

// CTDA evaluation — answering the questions the records ask.
//
// This is the one layer that needs both halves of the game state, so it sits above gamedb
// (baseline records) and worldstate (the live overlay) and is imported by whoever asks: a menu
// deciding whether to offer a crafting row, the stats menu deciding whether a perk can be taken.
//
// The design mirrors src/script/registry.odin, which solves the same problem for Papyrus natives: a
// large declared surface, a small implemented hot set, and a hard requirement never to brick on the
// unknown. See docs/conditions.md for the census and the plan.
//
// AN UNKNOWN FUNCTION EVALUATES TRUE. Returning false would hide content the player should see,
// and true is what the engine already does today, since nothing evaluated conditions at all before
// this. Every consumer therefore moves strictly forward as functions are added, never backward.

import "core:log"
import "../formats/esm"
import "../gamedb"
import "../worldstate"

Form_ID :: gamedb.Form_ID

// Context is what a condition is asked ABOUT. run_on picks which of the form fields a function
// receives; 92% of the base game's conditions run on the subject, so the rest are usually 0.
Context :: struct {
	db:         ^gamedb.DB,
	ws:         ^worldstate.World_State,
	subject:    Form_ID, // the actor or object the question is about — usually the player
	target:     Form_ID,
	quest:      Form_ID, // the quest that owns the conditions: run-on Quest Alias and alias parameters read it
	pack:       Form_ID, // the package that owns the conditions: package data parameters read it
	event:      ^worldstate.Story_Event, // the story event being run: run-on Event Data reads it
	quest_vars: Quest_Vars,
	// warned guards the log-once for unimplemented functions, exactly as the native registry does.
	// Optional: nil simply means do not log. The caller owns it.
	warned:     ^map[u16]bool,
}

// Quest_Vars reads a quest script's member for GetVMQuestVariable; `read` is nil where no script
// VM runs.
Quest_Vars :: struct {
	data: rawptr,
	read: proc(data: rawptr, quest: Form_ID, name: string) -> (f32, bool),
}

// (hole condition-groups :tags (mods quest) :sev wish) a mod can only write a condition list the CK way (OR runs bind tighter than AND, no parentheses), so (A AND B) OR (C AND D) must be expanded into AND-ed OR blocks; a mod-authored expression with real grouping could compile to this evaluator.
// all evaluates a condition list the way the format defines it: an AND, with runs of OR.
//
// A condition whose Or flag is set is joined to the FOLLOWING one as an OR, so consecutive
// flagged conditions form a group that passes if ANY member passes, and the groups are ANDed. An
// empty list passes. 11,460 of the base game's conditions set the flag, so a reader that treats the
// list as a flat AND silently inverts those. A list whose last condition sets the flag ends its
// group there (the CK sets it on every member of a trailing OR run).
all :: proc(ctx: ^Context, conds: []gamedb.Condition) -> bool {
	group := false
	for c, i in conds {
		group ||= test(ctx, c)
		if .Or not_in c.flags || i == len(conds) - 1 { // the group closes here, and must have passed
			if !group {
				return false
			}
			group = false
		}
	}
	return true
}

// test evaluates ONE condition: resolve which object it runs on, ask the function, compare.
test :: proc(ctx: ^Context, c: gamedb.Condition) -> bool {
	if ctx.ws == nil || ctx.db == nil {
		warn_once(ctx, c.function)
		return true // never hide content over a question we cannot answer
	}
	ctx.subject, ctx.target = worldstate.resolve(ctx.ws, ctx.subject), worldstate.resolve(ctx.ws, ctx.target)
	on, known_on := run_on_form(ctx, c)
	on = worldstate.resolve(ctx.ws, on)
	if !known_on {
		return true
	}
	got, answered := ask(ctx, c, on)
	if !answered {
		warn_once(ctx, c.function)
		return true
	}
	value := c.value
	if .Use_Global in c.flags {
		value = worldstate.global_value(ctx.ws, ctx.db, c.global)
	}
	return esm.condition_holds(esm.Condition{op = c.op, value = value}, got)
}

// run_on_form resolves which object the condition asks about; ok=false when the context cannot say
// (no owning quest, no event), and the condition passes. An empty alias is a real answer: 0.
@(private)
run_on_form :: proc(ctx: ^Context, c: gamedb.Condition) -> (Form_ID, bool) {
	subject, target := ctx.subject, ctx.target
	if .Swap in c.flags {
		subject, target = target, subject
	}
	switch c.run_on {
	case .Subject:
		return subject, true
	case .Target, .CombatTarget:
		return target, true
	case .Reference:
		return c.reference, true
	case .QuestAlias:
		return alias_ref(ctx, c.param3)
	case .EventData:
		return event_form(ctx.event, c.param3)
	case .LinkedRef:
		if ctx.db == nil {return 0, false}
		ref, _ := gamedb.linked_ref(ctx.db, subject)
		return ref, true
	case .PackageData:
	}
	return 0, false
}

// param_ref reads a Ref parameter (0 or 1): a reference, with Use_Aliases an alias of the quest,
// with Use_Pack_Data the target in that package data slot.
@(private)
param_ref :: proc(ctx: ^Context, c: gamedb.Condition, i: int) -> (Form_ID, bool) {
	raw := c.param1 if i == 0 else c.param2
	if .Use_Pack_Data in c.flags {
		in_, _ := gamedb.package_input(ctx.db, ctx.pack, u8(raw))
		t, ok := in_.value.(gamedb.Package_Target)
		if !ok {return 0, false}
		return worldstate.package_target_ref(ctx.ws, ctx.db, t, ctx.subject, ctx.quest), true
	}
	if .Use_Aliases in c.flags {return alias_ref(ctx, i32(raw))}
	return worldstate.resolve(ctx.ws, Form_ID(raw)), true
}

@(private)
alias_ref :: proc(ctx: ^Context, id: i32) -> (Form_ID, bool) {
	if ctx.quest == 0 || ctx.ws == nil {return 0, false}
	return worldstate.alias_ref(ctx.ws, ctx.quest, id), true
}

// EVENT_* are the story event members, two characters read as an i32 (xEdit).
EVENT_ACTOR_1 :: 0x3152 // R1
EVENT_ACTOR_2 :: 0x3252 // R2
EVENT_OBJECT :: 0x314F // O1
EVENT_FORM :: 0x3146 // F1
EVENT_KEYWORD :: 0x314B // K1
EVENT_LOCATION_1 :: 0x314C // L1
EVENT_LOCATION_2 :: 0x324C // L2
EVENT_QUEST :: 0x3151 // Q1
EVENT_VALUE_1 :: 0x3156 // V1
EVENT_VALUE_2 :: 0x3256 // V2

// event_form is a story event's form member; ok=false with no event or for a value member.
event_form :: proc(e: ^worldstate.Story_Event, member: i32) -> (Form_ID, bool) {
	if e == nil {return 0, false}
	switch member {
	case EVENT_ACTOR_1:
		return e.ref1, true
	case EVENT_ACTOR_2:
		return e.ref2, true
	case EVENT_OBJECT:
		return e.object, true
	case EVENT_FORM:
		return e.form, true
	case EVENT_KEYWORD:
		return e.keyword, true
	case EVENT_LOCATION_1:
		return e.location1, true
	case EVENT_LOCATION_2:
		return e.location2, true
	case EVENT_QUEST:
		return e.quest, true
	}
	return 0, false
}

@(private)
warn_once :: proc(ctx: ^Context, function: u16) {
	if ctx.warned == nil || ctx.warned^[function] {
		return
	}
	ctx.warned^[function] = true
	log.infof("condition: %s (%d) not implemented — treating it as true", esm.condition_function(function).name, function)
}
