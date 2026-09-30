package conditions

// The condition function bodies. Names and parameter kinds come from xEdit's table
// (esm.CONDITION_FUNCTIONS); a function without a body here passes. `on` is the object the run-on
// selected. A body reads the same worldstate proc as the matching Papyrus native.

import "core:math/rand"
import "../actorstate"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../sighthost"
import "../worldstate"

// (hole condition-functions :tags (records dialogue query) :sev polish) no body for GetClothingValue (2 uses, build/out/wsQ/measure14.py), so it passes: the CK wiki gives no formula for how an item's value is scaled by the slots it covers.
// (hole starts-dead :tags (records world) :sev polish) a ref placed dead reads alive: no baseline "starts dead" flag is surfaced, so GetDead and IsDead see only deaths at runtime.

// Eval answers one condition. Returns the value to compare plus whether it could answer at all;
// answered=false is treated exactly like an unknown function, so the condition passes.
Eval :: #type proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool)

@(rodata)
TABLE := #partial [esm.CONDITION_FUNCTION_COUNT]Eval {
	1   = fn_get_distance,
	5   = fn_get_locked,
	14  = fn_get_actor_value,
	18  = fn_get_current_time,
	25  = fn_is_moving,
	27  = fn_get_line_of_sight,
	32  = fn_get_in_same_cell,
	35  = fn_get_disabled,
	39  = fn_get_disease,
	45  = fn_get_detected,
	46  = fn_get_dead,
	47  = fn_get_item_count,
	48  = fn_get_gold,
	49  = fn_get_sleeping,
	50  = fn_get_talked_to_pc,
	56  = fn_get_quest_running,
	58  = fn_get_stage,
	59  = fn_get_stage_done,
	61  = fn_get_alarmed,
	62  = fn_is_raining,
	66  = fn_get_should_attack,
	67  = fn_get_in_cell,
	69  = fn_get_is_race,
	70  = fn_get_is_sex,
	71  = fn_get_in_faction,
	72  = fn_get_is_id,
	73  = fn_get_faction_rank,
	74  = fn_get_global_value,
	75  = fn_is_snowing,
	77  = fn_get_random_percent,
	79  = fn_get_quest_variable,
	80  = fn_get_level,
	84  = fn_get_dead_count,
	101 = fn_resting,
	108 = fn_get_weapon_anim_type,
	109 = fn_is_weapon_skill_type,
	125 = fn_is_guard,
	130 = fn_get_pc_is_race,
	131 = fn_get_pc_is_sex,
	132 = fn_get_pc_in_faction,
	136 = fn_get_is_reference,
	144 = fn_get_trespass_warning_level,
	145 = fn_is_trespassing,
	149 = fn_get_is_current_weather,
	157 = fn_get_open_state,
	159 = fn_get_sitting,
	161 = fn_get_is_current_package,
	170 = fn_get_day_of_week,
	180 = fn_has_same_editor_loc_as_ref,
	181 = fn_has_same_editor_loc_as_ref_alias,
	182 = fn_get_equipped,
	203 = fn_get_destroyed,
	214 = fn_has_magic_effect,
	223 = fn_is_spell_target,
	237 = fn_get_is_ghost,
	248 = fn_is_scene_playing,
	249 = fn_is_in_dialogue_with_player,
	250 = fn_get_location_cleared,
	255 = fn_get_offers_services_now,
	258 = fn_has_association_type,
	259 = fn_has_family_relationship,
	261 = fn_has_parent_relationship,
	263 = fn_resting,
	264 = fn_has_spell,
	266 = fn_is_pleasant,
	274 = fn_resting,
	277 = fn_get_base_actor_value,
	286 = fn_is_sneaking,
	288 = fn_get_friend_hit,
	289 = fn_is_in_combat,
	300 = fn_is_in_interior,
	310 = fn_get_in_worldspace,
	314 = fn_is_actor_a_victim,
	353 = fn_is_actor,
	354 = fn_is_essential,
	359 = fn_get_in_current_loc,
	360 = fn_get_in_current_loc_alias,
	365 = fn_is_child,
	372 = fn_is_in_list,
	375 = fn_get_crime_gold_violent,
	376 = fn_get_crime_gold_nonviolent,
	402 = fn_resting,
	403 = fn_get_relationship_rank,
	408 = fn_is_killer,
	415 = fn_resting,
	426 = fn_get_is_voice_type,
	430 = fn_get_health_percentage,
	432 = fn_get_is_object_type,
	444 = fn_get_in_current_loc_form_list,
	448 = fn_has_perk,
	449 = fn_get_faction_relation,
	453 = fn_get_player_teammate,
	459 = fn_get_crime_gold,
	470 = fn_get_destruction_stage,
	476 = fn_is_protected,
	491 = fn_resting,
	497 = fn_can_pay_crime_gold,
	499 = fn_get_days_in_jail,
	503 = fn_get_allow_world_interactions,
	513 = fn_is_combat_target,
	528 = fn_is_in_critical_stage,
	543 = fn_get_quest_completed,
	550 = fn_is_scene_action_complete,
	555 = fn_has_loaded_3d,
	560 = fn_has_keyword,
	561 = fn_has_ref_type,
	562 = fn_location_has_keyword,
	563 = fn_location_has_ref_type,
	565 = fn_get_is_editor_location,
	566 = fn_get_is_alias_ref,
	567 = fn_get_is_editor_loc_alias,
	576 = fn_get_event_data,
	579 = fn_get_equipped_shout,
	580 = fn_resting,
	590 = fn_is_in_scene,
	592 = fn_get_ref_type_alive_count,
	594 = fn_resting,
	596 = fn_spell_has_keyword,
	597 = fn_get_equipped_item_type,
	600 = fn_get_loc_alias_ref_type_dead_count,
	601 = fn_get_loc_alias_ref_type_alive_count,
	604 = fn_is_in_same_current_loc_as_ref_alias,
	605 = fn_loc_alias_is_location,
	606 = fn_get_keyword_data_for_location,
	610 = fn_loc_alias_has_keyword,
	612 = fn_get_numeric_package_data,
	616 = fn_get_lowest_relationship_rank,
	624 = fn_get_in_container,
	629 = fn_get_vm_quest_variable,
	630 = fn_get_vm_script_variable,
	632 = fn_resting,
	633 = fn_resting,
	635 = fn_resting,
	638 = fn_is_in_friend_state_with_player,
	640 = fn_get_actor_value_percent,
	641 = fn_is_unique,
	650 = fn_is_linked_to,
	651 = fn_get_keyword_data_for_current_location,
	652 = fn_get_in_shared_crime_faction,
	654 = fn_resting,
	655 = fn_resting,
	656 = fn_get_arrested_state,
	657 = fn_get_arresting_actor,
	682 = fn_worn_has_keyword,
	698 = fn_is_allowed_to_fly,
	699 = fn_has_magic_effect_keyword,
	700 = fn_resting,
	707 = fn_get_combat_target_has_keyword,
	715 = fn_is_undead,
	722 = fn_worn_apparel_has_keyword_count,
	726 = fn_does_not_exist,
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

