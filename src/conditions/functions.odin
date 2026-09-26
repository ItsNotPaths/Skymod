package conditions

// The condition function bodies. Names and parameter kinds come from xEdit's table
// (esm.CONDITION_FUNCTIONS); a function without a body here passes. `on` is the object the run-on
// selected. A body reads the same worldstate proc as the matching Papyrus native.

import "core:math/rand"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

// (hole condition-functions :tags (records quest) :sev gap) no body for GetLineOfSight (needs spatial queries), IsInFriendStateWithPlayer, GetQuestVariable, HasParentRelationship, IsMoving, IsAllowedToFly and 12 rarer ones: 114 of 68,007 quest and dialogue conditions (build/out/wsQ/measure14.py), and they pass.
// (hole starts-dead :tags (records world) :sev polish) a ref placed dead reads alive: no baseline "starts dead" flag is surfaced, so GetDead and IsDead see only deaths at runtime.

// Eval answers one condition. Returns the value to compare plus whether it could answer at all;
// answered=false is treated exactly like an unknown function, so the condition passes.
Eval :: #type proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool)

@(rodata)
TABLE := #partial [esm.CONDITION_FUNCTION_COUNT]Eval {
	1   = fn_get_distance,
	14  = fn_get_actor_value,
	18  = fn_get_current_time,
	32  = fn_get_in_same_cell,
	35  = fn_get_disabled,
	45  = fn_resting,
	46  = fn_get_dead,
	47  = fn_get_item_count,
	48  = fn_get_gold,
	49  = fn_resting,
	50  = fn_get_talked_to_pc,
	56  = fn_get_quest_running,
	58  = fn_get_stage,
	59  = fn_get_stage_done,
	61  = fn_resting,
	62  = fn_resting,
	66  = fn_resting,
	67  = fn_get_in_cell,
	69  = fn_get_is_race,
	70  = fn_get_is_sex,
	71  = fn_get_in_faction,
	72  = fn_get_is_id,
	73  = fn_get_faction_rank,
	74  = fn_get_global_value,
	75  = fn_resting,
	77  = fn_get_random_percent,
	80  = fn_get_level,
	84  = fn_get_dead_count,
	101 = fn_resting,
	125 = fn_is_guard,
	130 = fn_get_pc_is_race,
	131 = fn_get_pc_is_sex,
	132 = fn_get_pc_in_faction,
	136 = fn_get_is_reference,
	144 = fn_resting,
	145 = fn_resting,
	149 = fn_resting,
	159 = fn_resting,
	161 = fn_resting,
	181 = fn_has_same_editor_loc_as_ref_alias,
	182 = fn_get_equipped,
	214 = fn_has_magic_effect,
	223 = fn_is_spell_target,
	237 = fn_get_is_ghost,
	248 = fn_is_scene_playing,
	249 = fn_is_in_dialogue_with_player,
	250 = fn_get_location_cleared,
	255 = fn_get_offers_services_now,
	258 = fn_has_association_type,
	259 = fn_has_family_relationship,
	263 = fn_resting,
	264 = fn_has_spell,
	266 = fn_resting_true,
	274 = fn_resting,
	277 = fn_get_base_actor_value,
	286 = fn_is_sneaking,
	288 = fn_resting,
	289 = fn_resting,
	300 = fn_is_in_interior,
	310 = fn_get_in_worldspace,
	314 = fn_resting,
	353 = fn_is_actor,
	354 = fn_is_essential,
	359 = fn_get_in_current_loc,
	360 = fn_get_in_current_loc_alias,
	365 = fn_is_child,
	372 = fn_is_in_list,
	375 = fn_resting,
	376 = fn_resting,
	402 = fn_resting,
	403 = fn_get_relationship_rank,
	415 = fn_resting,
	426 = fn_get_is_voice_type,
	430 = fn_get_health_percentage,
	432 = fn_get_is_object_type,
	444 = fn_get_in_current_loc_form_list,
	448 = fn_has_perk,
	449 = fn_get_faction_relation,
	453 = fn_get_player_teammate,
	459 = fn_resting,
	476 = fn_is_protected,
	491 = fn_resting,
	497 = fn_resting,
	499 = fn_resting,
	503 = fn_resting_true,
	513 = fn_resting,
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
	600 = fn_get_loc_alias_ref_type_dead_count,
	601 = fn_get_loc_alias_ref_type_alive_count,
	605 = fn_loc_alias_is_location,
	606 = fn_get_keyword_data_for_location,
	610 = fn_loc_alias_has_keyword,
	624 = fn_get_in_container,
	629 = fn_get_vm_quest_variable,
	630 = fn_get_vm_script_variable,
	632 = fn_resting,
	633 = fn_resting,
	635 = fn_resting,
	640 = fn_get_actor_value_percent,
	641 = fn_is_unique,
	650 = fn_is_linked_to,
	651 = fn_get_keyword_data_for_current_location,
	652 = fn_resting,
	654 = fn_resting,
	655 = fn_resting,
	656 = fn_resting,
	657 = fn_resting,
	682 = fn_worn_has_keyword,
	699 = fn_has_magic_effect_keyword,
	700 = fn_resting,
	707 = fn_resting,
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

