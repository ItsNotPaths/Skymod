package conditions

// The condition function bodies. Names and parameter kinds come from xEdit's table
// (esm.CONDITION_FUNCTIONS); a function without a body here passes. `on` is the object the run-on
// selected. A body reads the same worldstate proc as the matching Papyrus native.

import "core:math/rand"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

// (hole condition-functions :tags (records quest) :sev gap) no body for IsSneaking and GetOffersServicesNow, nor for the quest and dialogue tail past the top 40 (4% of 68,007 conditions): they pass.
// (hole relationship-records :tags (records quest) :sev gap) RELA is never indexed, so GetRelationshipRank (363 quest and dialogue conditions) has no body: an untouched pair reads Acquaintance at runtime.
// (hole starts-dead :tags (records world) :sev polish) a ref placed dead reads alive: no baseline "starts dead" flag is surfaced, so GetDead and IsDead see only deaths at runtime.

// Eval answers one condition. Returns the value to compare plus whether it could answer at all;
// answered=false is treated exactly like an unknown function, so the condition passes.
Eval :: #type proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool)

@(rodata)
TABLE := #partial [esm.CONDITION_FUNCTION_COUNT]Eval {
	1   = fn_get_distance,
	14  = fn_get_actor_value,
	46  = fn_get_dead,
	47  = fn_get_item_count,
	56  = fn_get_quest_running,
	58  = fn_get_stage,
	59  = fn_get_stage_done,
	67  = fn_get_in_cell,
	69  = fn_get_is_race,
	70  = fn_get_is_sex,
	71  = fn_get_in_faction,
	72  = fn_get_is_id,
	73  = fn_get_faction_rank,
	74  = fn_get_global_value,
	77  = fn_get_random_percent,
	130 = fn_get_pc_is_race,
	131 = fn_get_pc_is_sex,
	182 = fn_get_equipped,
	277 = fn_get_base_actor_value,
	300 = fn_is_in_interior,
	310 = fn_get_in_worldspace,
	359 = fn_get_in_current_loc,
	426 = fn_get_is_voice_type,
	448 = fn_has_perk,
	543 = fn_get_quest_completed,
	560 = fn_has_keyword,
	576 = fn_get_event_data,
	562 = fn_location_has_keyword,
	566 = fn_get_is_alias_ref,
	579 = fn_get_equipped_shout,
	606 = fn_get_keyword_data_for_location,
	629 = fn_get_vm_quest_variable,
	651 = fn_get_keyword_data_for_current_location,
	650 = fn_is_linked_to,
}

@(private)
lookup :: proc(index: u16) -> (Eval, bool) {
	if int(index) >= len(TABLE) {return nil, false}
	return TABLE[index], TABLE[index] != nil
}

// implemented reports whether a function has a body. For diagnostics.
implemented :: proc(index: u16) -> bool {
	_, ok := lookup(index)
	return ok
}

@(private = "file")
yes :: proc(b: bool) -> (f32, bool) {return 1 if b else 0, true}

@(private = "file")
p1 :: proc(c: gamedb.Condition) -> Form_ID {return gamedb.condition_param1_form(c)}

// matches: `form` is `want`, or `want` is a FormList that holds it.
@(private = "file")
matches :: proc(ctx: ^Context, form, want: Form_ID) -> bool {
	return form == want || worldstate.list_has(ctx.ws, ctx.db, want, form)
}

// ── quests and globals ──────────────────────────────────────────────────────────────────────────

@(private = "file")
fn_get_stage :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.quest_stage(ctx.ws, p1(c))), true
}

@(private = "file")
fn_get_stage_done :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.quest_is_stage_done(ctx.ws, p1(c), u16(c.param2)))
}

@(private = "file")
fn_get_quest_running :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.quest_running(ctx.ws, ctx.db, p1(c)))
}

@(private = "file")
fn_get_quest_completed :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.quest_completed(ctx.ws, ctx.db, p1(c)))
}