// The crime gold functions: with a faction, `on`'s bounty there; without, the bounty `on` knows on
// the actor it talks to (a guard's line asks about the player's crimes).
@(private = "file")
condition_bounty :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> worldstate.Bounty {
	if f := p1(c); f != 0 {return worldstate.wanted(ctx.ws, on, f).bounty}
	return worldstate.bounty(ctx.ws, ctx.db, on, ctx.target)
}

@(private = "file")
fn_get_crime_gold :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.total(condition_bounty(ctx, c, on))), true
}

@(private = "file")
fn_get_crime_gold_violent :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(condition_bounty(ctx, c, on).violent), true
}

@(private = "file")
fn_get_crime_gold_nonviolent :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(condition_bounty(ctx, c, on).nonviolent), true
}

// CanPayCrimeGold: the actor `on` talks to carries the gold for the bounty `on` knows on it.
@(private = "file")
fn_can_pay_crime_gold :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	b := worldstate.bounty(ctx.ws, ctx.db, on, ctx.target)
	return yes(worldstate.inv_count(ctx.ws, ctx.db, ctx.target, formid.GOLD) >= worldstate.total(b))
}

// The crime functions a speaker's line asks about the actor it talks to (vanilla: the player).
@(private = "file")
fn_is_actor_a_victim :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(ctx.ws.crime_victims[{on, ctx.target}])
}

@(private = "file")
fn_get_days_in_jail :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(ctx.ws.days_jailed[ctx.target]), true
}

@(private = "file")
fn_get_arresting_actor :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(ctx.target != 0 && ctx.ws.arresting[on] == ctx.target)
}

@(private = "file")
fn_get_arrested_state :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.arrest_state(ctx.ws, on)), true
}

@(private = "file")
fn_get_in_shared_crime_faction :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.shared_crime_faction(ctx.ws, ctx.db, on, p1(c)))
}

@(private = "file")
fn_is_trespassing :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.is_trespassing(ctx.ws, ctx.db, on))
}

// GetTrespassWarningLevel: the warning `on` is on with the actor it talks to.
@(private = "file")
fn_get_trespass_warning_level :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.trespass_warning(ctx.ws, on, ctx.target)), true
}