@(private = "file")
fn_get_talked_to_pc :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(worldstate.talked_to_pc(ctx.ws, on))
}

@(private = "file")
fn_is_in_dialogue_with_player :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on != 0 && ctx.ws.talking == on)
}

// Functions about a system that does not exist yet answer its resting state, which is the true
// answer in this engine until the system comes: nobody fights, trespasses, sneaks or runs a package.
// (hole crime-conditions :tags (combat quest) :sev gap :needs (crime-reads)) IsTrespassing, GetTrespassWarningLevel, GetCrimeGold (and Violent, Nonviolent), CanPayCrimeGold, GetInSharedCrimeFaction, IsActorAVictim, IsBribedbyPlayer, GetArrestingActor, GetArrestedState and GetDaysInJail read 0: there is no crime system.
// (hole combat-conditions :tags combat :sev gap :needs (combat-damage)) IsInCombat, GetShouldAttack, GetAlarmed, GetFriendHit, IsCombatTarget, GetCombatTargetHasKeyword, IsBleedingOut, IsWeaponOut, IsWeaponMagicOut and IsCasting read 0: nothing fights or draws a weapon.
// (hole package-conditions :tags ai :sev gap :needs (ai-agent)) GetIsCurrentPackage, GetSleeping, GetSitting, GetDetected, IsSmallBump and GetGroupMemberCount read 0 and GetAllowWorldInteractions 1: no actor runs a package, uses furniture, bumps or looks for anyone.
// (hole commanded-actors :tags magic :sev gap :needs (spell-casting)) IsCommandedActor reads 0: no spell raises or commands an actor.
// (hole flight :tags (ai combat) :sev gap :needs (ai-agent)) GetIsFlying and GetFlyingState read 0: no dragon flies.
// (hole weather-conditions :tags world :sev gap :needs (weather-select)) IsRaining, IsSnowing and GetIsCurrentWeather read 0 and IsPleasant 1: no weather is selected, so the sky reads clear.
// (hole map-markers :tags (ui quest) :sev gap) GetMapMarkerVisible reads 0: there is no map, so no marker is ever found.
// (hole persuasion :tags dialogue :sev gap) GetIntimidateSuccess and GetBribeSuccess read 0: no speech check marks an actor persuaded.
// (hole favor-commands :tags (dialogue ai) :sev gap :needs (teammate-behavior)) IsInFavorState reads 0: no follower takes commands.
@(private = "file")
fn_resting :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return 0, true
}

@(private = "file")
fn_resting_true :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return 1, true
}

@(private = "file")
fn_get_player_teammate :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on in ctx.ws.teammates)
}

@(private = "file")
fn_is_unique :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(actor_flags(ctx, on) & esm.ACBS_UNIQUE != 0)
}

// IsChild: the actor's race has the Child flag (RACE DATA 0x4).
@(private = "file")
fn_is_child :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	race, _ := gamedb.race_of(ctx.db, worldstate.actor_traits(ctx.ws, ctx.db, on).race)
	return yes(race.info.flags & 0x4 != 0)
}

@(private = "file")
fn_is_actor :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(on == formid.PLAYER || worldstate.ref_base(ctx.ws, ctx.db, on) in ctx.db.actors)
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
	return yes(worldstate.in_faction(ctx.ws, ctx.db, formid.PLAYER, p1(c)))
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

// GetOffersServicesNow: the actor is in a vendor faction that trades now, inside its hours and
// its vendor conditions.
@(private = "file")
fn_get_offers_services_now :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	_, _, _, hour := worldstate.game_date(ctx.ws)
	for id in worldstate.actor_factions_now(ctx.ws, ctx.db, on) {
		f, _ := gamedb.faction_of(ctx.db, id)
		v := f.vendor
		if f.flags & esm.FACT_VENDOR == 0 {continue}
		open := f64(v.start) <= hour && hour < f64(v.end) if v.start <= v.end else hour >= f64(v.start) || hour < f64(v.end)
		sub := Context{db = ctx.db, ws = ctx.ws, subject = on, target = formid.PLAYER, quest_vars = ctx.quest_vars}
		if open && all(&sub, v.conditions) {return 1, true}
	}
	return 0, true
}

// GetDeadCount(actor base): how many of its placed actors are dead.
@(private = "file")
fn_get_dead_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	n := 0
	for ref, d in ctx.ws.ref_deltas {
		if .Dead in d.live && d.dead && worldstate.ref_base(ctx.ws, ctx.db, ref) == p1(c) {n += 1}
	}
	return f32(n), true
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
	case 13: return yes(on == formid.PLAYER || base in ctx.db.actors)
	}
	return 0, false
}