@(private = "file")
fn_get_global_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return worldstate.global_value(ctx.ws, ctx.db, p1(c)), true
}

// GetRandomPercent rolls 0..99 on every evaluation.
@(private = "file")
fn_get_random_percent :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(rand.int_max(100)), true
}

// GetIsAliasRef: `on` fills the owning quest's alias param1.
@(private = "file")
fn_get_is_alias_ref :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	ref, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(ref != 0 && ref == on)
}

// GetVMQuestVariable(quest, "::name_var"): a quest script's int, float or bool member.
@(private = "file")
fn_get_vm_quest_variable :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.quest_vars.read == nil {return 0, false}
	return ctx.quest_vars.read(ctx.quest_vars.data, p1(c), c.text)
}

// ── actors ──────────────────────────────────────────────────────────────────────────────────────

// GetIsID compares the base form; a leveled actor compares the NPC_ it spawned as.
@(private = "file")
fn_get_is_id :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	base := worldstate.actor_pick(ctx.ws, ctx.db, on)
	if base == 0 {base = worldstate.ref_base(ctx.ws, ctx.db, on)}
	return yes(base != 0 && base == p1(c))
}

@(private = "file")
fn_get_in_faction :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.in_faction(ctx.ws, ctx.db, on, p1(c)))
}

@(private = "file")
fn_get_faction_rank :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	r, ok := worldstate.faction_rank(ctx.ws, ctx.db, on, p1(c))
	return f32(r) if ok else -1, true
}

@(private = "file")
fn_get_is_voice_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	voice := worldstate.actor_traits(ctx.ws, ctx.db, on).voice
	return yes(voice != 0 && matches(ctx, voice, p1(c)))
}

@(private = "file")
fn_get_is_race :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.actor_traits(ctx.ws, ctx.db, on).race == p1(c))
}

@(private = "file")
fn_get_pc_is_race :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return fn_get_is_race(ctx, c, formid.PLAYER)
}

// GetIsSex(sex): 0 male, 1 female.
@(private = "file")
fn_get_is_sex :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	female := worldstate.actor_traits(ctx.ws, ctx.db, on).flags & esm.ACBS_FEMALE != 0
	return yes(u64(female ? 1 : 0) == c.param1)
}

@(private = "file")
fn_get_pc_is_sex :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return fn_get_is_sex(ctx, c, formid.PLAYER)
}

@(private = "file")
fn_get_dead :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.is_dead(ctx.ws, on))
}

// GetActorValue(index): the current value.
@(private = "file")
fn_get_actor_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if c.param1 >= esm.ACTOR_VALUE_COUNT {return 0, false}
	return worldstate.av_current(ctx.ws, ctx.db, on, gamedb.AV_NAMES[c.param1]), true
}

// GetBaseActorValue(index). On a PERK take-gate this is the skill requirement.
@(private = "file")
fn_get_base_actor_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if c.param1 >= esm.ACTOR_VALUE_COUNT {return 0, false}
	return worldstate.av_base(ctx.ws, ctx.db, on, gamedb.AV_NAMES[c.param1]), true
}

@(private = "file")
fn_has_perk :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.perk_has(ctx.ws, ctx.db, on, p1(c)))
}

@(private = "file")
fn_get_item_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.inv_count(ctx.ws, ctx.db, on, p1(c))), true
}

// GetEquipped(item or FormList).
@(private = "file")
fn_get_equipped :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	want := p1(c)
	if worldstate.is_equipped(ctx.ws, ctx.db, on, want) {return 1, true}
	authored, _ := gamedb.form_list_of(ctx.db, want)
	for item in authored {
		if worldstate.is_equipped(ctx.ws, ctx.db, on, item) {return 1, true}
	}
	for item in worldstate.list_added(ctx.ws, want) {
		if worldstate.is_equipped(ctx.ws, ctx.db, on, item) {return 1, true}
	}
	return 0, true
}