// GetAlarmed: the actor fights someone, or a guard confronts someone.
@(private = "file")
fn_get_alarmed :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on in ctx.ws.alarmed)
}

// GetQuestVariable is deprecated and does not work in Skyrim (CK wiki): it reads 0.
@(private = "file")
fn_get_quest_variable :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return 0, true
}

// GetDayOfWeek: 0 Sundas .. 6 Loredas.
@(private = "file")
fn_get_day_of_week :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.weekday(ctx.ws)), true
}

// GetVMQuestVariable(quest, "::name_var"): a quest script's int, float or bool member.
@(private = "file")
fn_get_vm_quest_variable :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if ctx.quest_vars.read == nil {return 0, false}
	return ctx.quest_vars.read(ctx.quest_vars.data, p1(c), c.text)
}

// ── actors ──────────────────────────────────────────────────────────────────────────────────────

// GetIsID compares the base form. A leveled actor matches both its own base (the Whiterun gate
// guard's quest names it) and the NPC_ it spawned as.
@(private = "file")
fn_get_is_id :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	id := p1(c)
	return yes(id != 0 && (id == worldstate.ref_base(ctx.ws, ctx.db, on) || id == worldstate.actor_pick(ctx.ws, ctx.db, on)))
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
	return fn_get_is_race(ctx, c, ctx.ws.player)
}

// GetIsSex(sex): 0 male, 1 female.
@(private = "file")
fn_get_is_sex :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	female := worldstate.actor_traits(ctx.ws, ctx.db, on).flags & esm.ACBS_FEMALE != 0
	return yes(u64(female ? 1 : 0) == c.param1)
}

@(private = "file")
fn_get_pc_is_sex :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return fn_get_is_sex(ctx, c, ctx.ws.player)
}

@(private = "file")
fn_get_dead :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.is_dead(ctx.ws, ctx.db, on))
}

@(private = "file")
fn_get_talked_to_pc :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.talked_to_pc(ctx.ws, on))
}

@(private = "file")
fn_is_in_dialogue_with_player :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on != 0 && ctx.ws.talking == on)
}

// GetDestructionStage: the subject's destruction stage; 0 when it is in none.
@(private = "file")
fn_get_destruction_stage :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	stage, _ := worldstate.destruction_stage(ctx.ws, ctx.db, on)
	return f32(max(stage, 0)), true
}

// IsInCriticalStage(stage): the subject's death is at that stage (SetCriticalStage).
@(private = "file")
fn_is_in_critical_stage :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(i32(ctx.ws.critical[on].stage) == i32(c.param1))
}

// IsInCombat: the subject fights someone or someone fights it (the AI's fights this tick).
@(private = "file")
fn_is_in_combat :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.in_combat(ctx.ws, on))
}

// GetShouldAttack(target): the subject would attack the target on sight: it is hostile to it.
@(private = "file")
fn_get_should_attack :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	target, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(worldstate.hostile(ctx.ws, ctx.db, on, target))
}

// IsCombatTarget(actor): the subject is whom that actor fights.
@(private = "file")
fn_is_combat_target :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	actor, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(on != 0 && ctx.ws.ai.fighting[actor] == on)
}

// GetCombatTargetHasKeyword(keyword): whom the subject fights has the keyword.
@(private = "file")
fn_get_combat_target_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	target := ctx.ws.ai.fighting[on]
	return yes(target != 0 && worldstate.has_keyword(ctx.ws, ctx.db, target, p1(c)))
}

// fn_get_friend_hit is how many of the target's hits the subject let go as a friend (a Hit line's
// target is whoever hit the speaker).
fn_get_friend_hit :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(ctx.ws.friend_hits[{on, ctx.target}]), true
}