// GetInContainer(container): the item ref is carried in that container.
@(private = "file")
fn_get_in_container :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	container, ok := param_ref(ctx, c, 0)
	if !ok {return 0, false}
	holder, carried := ctx.ws.carried[on]
	return yes(carried && holder == container)
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
	theirs := worldstate.actor_factions_now(ctx.ws, ctx.db, other)
	for mine in worldstate.actor_factions_now(ctx.ws, ctx.db, on) {
		f, _ := gamedb.faction_of(ctx.db, mine)
		for r in f.relations {
			for t in theirs {
				if r.faction == t {return f32(r.combat), true}
			}
		}
	}
	return 0, true
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
	for h in worldstate.effects_on(ctx.ws, on) {
		if e := ctx.ws.effects[h]; !e.finished && gamedb.has_keyword(ctx.db, e.effect, p1(c)) {return 1, true}
	}
	return 0, true
}

@(private = "file")
fn_get_in_current_loc_form_list :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc := worldstate.ref_location(ctx.ws, ctx.db, on)
	return yes(loc != 0 && worldstate.list_has(ctx.ws, ctx.db, p1(c), loc))
}

@(private = "file")
fn_worn_has_keyword :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	for w in worldstate.equipment(ctx.ws, ctx.db, on).worn {
		if gamedb.has_keyword(ctx.db, w.item, p1(c)) {return 1, true}
	}
	return 0, true
}

// GetRefTypeAliveCount(location, ref type): the location's refs of that type that are alive.
@(private = "file")
fn_get_ref_type_alive_count :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	n := 0
	for ref in gamedb.location_special_refs(ctx.db, p1(c), gamedb.condition_param2_form(c)) {
		if !worldstate.is_dead(ctx.ws, ref) {n += 1}
	}
	return f32(n), true
}

// GetIsGhost, IsEssential, IsProtected and IsUnique: the NPC_'s ACBS flags.
@(private = "file")
fn_get_is_ghost :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(actor_flags(ctx, on) & esm.ACBS_GHOST != 0)
}

@(private = "file")
fn_is_essential :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(actor_flags(ctx, on) & esm.ACBS_ESSENTIAL != 0)
}

@(private = "file")
fn_is_protected :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(actor_flags(ctx, on) & esm.ACBS_PROTECTED != 0)
}

@(private = "file")
actor_flags :: proc(ctx: ^Context, on: Form_ID) -> u32 {
	base := worldstate.ref_base(ctx.ws, ctx.db, on)
	return gamedb.template_part(ctx.db, base, esm.ACBS_TEMPLATE_BASE_DATA, worldstate.actor_pick(ctx.ws, ctx.db, on)).flags
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
	return yes(worldstate.is_sneaking(ctx.ws, on))
}

// IsInList(list): the ref, or its base, is a member of the form list.
@(private = "file")
fn_is_in_list :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	base := worldstate.actor_pick(ctx.ws, ctx.db, on)
	if base == 0 {base = worldstate.ref_base(ctx.ws, ctx.db, on)}
	list := p1(c)
	return yes(worldstate.list_has(ctx.ws, ctx.db, list, on) || (base != 0 && worldstate.list_has(ctx.ws, ctx.db, list, base)))
}

// GetCurrentTime: the hour of the day.
@(private = "file")
fn_get_current_time :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	_, _, _, hour := worldstate.game_date(ctx.ws)
	return f32(hour), true
}

@(private = "file")
fn_get_disabled :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	return yes(!worldstate.ref_enabled(ctx.ws, ctx.db, on))
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
	for h in worldstate.effects_on(ctx.ws, on) {
		if e := ctx.ws.effects[h]; e.effect == p1(c) && !e.finished {return 1, true}
	}
	return 0, true
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
	name := gamedb.AV_NAMES[c.param1]
	most := worldstate.av_max(ctx.ws, ctx.db, on, name)
	return worldstate.av_current(ctx.ws, ctx.db, on, name) / most if most > 0 else 1, true
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

// GetIsEditorLocation(location): the ref was placed in that location.
@(private = "file")
fn_get_is_editor_location :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc := gamedb.editor_location(ctx.db, on)
	return yes(loc != 0 && loc == p1(c))
}

// GetIsEditorLocAlias(location alias): the ref was placed in what the alias holds.
@(private = "file")
fn_get_is_editor_loc_alias :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	loc, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	return yes(loc != 0 && loc == gamedb.editor_location(ctx.db, on))
}

// HasSameEditorLocAsRefAlias(ref alias, keyword): both refs were placed in the same location, each
// taken up to its nearest parent with the keyword.
@(private = "file")
fn_has_same_editor_loc_as_ref_alias :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (f32, bool) {
	other, ok := alias_ref(ctx, i32(c.param1))
	if !ok {return 0, false}
	kw := gamedb.condition_param2_form(c)
	a := gamedb.location_with_keyword(ctx.db, gamedb.editor_location(ctx.db, on), kw)
	return yes(a != 0 && a == gamedb.location_with_keyword(ctx.db, gamedb.editor_location(ctx.db, other), kw))
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
	n := 0
	for ref in gamedb.location_special_refs(ctx.db, loc, gamedb.condition_param2_form(c)) {
		if worldstate.is_dead(ctx.ws, ref) == dead {n += 1}
	}
	return f32(n), true
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
