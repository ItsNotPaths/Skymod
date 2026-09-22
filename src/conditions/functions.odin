package conditions

// The condition function table.
//
// GREP `CTDA-FN` for every place a function index is named, here and in src/gamedb/conditions.odin.
//
// EVERY IDENTITY BELOW IS INFERRED, not documented. The data carries a number and no name, so each
// was derived from the real Skyrim.esm: which record types use it, what its parameters resolve to,
// and which operator and comparison values it appears with. The evidence is recorded per entry and
// the full reasoning is in docs/conditions.md. Confirm each against the Creation Kit before
// treating it as settled; if one turns out to be wrong, its entry is the only thing to change.
//
// Skyrim.esm uses 244 distinct functions across 83,759 conditions, and two thirds of those are
// dialogue. This table deliberately covers only what the already-indexed records ask, which is a
// very short list — see the coverage note on each entry.

import "../gamedb"
import "../worldstate"

// HOLE(records, blocker): 7 of the 244 condition functions Skyrim.esm uses are implemented, and an unanswerable condition PASSES — so 83,759 authored gates are mostly open doors, not gates.
// HOLE(combat, gap): perk ENTRY gates are 1,111 conditions over 47 functions, led by has-keyword, and none are evaluated — every perk entry applies unconditionally.
// Eval answers one condition. `on` is the object the run-on selected. Returns the value to compare
// plus whether it could answer at all; answered=false is treated exactly like an unknown function,
// so the condition passes.
Eval :: #type proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool)

Function :: struct {
	index: u16,
	name:  string, // the INFERRED identity — see the file header
	eval:  Eval,
}

// TABLE is small enough to scan linearly. Swap it for a map if it grows past a few dozen entries.
@(rodata)
TABLE := []Function {
	{448, "has-perk", fn_has_perk},
	{277, "actor-value-by-index", fn_actor_value_by_index},
	{47, "item-count", fn_item_count},
}

@(private)
lookup :: proc(index: u16) -> (Function, bool) {
	for f in TABLE {
		if f.index == index {
			return f, true
		}
	}
	return {}, false
}

// name_of returns a function's inferred name, or "" when it is not implemented. For diagnostics.
name_of :: proc(index: u16) -> string {
	if f, ok := lookup(index); ok {
		return f.name
	}
	return ""
}

// CTDA-FN 448 — has-perk (INFERRED).
//
// EVIDENCE: 503 uses on COBJ and 263 on PERK take-gates. param1 always resolves to a PERK record
// (ArcaneBlacksmith on the tempering recipes, AugmentedShock and friends on perks), the operator is
// always ==, and the comparison is 1. Pairing ArcaneBlacksmith with function 659 reproduces the
// vanilla rule that enchanted gear cannot be tempered without that perk.
//
// COVERAGE: the single biggest condition function in both crafting and perk gating.
@(private)
fn_has_perk :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.ws == nil {
		return 0, false
	}
	return worldstate.perk_has(ctx.ws, on, gamedb.condition_param1_form(c)) ? 1 : 0, true
}

// CTDA-FN 277 — actor value by index (INFERRED).
//
// EVIDENCE: 249 uses, all on PERK take-gates. param1 is NOT a form — it is a small integer that
// indexes the engine ActorValue enum, and it appears with >= against values like 60. The sample
// that names itself: param1 0x14 (index 20, Destruction) compared >= 60, on a Destruction perk.
// That is a skill-level requirement, and it is where the perk tree's level gate actually lives —
// AVIF's nodes carry no such field, contrary to what docs/menus.md long assumed.
//
// The index is joined to worldstate's name-keyed store through gamedb.actor_value_key, the bridge
// AVIF exists to provide.
@(private)
fn_actor_value_by_index :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.db == nil || ctx.ws == nil {
		return 0, false
	}
	key, kok := gamedb.actor_value_key(ctx.db, i32(c.param1))
	if !kok {
		return 0, false // an index with no AVIF record — engine-only slot
	}
	v, _ := worldstate.av_get(ctx.ws, on, key) // unset reads 0, which is a real answer
	return v, true
}

// CTDA-FN 47 — item count (INFERRED).
//
// EVIDENCE: 15 uses on COBJ. param1 resolves to a carriable item (FoxPelt, GeneralTulliusArmor) and
// the operator is >= with a comparison of 1 — "the player is holding at least one of these", which
// is how a recipe requires a quest or unique item it does not consume.
//
// CAVEAT: worldstate's inventory store is overlay-only, so on a fresh game every count reads 0
// until a baseline-inventory index exists. The answer is honest, just incomplete.
@(private)
fn_item_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.ws == nil {
		return 0, false
	}
	return f32(worldstate.inv_count(ctx.ws, on, gamedb.condition_param1_form(c))), true
}

// HOLE(records, gap): EITM (a base item's enchantment) is decoded by nothing, so CTDA-FN 659 — 384 uses on COBJ, second only to has-perk — is permanently unknown and offers every tempering recipe.
// NOT IMPLEMENTED, and the next one worth doing:
//
// CTDA-FN 659 — tempering target is enchanted (INFERRED). 384 uses on COBJ, second only to
// has-perk. param1 is unused, the operator is != and the comparison is 1. It needs two things that
// do not exist: a crafting menu to say WHICH item is selected, and the item's enchantment — base
// items carry it in an EITM subrecord that nothing decodes, and player-enchanted instances need
// runtime item data. Until then it is unknown and the row is offered, which is what happens today.
//
// The perk ENTRY gates (1,111 conditions over 47 functions, led by CTDA-FN 560 has-keyword) belong
// with the combat system. Dialogue's 55,641 belong with the dialogue project.