// Functions about a system that does not exist yet answer its resting state, which is the true
// answer in this engine until the system comes: nobody fights, trespasses, sneaks or runs a package.
// (hole crime-conditions :tags (combat quest) :sev gap :needs (persuasion)) IsBribedbyPlayer reads 0: nothing bribes.
// (hole action-state-conditions :tags (combat unclaimed) :sev gap :needs (actor-states)) IsAttackType (16 uses in damage perk tabs, SE), IsSprinting (4) and IsBlocking (2) have no body, so they pass; perk entries gated on them are not translated (magictranslate/perks.odin UNBUILT).
// (hole action-state-conditions :tags (combat unclaimed) :sev gap :needs (actor-states)) IsWeaponOut, IsWeaponMagicOut, IsCasting and IsBleedingOut read 0: no actor has a drawn, casting or bleedout state.
// (hole package-conditions :tags ai :sev gap) IsSmallBump and GetGroupMemberCount read 0: no bump is noticed (and no line answers one), and there are no package groups.
// (hole magic-conditions :tags (magic records) :sev gap) these have no body, so they pass: HasShout, GetSpellUsageNum, HasEquippedSpell, GetCurrentCastingType, IsCurrentSpell, IsWardState, IsDualCasting, EPMagic_IsAdvanceSkill, EPMagic_SpellHasKeyword, EPMagic_SpellHasSkill, HasBoundWeaponEquipped, SpellHasCastingPerk, EffectWasDualCast. A perk gated on an EPMagic_ one applies to every spell.
// (hole commanded-actors :tags (magic unclaimed) :sev gap :needs (other-archetypes)) IsCommandedActor reads 0: no spell raises or commands an actor.
// (hole flight :tags (animation combat unclaimed) :sev gap :needs (actor-states)) GetIsFlying and GetFlyingState read 0: no dragon flies.
// (hole map-markers :tags quest :sev gap) GetMapMarkerVisible reads 0: no marker is ever found; nothing discovers one as the player nears it, and AddToMap and IsMapMarkerVisible are not natives.
// (hole persuasion :tags dialogue :sev gap) GetIntimidateSuccess and GetBribeSuccess read 0: no speech check marks an actor persuaded.
// (hole favor-commands :tags (dialogue ai) :sev gap :needs (teammate-behavior)) IsInFavorState reads 0: no follower takes commands.
@(private = "file")
fn_resting :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return 0, true
}

@(private = "file")
fn_get_player_teammate :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on in ctx.ws.teammates)
}

@(private = "file")
fn_is_unique :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.actor_flag(ctx.ws, ctx.db, on, esm.ACBS_UNIQUE))
}

// IsChild: the actor's race has the Child flag (RACE DATA 0x4).
@(private = "file")
fn_is_child :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	race, _ := gamedb.race_of(ctx.db, worldstate.actor_traits(ctx.ws, ctx.db, on).race)
	return yes(race.info.flags & 0x4 != 0)
}

@(private = "file")
fn_is_actor :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.ref_base(ctx.ws, ctx.db, on) in ctx.db.actors)
}

@(private = "file")
fn_get_in_same_cell :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	cell := worldstate.ref_cell(ctx.ws, ctx.db, on)
	return yes(cell != 0 && cell == worldstate.ref_cell(ctx.ws, ctx.db, other))
}

@(private = "file")
fn_get_pc_in_faction :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.in_faction(ctx.ws, ctx.db, ctx.ws.player, p1(c)))
}

// GetHealthPercentage: current Health over its maximum, 0 to 1.
@(private = "file")
fn_get_health_percentage :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	most := worldstate.av_max(ctx.ws, ctx.db, on, "Health")
	return worldstate.av_current(ctx.ws, ctx.db, on, "Health") / most if most > 0 else 1, true
}

@(private = "file")
fn_is_in_scene :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.scene_of_actor(ctx.ws, ctx.db, on) != 0)
}

@(private = "file")
fn_is_scene_playing :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.scene_playing(ctx.ws, p1(c)))
}

// IsSceneActionComplete(scene, action index).
@(private = "file")
fn_is_scene_action_complete :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.scene_action_done(ctx.ws, p1(c), u32(c.param2)))
}

// GetRelationshipRank(other): 4 Lover .. 0 Acquaintance .. -4 Archnemesis.
@(private = "file")
fn_get_relationship_rank :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return f32(worldstate.rel_rank(ctx.ws, ctx.db, on, other)), true
}

// HasAssociationType(other, association): their tie is of that kind (spouse, sibling...).
@(private = "file")
fn_has_association_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	kind := worldstate.rel_association(ctx.ws, ctx.db, on, other)
	return yes(kind != 0 && kind == gamedb.condition_param2_form(c))
}

@(private = "file")
fn_has_family_relationship :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(gamedb.association_is_family(ctx.db, worldstate.rel_association(ctx.ws, ctx.db, on, other)))
}

// HasParentRelationship(other): `on` is the parent in their tie.
@(private = "file")
fn_has_parent_relationship :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(worldstate.rel_is_parent(ctx.ws, ctx.db, on, other))
}

// GetLowestRelationshipRank: the lowest rank of the actor's ties, 0 for none.
@(private = "file")
fn_get_lowest_relationship_rank :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	lowest, _ := worldstate.rel_rank_range(ctx.ws, ctx.db, on)
	return f32(lowest), true
}