@(private = "file")
fn_get_equipped_shout :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.in_slot(ctx.ws, ctx.db, on, .Voice) == p1(c))
}

// HasKeyword reads the ref's base object (CK wiki).
@(private = "file")
fn_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.has_keyword(ctx.ws, ctx.db, on, p1(c)))
}

// ── places ──────────────────────────────────────────────────────────────────────────────────────

@(private = "file")
fn_get_in_cell :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.ref_grid_cell(ctx.ws, ctx.db, on) == p1(c))
}

@(private = "file")
fn_get_in_worldspace :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	cell, ok := gamedb.cell_by_formid(ctx.db, worldstate.ref_cell(ctx.ws, ctx.db, on))
	return yes(ok && !cell.interior && matches(ctx, cell.world_form_id, p1(c)))
}

@(private = "file")
fn_is_in_interior :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	cell, ok := gamedb.cell_by_formid(ctx.db, worldstate.ref_cell(ctx.ws, ctx.db, on))
	return yes(ok && cell.interior)
}

// GetInCurrentLoc: the ref's location is the given one or inside it (CK wiki).
@(private = "file")
fn_get_in_current_loc :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.location_within(ctx.db, worldstate.ref_location(ctx.ws, ctx.db, on), p1(c)))
}

@(private = "file")
fn_location_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.has_keyword(ctx.db, worldstate.ref_location(ctx.ws, ctx.db, on), p1(c)))
}

// GetKeywordDataForLocation(location, keyword): the value Location.SetKeywordData stored; 0 unset.
@(private = "file")
fn_get_keyword_data_for_location :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return ctx.ws.keyword_data[{p1(c), gamedb.condition_param2_form(c)}], true
}

@(private = "file")
fn_get_keyword_data_for_current_location :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return ctx.ws.keyword_data[{worldstate.ref_location(ctx.ws, ctx.db, on), p1(c)}], true
}

@(private = "file")
fn_get_distance :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return worldstate.ref_distance(ctx.ws, ctx.db, on, other), true
}

// IsLinkedTo(ref, keyword): `on`'s link on that keyword is the ref.
@(private = "file")
fn_is_linked_to :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	linked, _ := gamedb.linked_ref(ctx.db, on, gamedb.condition_param2_form(c))
	return yes(linked != 0 && linked == other)
}

// GetEventData(function and member, form): the one way to test an event's values and non-ref forms.
// param1 packs the function (low 16 bits: 0 GetIsID, 1 IsInList, 2 GetValue, 3 HasKeyword,
// 4 GetItemValue) and the member (high 16 bits).
@(private = "file")
fn_get_event_data :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.event == nil {return 0, false}
	function, member := c.param1 & 0xFFFF, i32(c.param1 >> 16)
	if function == 2 {
		switch member {
		case EVENT_VALUE_1:
			return f32(ctx.event.value1), true
		case EVENT_VALUE_2:
			return f32(ctx.event.value2), true
		}
		return 0, false
	}
	want := gamedb.condition_param2_form(c)
	form, ok := event_form(ctx.event, member)
	if !ok {return 0, false}
	switch function {
	case 0:
		base := worldstate.ref_base(ctx.ws, ctx.db, form)
		return yes(form == want || (base != 0 && base == want))
	case 1:
		return yes(matches(ctx, form, want) || matches(ctx, worldstate.ref_base(ctx.ws, ctx.db, form), want))
	case 3:
		return yes(worldstate.has_keyword(ctx.ws, ctx.db, form, want))
	}
	return 0, false
}

// (hole ctda-659 :tags records :sev gap :needs (crafting-screen)) EPTemperingItemIsEnchanted (659; 384 uses on COBJ, second only to HasPerk) is not implemented: no crafting screen says which item is selected, and player-made enchantments have no instance data, so every tempering recipe is offered.
