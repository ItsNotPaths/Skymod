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
	db:      ^gamedb.DB,
	ws:      ^worldstate.World_State,
	subject: Form_ID, // the actor or object the question is about — usually the player
	target:  Form_ID,
	reference: Form_ID,
	// warned guards the log-once for unimplemented functions, exactly as the native registry does.
	// Optional: nil simply means do not log. The caller owns it.
	warned: ^map[u16]bool,
}

// all evaluates a condition list the way the format defines it: an AND, with runs of OR.
//
// A condition whose Or flag is set is joined to the FOLLOWING one as an OR, so consecutive
// flagged conditions form a group that passes if ANY member passes, and the groups are ANDed. An
// empty list passes. 11,460 of the base game's conditions set the flag, so a reader that treats the
// list as a flat AND silently inverts those.
all :: proc(ctx: ^Context, conds: []gamedb.Condition) -> bool {
	group := false
	for c in conds {
		group ||= test(ctx, c)
		if .Or not_in c.flags { // the group closes here, and must have passed
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
	fn, known := lookup(c.function)
	if !known {
		warn_once(ctx, c.function)
		return true // never hide content over a question we cannot answer
	}
	got, answered := fn.eval(ctx, c, run_on_form(ctx, c))
	if !answered {
		warn_once(ctx, c.function)
		return true
	}
	value := c.value
	if .Use_Global in c.flags {
		if ctx.ws == nil || ctx.db == nil {
			return true
		}
		value = worldstate.global_value(ctx.ws, ctx.db, c.global)
	}
	return esm.condition_holds(esm.Condition{op = c.op, value = value}, got)
}

// run_on_form resolves which object the condition asks about. An unhandled run-on falls back to the
// subject rather than to nothing, so the question is still asked of something sensible.
@(private)
run_on_form :: proc(ctx: ^Context, c: gamedb.Condition) -> Form_ID {
	subject, target := ctx.subject, ctx.target
	if .Swap in c.flags {
		subject, target = target, subject
	}
	switch c.run_on {
	case .Subject:
		return subject
	case .Target, .CombatTarget:
		return target
	case .Reference:
		return c.reference
	case .LinkedRef, .QuestAlias, .PackageData, .EventData:
		return subject
	}
	return subject
}

@(private)
warn_once :: proc(ctx: ^Context, function: u16) {
	if ctx.warned == nil || ctx.warned^[function] {
		return
	}
	ctx.warned^[function] = true
	log.infof("condition: %s (%d) not implemented — treating it as true", esm.condition_function(function).name, function)
}