// IsInFriendStateWithPlayer: the actor is the player's Friend or closer (rank 1 or more).
@(private = "file")
fn_is_in_friend_state_with_player :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.rel_rank(ctx.ws, ctx.db, on, ctx.ws.player) >= 1)
}

// IsKiller(actor): the actor killed `on`.
@(private = "file")
fn_is_killer :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	killer, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(killer != 0 && ctx.ws.killers[on] == killer)
}

@(private = "file")
fn_is_allowed_to_fly :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.allowed_to_fly(ctx.ws, on))
}

// GetDisease: the actor has a disease spell.
@(private = "file")
fn_get_disease :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	for id in worldstate.spell_list(ctx.ws, ctx.db, on) {
		if sp, ok := gamedb.spell_of(ctx.db, id); ok && sp.info.type == .Disease {return 1, true}
	}
	return 0, true
}

// GetEquippedItemType(hand): 0 left, 1 right.
@(private = "file")
fn_get_equipped_item_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.equipped_item_type(ctx.ws, ctx.db, on, .LeftHand if c.param1 == 0 else .RightHand)), true
}

@(private = "file")
fn_get_weapon_anim_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.weapon_anim_type(ctx.ws, ctx.db, on)), true
}

// GetOffersServicesNow: the actor is in a vendor faction that trades now, inside its hours and
// its vendor conditions.
@(private = "file")
fn_get_offers_services_now :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	_, _, _, hour := worldstate.game_date(ctx.ws)
	for id in worldstate.actor_factions_now(ctx.ws, ctx.db, on) {
		f, _ := worldstate.faction(ctx.ws, ctx.db, id)
		v := f.vendor
		if f.flags & esm.FACT_VENDOR == 0 {continue}
		open := f64(v.start) <= hour && hour < f64(v.end) if v.start <= v.end else hour >= f64(v.start) || hour < f64(v.end)
		sub := Context{db = ctx.db, ws = ctx.ws, subject = on, target = ctx.ws.player, quest_vars = ctx.quest_vars}
		if open && all(&sub, v.conditions) {return 1, true}
	}
	return 0, true
}

// GetDeadCount(actor base): how many of its placed actors are dead.
@(private = "file")
fn_get_dead_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.dead_count(ctx.ws, ctx.db, p1(c))), true
}

// SpellHasKeyword(hand, keyword): the spell in that hand (0 left, 1 right) or one of its effects
// has the keyword.
@(private = "file")
fn_spell_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	hand := gamedb.Slot.LeftHand if c.param1 == 0 else .RightHand
	spell := worldstate.in_slot(ctx.ws, ctx.db, on, hand)
	kw := gamedb.condition_param2_form(c)
	if spell == 0 {return 0, true}
	if gamedb.has_keyword(ctx.db, spell, kw) {return 1, true}
	sp, _ := gamedb.spell_of(ctx.db, spell)
	for e in sp.effects {
		if gamedb.has_keyword(ctx.db, e.effect, kw) {return 1, true}
	}
	return 0, true
}

// GetIsObjectType(form type): the xEdit form type of the ref's base. Skyrim.esm asks only 1 Armor,
// 12 Weapon and 13 Actor; other types are not answered.
@(private = "file")
fn_get_is_object_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	base := worldstate.ref_base(ctx.ws, ctx.db, on)
	if base == 0 {base = on}
	switch c.param1 {
	case 1:  return yes(gamedb.form_kind(ctx.db, base) == .Armor)
	case 12: return yes(gamedb.form_kind(ctx.db, base) == .Weapon)
	case 13: return yes(base in ctx.db.actors)
	}
	return 0, false
}

// GetInContainer(container): the item unit is in that container.
@(private = "file")
fn_get_in_container :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	container, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(ctx.ws.units[on].holder == container && container != 0)
}

// GetVMScriptVariable(ref, variable): a member of a script on the ref, as GetVMQuestVariable.
@(private = "file")
fn_get_vm_script_variable :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	ref, ok := param_ref(ctx, c, 0)
	if !ok || ctx.quest_vars.read == nil {return 0, false}
	return ctx.quest_vars.read(ctx.quest_vars.data, ref, c.text)
}

@(private = "file")
fn_loc_alias_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(loc != 0 && gamedb.has_keyword(ctx.db, loc, gamedb.condition_param2_form(c)))
}

// GetFactionRelation(other): how one of the actor's factions stands toward one of the other's: 0
// neutral, 1 enemy, 2 ally, 3 friend (FACT XNAM). The first relation found answers.
@(private = "file")
fn_get_faction_relation :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return f32(worldstate.faction_relation(ctx.ws, ctx.db, on, other)), true
}

