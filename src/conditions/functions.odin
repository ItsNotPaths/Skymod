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

import "../formats/esm"
import "../gamedb"
import "../worldstate"

// (hole condition-functions :tags records :sev blocker) 3 of the 244 condition functions Skyrim.esm uses are implemented, and an unanswerable condition PASSES — so 83,759 authored gates are mostly open doors, not gates.
// (hole perk-entry-conditions :tags combat :sev gap :needs (condition-functions perk-entries)) perk ENTRY gates (1,111 conditions over 47 functions, led by has-keyword) are not read; once perk entries decode, every entry would apply ungated.
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
	{277, "base-actor-value", fn_base_actor_value},
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

// CTDA-FN 277 — GetBaseActorValue (UESP Function Indices; 14 is GetActorValue, 640 GetActorValuePercent).
//
// EVIDENCE: 249 uses, all on PERK take-gates. param1 is NOT a form — it is a small integer that
// indexes the engine ActorValue enum, and it appears with >= against values like 60. The sample
// that names itself: param1 0x14 (index 20, Destruction) compared >= 60, on a Destruction perk.
// That is a skill-level requirement, and it is where the perk tree's level gate actually lives —
// AVIF's nodes carry no such field, contrary to what docs/menus.md long assumed.
@(private)
fn_base_actor_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.db == nil || ctx.ws == nil || c.param1 >= esm.ACTOR_VALUE_COUNT {
		return 0, false
	}
	return worldstate.av_base(ctx.ws, ctx.db, on, gamedb.AV_NAMES[c.param1]), true
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
	return f32(worldstate.inv_count(ctx.ws, ctx.db, on, gamedb.condition_param1_form(c))), true
}

// (hole ctda-659 :tags records :sev gap :needs (crafting-screen)) CTDA-FN 659 (384 uses on COBJ, second only to has-perk) is not implemented: no crafting screen says which item is selected, and player-made enchantments have no instance data, so every tempering recipe is offered.
// CTDA-FN 659 — tempering target is enchanted (INFERRED): param1 is unused, the operator is != and
// the comparison is 1. A base item's enchantment is gamedb.Equip_Slot.enchantment.
//
// The perk ENTRY gates (1,111 conditions over 47 functions, led by CTDA-FN 560 has-keyword) belong
// with the combat system. Dialogue's 55,641 belong with the dialogue project.
