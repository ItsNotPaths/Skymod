package conditions

// The condition function bodies. Names and parameter kinds come from xEdit's table
// (esm.CONDITION_FUNCTIONS); a function without a body here passes.

import "../formats/esm"
import "../gamedb"
import "../worldstate"

// (hole condition-functions :tags (records quest) :sev blocker) 3 of the 244 condition functions Skyrim.esm uses are implemented, and an unanswerable condition PASSES. 30 of the top 40 read data we already store (85% of 68,007 quest and dialogue conditions); GetVMQuestVariable (5.5%) needs a Context hook into Lua, and Context has no owning quest or story event (run-on QuestAlias and EventData fall back to the subject).
// Eval answers one condition. `on` is the object the run-on selected. Returns the value to compare
// plus whether it could answer at all; answered=false is treated exactly like an unknown function,
// so the condition passes.
Eval :: #type proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool)

Function :: struct {
	index: u16,
	eval:  Eval,
}

// TABLE is small enough to scan linearly. Swap it for an array by index when it grows.
@(rodata)
TABLE := []Function{{448, fn_has_perk}, {277, fn_base_actor_value}, {47, fn_item_count}}

@(private)
lookup :: proc(index: u16) -> (Function, bool) {
	for f in TABLE {
		if f.index == index {
			return f, true
		}
	}
	return {}, false
}

// implemented reports whether a function has a body. For diagnostics.
implemented :: proc(index: u16) -> bool {
	_, ok := lookup(index)
	return ok
}

// HasPerk(perk).
@(private)
fn_has_perk :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.ws == nil {
		return 0, false
	}
	return worldstate.perk_has(ctx.ws, ctx.db, on, gamedb.condition_param1_form(c)) ? 1 : 0, true
}

// GetBaseActorValue(actor value index). On a PERK take-gate this is the skill requirement.
@(private)
fn_base_actor_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.db == nil || ctx.ws == nil || c.param1 >= esm.ACTOR_VALUE_COUNT {
		return 0, false
	}
	return worldstate.av_base(ctx.ws, ctx.db, on, gamedb.AV_NAMES[c.param1]), true
}

// GetItemCount(item).
@(private)
fn_item_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.ws == nil {
		return 0, false
	}
	return f32(worldstate.inv_count(ctx.ws, ctx.db, on, gamedb.condition_param1_form(c))), true
}

// (hole ctda-659 :tags records :sev gap :needs (crafting-screen)) EPTemperingItemIsEnchanted (659; 384 uses on COBJ, second only to HasPerk) is not implemented: no crafting screen says which item is selected, and player-made enchantments have no instance data, so every tempering recipe is offered.