@(private = "file")
fn_is_spell_target :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	for h in worldstate.effects_on(ctx.ws, on) {
		if e := ctx.ws.effects[h]; e.spell == p1(c) && !e.finished {return 1, true}
	}
	return 0, true
}

@(private = "file")
fn_has_magic_effect_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.has_effect_keyword(ctx.ws, ctx.db, on, p1(c)))
}

@(private = "file")
fn_get_in_current_loc_form_list :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc := worldstate.ref_location(ctx.ws, ctx.db, on)
	return yes(loc != 0 && worldstate.list_has(ctx.ws, ctx.db, p1(c), loc))
}

// WornApparelHasKeywordCount(keyword): how many armor pieces the actor wears have the keyword.
@(private = "file")
fn_worn_apparel_has_keyword_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	n := 0
	for w in worldstate.equipment(ctx.ws, ctx.db, on).worn {
		slot, _ := gamedb.equip_slot_of(ctx.db, w.item)
		if slot.kind == .Armor && gamedb.has_keyword(ctx.db, w.item, p1(c)) {n += 1}
	}
	return f32(n), true
}

// (hole is-undead-reading :tags combat :sev polish) unsourced: IsUndead read as the ActorTypeUndead keyword (race or base); no record says what the engine tests.
@(private = "file")
fn_is_undead :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	kw, ok := gamedb.keyword_id(ctx.db, "ActorTypeUndead")
	return yes(ok && worldstate.has_keyword(ctx.ws, ctx.db, on, kw))
}

// IsWeaponSkillType(skill): the weapon (a perk tab's) trains that skill, an AV index (WEAP DNAM).
@(private = "file")
fn_is_weapon_skill_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	slot, ok := gamedb.equip_slot_of(ctx.db, on)
	if !ok {slot, ok = gamedb.equip_slot_of(ctx.db, worldstate.ref_base(ctx.ws, ctx.db, on))}
	return yes(ok && slot.kind == .Weapon && u64(slot.gear.skill) == c.param1)
}

@(private = "file")
fn_worn_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.worn_has_keyword(ctx.ws, ctx.db, on, p1(c)))
}

// GetRefTypeAliveCount(location, ref type): the location's refs of that type that are alive.
@(private = "file")
fn_get_ref_type_alive_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.ref_type_count(ctx.ws, ctx.db, p1(c), gamedb.condition_param2_form(c), false)), true
}

// GetIsGhost, IsEssential, IsProtected and IsUnique: the ACBS flags, as scripts set them.
@(private = "file")
fn_get_is_ghost :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.actor_flag(ctx.ws, ctx.db, on, esm.ACBS_GHOST))
}

@(private = "file")
fn_is_essential :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.actor_flag(ctx.ws, ctx.db, on, esm.ACBS_ESSENTIAL))
}

@(private = "file")
fn_is_protected :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.actor_flag(ctx.ws, ctx.db, on, esm.ACBS_PROTECTED))
}

@(private = "file")
fn_get_location_cleared :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(ctx.ws.cleared[p1(c)])
}

// IsGuard: a member of IsGuardFaction.
@(private = "file")
fn_is_guard :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.in_faction(ctx.ws, ctx.db, on, formid.IS_GUARD_FACTION))
}

@(private = "file")
fn_is_sneaking :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(actorstate.current(&ctx.ws.states, on) == actorstate.SNEAK)
}

// IsInList(list): the ref, its base or, for a leveled actor, the NPC_ it spawned as is in the list.
@(private = "file")
fn_is_in_list :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	list := p1(c)
	for f in ([]Form_ID{on, worldstate.ref_base(ctx.ws, ctx.db, on), worldstate.actor_pick(ctx.ws, ctx.db, on)}) {
		if f != 0 && worldstate.list_has(ctx.ws, ctx.db, list, f) {return yes(true)}
	}
	return yes(false)
}

// GetCurrentTime: the hour of the day.
@(private = "file")
fn_get_current_time :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	_, _, _, hour := worldstate.game_date(ctx.ws)
	return f32(hour), true
}

@(private = "file")
fn_is_moving :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on in ctx.ws.ai.moving)
}

@(private = "file")
fn_get_sitting :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(actorstate.sit_state(&ctx.ws.states, on)), true
}

@(private = "file")
fn_get_sleeping :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(actorstate.sleep_state(&ctx.ws.states, on)), true
}

@(private = "file")
fn_get_is_current_package :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	pack := ctx.ws.ai.packages[on]
	return yes(pack != 0 && pack == p1(c))
}

WORLD_INTERACTIONS :: 0x200 // PKDT interrupt flag (xEdit wbPKDTInterruptFlags)

// GetAllowWorldInteractions reads the running package's flag; an actor with none allows them.
@(private = "file")
fn_get_allow_world_interactions :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	p, ok := gamedb.package_of(ctx.db, ctx.ws.ai.packages[on])
	return yes(!ok || p.interrupt_flags & WORLD_INTERACTIONS != 0)
}

@(private = "file")
fn_get_destroyed :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.is_destroyed(ctx.ws, on))
}

@(private = "file")
fn_get_disabled :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(!worldstate.ref_enabled(ctx.ws, ctx.db, on))
}

@(private = "file")
fn_get_locked :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.is_locked(ctx.ws, ctx.db, on))
}

@(private = "file")
fn_get_open_state :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.open_state(ctx.ws, ctx.db, on)), true
}

// DoesNotExist: `on` is no ref, or a deleted one.
@(private = "file")
fn_does_not_exist :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	_, placed := gamedb.ref_by_formid(ctx.db, on)
	_, created := ctx.ws.created[on]
	return yes(!(placed || created) || worldstate.is_deleted(ctx.ws, on))
}

@(private = "file")
fn_get_gold :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.inv_count(ctx.ws, ctx.db, on, formid.GOLD)), true
}

@(private = "file")
fn_get_level :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return f32(worldstate.actor_level(ctx.ws, ctx.db, on)), true
}

@(private = "file")
fn_get_is_reference :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	ref, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(on != 0 && on == ref)
}

@(private = "file")
fn_has_magic_effect :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.has_effect(ctx.ws, on, p1(c)))
}

@(private = "file")
fn_has_spell :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.has_spell(ctx.ws, ctx.db, on, p1(c)))
}

// HasLoaded3D: an enabled ref in a cell attached to the player's scene.
@(private = "file")
fn_has_loaded_3d :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	cell := worldstate.ref_grid_cell(ctx.ws, ctx.db, on)
	return yes(cell != 0 && cell in ctx.ws.attached && worldstate.ref_enabled(ctx.ws, ctx.db, on))
}

// GetActorValuePercent(index): the current value over the maximum, 0 to 1.
@(private = "file")
fn_get_actor_value_percent :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if c.param1 >= esm.ACTOR_VALUE_COUNT {return 0, false}
	name := esm.AV_NAMES[c.param1]
	most := worldstate.av_max(ctx.ws, ctx.db, on, name)
	return worldstate.av_current(ctx.ws, ctx.db, on, name) / most if most > 0 else 1, true
}

// GetActorValue(index): the current value.
@(private = "file")
fn_get_actor_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if c.param1 >= esm.ACTOR_VALUE_COUNT {return 0, false}
	return worldstate.av_current(ctx.ws, ctx.db, on, esm.AV_NAMES[c.param1]), true
}

// GetBaseActorValue(index). On a PERK take-gate this is the skill requirement.
@(private = "file")
fn_get_base_actor_value :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	if c.param1 >= esm.ACTOR_VALUE_COUNT {return 0, false}
	return worldstate.av_base(ctx.ws, ctx.db, on, esm.AV_NAMES[c.param1]), true
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
// IsRaining, IsSnowing, IsPleasant: the current weather's class. GetIsCurrentWeather: it is param1.
fn_is_raining :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.weather_classification(ctx.db, ctx.ws.weather.current) == .Rainy)
}

fn_is_snowing :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.weather_classification(ctx.db, ctx.ws.weather.current) == .Snow)
}

fn_is_pleasant :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.weather_classification(ctx.db, ctx.ws.weather.current) == .Pleasant)
}

fn_get_is_current_weather :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(ctx.ws.weather.current != 0 && ctx.ws.weather.current == p1(c))
}

fn_is_in_interior :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	cell, ok := gamedb.cell_by_formid(ctx.db, worldstate.ref_cell(ctx.ws, ctx.db, on))
	return yes(ok && cell.interior)
}

// GetInCurrentLoc: the ref's location is the given one or inside it; run on a location, its
// parent is (CK wiki).
@(private = "file")
fn_get_in_current_loc :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(in_location(ctx, on, p1(c)))
}

@(private = "file")
in_location :: proc(ctx: ^Context, on, location: Form_ID) -> bool {
	here := worldstate.ref_location(ctx.ws, ctx.db, on)
	if l, ok := gamedb.location_of(ctx.db, on); ok {here = l.parent}
	return location != 0 && gamedb.location_within(ctx.db, here, location)
}

// GetInCurrentLocAlias(location alias): GetInCurrentLoc on what the alias holds.
@(private = "file")
fn_get_in_current_loc_alias :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(in_location(ctx, on, loc))
}

// LocAliasIsLocation(location alias, location).
@(private = "file")
fn_loc_alias_is_location :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(loc != 0 && loc == gamedb.condition_param2_form(c))
}

// GetIsEditorLocation(location): the ref was placed in that location or one inside it. Records check
// whole holds (HjaalmarchHoldLocation) on actors placed in their towns, so an exact match never fits.
@(private = "file")
fn_get_is_editor_location :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc := gamedb.editor_location(ctx.db, on)
	return yes(loc != 0 && gamedb.location_within(ctx.db, loc, p1(c)))
}

// GetIsEditorLocAlias(location alias): as GetIsEditorLocation, on what the alias holds.
@(private = "file")
fn_get_is_editor_loc_alias :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	area, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	loc := gamedb.editor_location(ctx.db, on)
	return yes(area != 0 && loc != 0 && gamedb.location_within(ctx.db, loc, area))
}

// HasSameEditorLocAsRef(ref, keyword) and HasSameEditorLocAsRefAlias(ref alias, keyword): both refs
// were placed in the same location, each taken up to its nearest parent with the keyword.
@(private = "file")
fn_has_same_editor_loc_as_ref :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(same_location(ctx, gamedb.editor_location(ctx.db, on), gamedb.editor_location(ctx.db, other), c))
}

@(private = "file")
fn_has_same_editor_loc_as_ref_alias :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(same_location(ctx, gamedb.editor_location(ctx.db, on), gamedb.editor_location(ctx.db, other), c))
}

// IsInSameCurrentLocAsRefAlias(ref alias, keyword): as HasSameEditorLocAsRefAlias, on current locations.
@(private = "file")
fn_is_in_same_current_loc_as_ref_alias :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(same_location(ctx, worldstate.ref_location(ctx.ws, ctx.db, on), worldstate.ref_location(ctx.ws, ctx.db, other), c))
}

// same_location: the two locations, each taken up to its nearest parent with the keyword (param2), are one.
@(private = "file")
same_location :: proc(ctx: ^Context, a, b: Form_ID, c: gamedb.Condition) -> bool {
	kw := gamedb.condition_param2_form(c)
	top := gamedb.location_with_keyword(ctx.db, a, kw)
	return top != 0 && top == gamedb.location_with_keyword(ctx.db, b, kw)
}

// location_of is where `on` is; a location is its own (CK wiki: LocationHasKeyword filling a
// location alias tests the locations themselves).
@(private = "file")
location_of :: proc(ctx: ^Context, on: Form_ID) -> Form_ID {
	if on in ctx.db.locations {return on}
	return worldstate.ref_location(ctx.ws, ctx.db, on)
}

@(private = "file")
fn_location_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.has_keyword(ctx.db, location_of(ctx, on), p1(c)))
}

// HasRefType(location ref type): the ref is one of that type.
@(private = "file")
fn_has_ref_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(gamedb.has_ref_type(ctx.db, on, p1(c)))
}

// LocationHasRefType(location ref type): the location holds a ref of that type.
@(private = "file")
fn_location_has_ref_type :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(len(gamedb.location_special_refs(ctx.db, location_of(ctx, on), p1(c))) > 0)
}

// GetLocAliasRefTypeAlive/DeadCount(location alias, ref type): its refs of that type, living or dead.
@(private = "file")
loc_alias_ref_type_count :: proc(ctx: ^Context, c: gamedb.Condition, dead: bool) -> (f32, bool) {
	loc, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return f32(worldstate.ref_type_count(ctx.ws, ctx.db, loc, gamedb.condition_param2_form(c), dead)), true
}

@(private = "file")
fn_get_loc_alias_ref_type_alive_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return loc_alias_ref_type_count(ctx, c, false)
}

@(private = "file")
fn_get_loc_alias_ref_type_dead_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return loc_alias_ref_type_count(ctx, c, true)
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

// GetNumericPackageData(index): the Bool, Int or Float in that data slot of the package the conditions belong to.
@(private = "file")
fn_get_numeric_package_data :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	in_, _ := gamedb.package_input(ctx.db, ctx.pack, u8(c.param1))
	#partial switch v in in_.value {
	case bool: return yes(v)
	case i32:  return f32(v), true
	case f32:  return v, true
	}
	return 0, false
}

// GetDetected(ref): `on` has detected the ref.
@(private = "file")
fn_get_detected :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(worldstate.detected(ctx.ws, on, other))
}

// GetLineOfSight(ref): `on` sees the ref, as Actor.HasLOS.
@(private = "file")
fn_get_line_of_sight :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	return yes(sighthost.has_los(ctx.ws, ctx.db, on, other))
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
