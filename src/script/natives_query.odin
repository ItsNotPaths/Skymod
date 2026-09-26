package script

// Queries over data we already have (ws.md, Workstream L): records, and the stores their setters
// write. A condition function that asks the same thing reads the same worldstate proc.

import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

// (hole warmth-rating :tags (records player) :sev polish) GetWarmthRating (Actor, Armor, Light; Survival mode) reads 0: no source gives how Survival rates warmth.

register_query :: proc(reg: ^Registry) {
	register(reg, "FormList", "Find", n_list_find)
	register(reg, "Utility", "GetCurrentRealTime", n_get_current_real_time)
	register(reg, "Game", "GetRealHoursPassed", n_get_real_hours_passed)
	register(reg, "ObjectReference", "CalculateEncounterLevel", n_calculate_encounter_level)
	register(reg, "Form", "GetGoldValue", n_get_gold_value)
	register(reg, "ObjectReference", "PlaceActorAtMe", n_place_actor_at_me)

	register(reg, "Actor", "HasMagicEffect", n_has_magic_effect)
	register(reg, "Actor", "HasMagicEffectWithKeyword", n_has_effect_keyword)
	register(reg, "ObjectReference", "HasEffectKeyword", n_has_effect_keyword)
	register(reg, "Actor", "WornHasKeyword", n_worn_has_keyword)
	register(reg, "Actor", "IsOverEncumbered", n_is_over_encumbered)
	register(reg, "Actor", "IsGuard", n_is_guard)
	register(reg, "Actor", "GetKiller", n_get_killer)
	register(reg, "Actor", "HasFamilyRelationship", n_has_family_relationship)
	register(reg, "Actor", "HasParentRelationship", n_has_parent_relationship)
	register(reg, "Actor", "GetHighestRelationshipRank", n_get_highest_rel_rank)
	register(reg, "Actor", "GetLowestRelationshipRank", n_get_lowest_rel_rank)

	register(reg, "Actor", "SetGhost", n_set_ghost)
	register(reg, "Actor", "IsGhost", n_is_ghost)
	register(reg, "Actor", "IsEssential", n_is_essential)
	register(reg, "ActorBase", "IsEssential", n_is_essential)
	register(reg, "ActorBase", "SetEssential", n_set_essential)
	register(reg, "ActorBase", "IsProtected", n_is_protected)
	register(reg, "ActorBase", "SetProtected", n_set_protected)
	register(reg, "ActorBase", "IsInvulnerable", n_is_invulnerable)
	register(reg, "ActorBase", "SetInvulnerable", n_set_invulnerable)
	register(reg, "ActorBase", "IsUnique", n_is_unique)
	register(reg, "ActorBase", "GetSex", n_get_sex)
	register(reg, "ActorBase", "GetClass", n_get_class)
	register(reg, "ActorBase", "GetDeadCount", n_get_dead_count)
	register(reg, "ActorBase", "GetGiftFilter", n_get_gift_filter)

	register(reg, "ObjectReference", "GetEditorLocation", n_get_editor_location)
	register(reg, "ObjectReference", "GetHeadingAngle", n_get_heading_angle)
	register(reg, "ObjectReference", "GetWidth", n_get_width)
	register(reg, "ObjectReference", "GetLength", n_get_length)
	register(reg, "ObjectReference", "GetHeight", n_get_height)
	register(reg, "ObjectReference", "HasRefType", n_ref_has_ref_type)
	register(reg, "ObjectReference", "IsDeleted", n_is_deleted)
	register(reg, "ObjectReference", "GetKey", n_get_key)
	register(reg, "ObjectReference", "GetLockLevel", n_get_lock_level)
	register(reg, "ObjectReference", "SetLockLevel", n_set_lock_level)
	register(reg, "ObjectReference", "IsLockBroken", n_is_lock_broken)
	register(reg, "ObjectReference", "GetVoiceType", n_get_voice_type)
	register(reg, "ObjectReference", "IsActivateChild", n_is_activate_child)
	register(reg, "ObjectReference", "GetAllItemsCount", n_get_all_items_count)
	register(reg, "ObjectReference", "IsContainerEmpty", n_is_container_empty)
	for class in ([]string{"ObjectReference", "Cell"}) {
		register(reg, class, "GetActorOwner", n_get_actor_owner)
		register(reg, class, "GetFactionOwner", n_get_faction_owner)
		register(reg, class, "SetActorOwner", n_set_owner)
		register(reg, class, "SetFactionOwner", n_set_owner)
	}
	register(reg, "Cell", "IsInterior", n_cell_is_interior)

	register(reg, "Location", "GetRefTypeAliveCount", n_get_ref_type_alive_count)
	register(reg, "Location", "GetRefTypeDeadCount", n_get_ref_type_dead_count)
	register(reg, "Location", "HasRefType", n_location_has_ref_type)
	register(reg, "Location", "HasCommonParent", n_has_common_parent)

	for class in ([]string{"Spell", "Enchantment", "Potion", "Ingredient"}) {
		register(reg, class, "IsHostile", n_is_hostile)
	}
	register(reg, "MagicEffect", "GetAssociatedSkill", n_get_associated_skill)
	register(reg, "Package", "GetTemplate", n_get_template)
	register(reg, "Form", "GetFormID", n_get_form_id)
	register(reg, "Form", "PlayerKnows", n_player_knows)
	register(reg, "Game", "GetForm", n_get_form)
	register(reg, "Game", "GetGameSettingFloat", n_get_setting_float)
	register(reg, "Game", "GetGameSettingInt", n_get_setting_int)
	register(reg, "Game", "GetGameSettingString", n_get_setting_string)
}

// ── wrong zeros ──────────────────────────────────────────────────────────────────

// FormList.Find: the index of the form, authored members first; -1 when absent.
n_list_find :: proc(c: ^Call, args: []Value) -> Value {
	form := arg_form(args, 0)
	authored, _ := gamedb.form_list_of(c.db, c.self)
	for f, i in authored {
		if f == form {return i32(i)}
	}
	for f, i in worldstate.list_added(c.ws, c.self) {
		if f == form {return i32(len(authored) + i)}
	}
	return i32(-1)
}

// GetCurrentRealTime counts the seconds this game has played, across saves, so a time a script
// stored before a save still subtracts right after a load.
n_get_current_real_time :: proc(c: ^Call, args: []Value) -> Value {
	return f32(c.ws.clock.played)
}

n_get_real_hours_passed :: proc(c: ^Call, args: []Value) -> Value {
	return f32(c.ws.clock.played / 3600)
}

// CalculateEncounterLevel(aiDifficulty = 4): the ref's zone level at that difficulty (4 is none).
n_calculate_encounter_level :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.encounter_level(c.ws, c.db, gamedb.zone_of(c.db, c.self), arg_i32(args, 0, 4))
}

n_get_gold_value :: proc(c: ^Call, args: []Value) -> Value {
	v, _ := gamedb.value_of(c.db, c.self)
	return v
}

// PlaceActorAtMe(akActorToPlace, aiLevelMod = 4, akZone = None) is PlaceAtMe for an actor. A leveled
// actor rolls at once, at the zone's level (akZone, else the caller's) times aiLevelMod.
n_place_actor_at_me :: proc(c: ^Call, args: []Value) -> Value {
	actor := place_at_me(c, arg_form(args, 0))
	if actor == 0 || worldstate.pick_list(c.ws, c.db, actor) == 0 {return form_or_none(actor)}
	zone := arg_form(args, 2)
	if zone == 0 {zone = gamedb.zone_of(c.db, c.self)}
	worldstate.roll_pick(c.ws, c.db, actor, f32(worldstate.encounter_level(c.ws, c.db, zone, arg_i32(args, 1, 4))))
	return actor
}

// ── actors ───────────────────────────────────────────────────────────────────────

n_has_magic_effect :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.has_effect(c.ws, c.self, arg_form(args, 0))
}

n_has_effect_keyword :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.has_effect_keyword(c.ws, c.db, c.self, arg_form(args, 0))
}

n_worn_has_keyword :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.worn_has_keyword(c.ws, c.db, c.self, arg_form(args, 0))
}

n_is_over_encumbered :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.over_encumbered(c.ws, c.db, c.self)
}

n_is_guard :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.in_faction(c.ws, c.db, c.self, formid.IS_GUARD_FACTION)
}

n_get_killer :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(c.ws.killers[c.self])
}

n_has_parent_relationship :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.rel_is_parent(c.ws, c.db, c.self, arg_form(args, 0))
}

n_has_family_relationship :: proc(c: ^Call, args: []Value) -> Value {
	return gamedb.association_is_family(c.db, worldstate.rel_association(c.ws, c.db, c.self, arg_form(args, 0)))
}

n_get_highest_rel_rank :: proc(c: ^Call, args: []Value) -> Value {
	_, highest := worldstate.rel_rank_range(c.ws, c.db, c.self)
	return highest
}

n_get_lowest_rel_rank :: proc(c: ^Call, args: []Value) -> Value {
	lowest, _ := worldstate.rel_rank_range(c.ws, c.db, c.self)
	return lowest
}

// The ACBS flags: SetGhost writes the actor, the ActorBase setters its NPC_ (worldstate.actor_flag).

n_set_ghost :: proc(c: ^Call, args: []Value) -> Value {return set_flag(c, args, esm.ACBS_GHOST)}
n_set_essential :: proc(c: ^Call, args: []Value) -> Value {return set_flag(c, args, esm.ACBS_ESSENTIAL)}
n_set_protected :: proc(c: ^Call, args: []Value) -> Value {return set_flag(c, args, esm.ACBS_PROTECTED)}
n_set_invulnerable :: proc(c: ^Call, args: []Value) -> Value {return set_flag(c, args, esm.ACBS_INVULNERABLE)}

// An Essential alias does not count yet (alias-data).
n_is_ghost :: proc(c: ^Call, args: []Value) -> Value {return worldstate.actor_flag(c.ws, c.db, c.self, esm.ACBS_GHOST)}
n_is_essential :: proc(c: ^Call, args: []Value) -> Value {return worldstate.actor_flag(c.ws, c.db, c.self, esm.ACBS_ESSENTIAL)}
n_is_protected :: proc(c: ^Call, args: []Value) -> Value {return worldstate.actor_flag(c.ws, c.db, c.self, esm.ACBS_PROTECTED)}
n_is_invulnerable :: proc(c: ^Call, args: []Value) -> Value {return worldstate.actor_flag(c.ws, c.db, c.self, esm.ACBS_INVULNERABLE)}
n_is_unique :: proc(c: ^Call, args: []Value) -> Value {return worldstate.actor_flag(c.ws, c.db, c.self, esm.ACBS_UNIQUE)}

set_flag :: proc(c: ^Call, args: []Value, bit: u32) -> Value {
	worldstate.set_actor_flag(c.ws, c.self, bit, arg_bool(args, 0, true))
	return nil
}

// GetSex: 0 male, 1 female.
n_get_sex :: proc(c: ^Call, args: []Value) -> Value {
	return i32(1) if gamedb.actor_traits(c.db, c.self).flags & esm.ACBS_FEMALE != 0 else i32(0)
}

n_get_class :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(gamedb.template_part(c.db, c.self, esm.ACBS_TEMPLATE_STATS).class)
}

n_get_dead_count :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.dead_count(c.ws, c.db, c.self)
}

n_get_gift_filter :: proc(c: ^Call, args: []Value) -> Value {
	base, _ := gamedb.actor_base(c.db, c.self)
	return form_or_none(base.gift_filter)
}

// ── refs and cells ───────────────────────────────────────────────────────────────

n_get_editor_location :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(gamedb.editor_location(c.db, c.self))
}

n_get_heading_angle :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.heading_angle(c.ws, c.db, c.self, arg_form(args, 0))
}

n_get_width :: proc(c: ^Call, args: []Value) -> Value {return ref_size(c, c.self).x}
n_get_length :: proc(c: ^Call, args: []Value) -> Value {return ref_size(c, c.self).y}
n_get_height :: proc(c: ^Call, args: []Value) -> Value {return ref_size(c, c.self).z}

// ref_size is a ref's bounds box extent at its current scale: an actor's from its race, else its
// base's OBND.
ref_size :: proc(c: ^Call, ref: Form_ID) -> [3]f32 {
	base := worldstate.ref_base(c.ws, c.db, ref)
	if gamedb.is_actor(c.db, base) {
		box := worldstate.actor_box(c.ws, c.db, ref)
		return box[1] - box[0]
	}
	box, _ := gamedb.base_bounds(c.db, base)
	return (box[1] - box[0]) * worldstate.ref_scale(c.ws, c.db, ref)
}

n_ref_has_ref_type :: proc(c: ^Call, args: []Value) -> Value {
	return gamedb.has_ref_type(c.db, c.self, arg_form(args, 0))
}

// IsDeleted: a script's Delete, or a plugin that deleted the placement.
n_is_deleted :: proc(c: ^Call, args: []Value) -> Value {
	r, _ := gamedb.ref_by_formid(c.db, c.self)
	return r.deleted || worldstate.is_deleted(c.ws, c.self)
}

n_get_key :: proc(c: ^Call, args: []Value) -> Value {
	lock, _ := gamedb.lock_of(c.db, c.self)
	return form_or_none(lock.key)
}

n_get_lock_level :: proc(c: ^Call, args: []Value) -> Value {
	return i32(worldstate.lock_level(c.ws, c.db, c.self))
}

n_set_lock_level :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_lock_level(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), u8(clamp(arg_i32(args, 0, 0), 0, 255)))
	return nil
}

// (hole lockpicking :tags (ui player) :sev gap) IsLockBroken reads false: no pick or bash breaks a lock.
n_is_lock_broken :: proc(c: ^Call, args: []Value) -> Value {
	return false
}

n_get_voice_type :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(worldstate.actor_traits(c.ws, c.db, c.self).voice)
}

n_is_activate_child :: proc(c: ^Call, args: []Value) -> Value {
	return gamedb.is_activate_child(c.db, c.self, arg_form(args, 0))
}

n_get_all_items_count :: proc(c: ^Call, args: []Value) -> Value {
	n: i32
	for item in worldstate.inv_items(c.ws, c.db, c.self) {n += worldstate.inv_count(c.ws, c.db, c.self, item)}
	return n
}

n_is_container_empty :: proc(c: ^Call, args: []Value) -> Value {
	return len(worldstate.inv_items(c.ws, c.db, c.self)) == 0
}

n_get_actor_owner :: proc(c: ^Call, args: []Value) -> Value {
	o := worldstate.owner(c.ws, c.db, c.self)
	return o if gamedb.is_actor(c.db, o) else nil
}

n_get_faction_owner :: proc(c: ^Call, args: []Value) -> Value {
	o := worldstate.owner(c.ws, c.db, c.self)
	_, faction := gamedb.faction_of(c.db, o)
	return o if faction else nil
}

// SetActorOwner(akActorBase) and SetFactionOwner(akFaction): None clears the owner.
n_set_owner :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_owner(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_cell_is_interior :: proc(c: ^Call, args: []Value) -> Value {
	cell, _ := gamedb.cell_by_formid(c.db, c.self)
	return cell.interior
}

// ── locations ────────────────────────────────────────────────────────────────────

n_get_ref_type_alive_count :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.ref_type_count(c.ws, c.db, c.self, arg_form(args, 0), false)
}

n_get_ref_type_dead_count :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.ref_type_count(c.ws, c.db, c.self, arg_form(args, 0), true)
}

n_location_has_ref_type :: proc(c: ^Call, args: []Value) -> Value {
	return len(gamedb.location_special_refs(c.db, c.self, arg_form(args, 0))) > 0
}

// HasCommonParent(akOther, akFilter = None): a location above this one, with the keyword when one is
// given, also holds the other.
n_has_common_parent :: proc(c: ^Call, args: []Value) -> Value {
	other, filter := arg_form(args, 0), arg_form(args, 1)
	l, ok := gamedb.location_of(c.db, c.self)
	for depth := 0; ok && l.parent != 0 && depth < gamedb.LOCATION_TREE_MAX_DEPTH; depth += 1 {
		if (filter == 0 || gamedb.has_keyword(c.db, l.parent, filter)) && gamedb.location_within(c.db, other, l.parent) {return true}
		l, ok = gamedb.location_of(c.db, l.parent)
	}
	return false
}

// ── forms ────────────────────────────────────────────────────────────────────────

n_is_hostile :: proc(c: ^Call, args: []Value) -> Value {
	return gamedb.is_hostile(c.db, c.self)
}

// GetAssociatedSkill: the skill an effect trains, "" for none.
n_get_associated_skill :: proc(c: ^Call, args: []Value) -> Value {
	m, _ := gamedb.magic_effect_of(c.db, c.self)
	skill := m.info.magic_skill
	return gamedb.AV_NAMES[skill] if skill >= 0 && skill < esm.ACTOR_VALUE_COUNT else ""
}

n_get_template :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(gamedb.package_template_of(c.db, c.self))
}

n_get_form_id :: proc(c: ^Call, args: []Value) -> Value {
	return i32(gamedb.load_id(c.db, c.self))
}

n_get_form :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(gamedb.form_by_load_id(c.db, u32(arg_i32(args, 0, 0))))
}

// (hole crafting-screen :tags ui :sev gap) PlayerKnows is true only for a word of power the player learned: no crafting screen teaches an ingredient effect or an enchantment.
n_player_knows :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.word_taught(c.ws, formid.PLAYER, c.self)
}

n_get_setting_float :: proc(c: ^Call, args: []Value) -> Value {return gamedb.setting_float(c.db, arg_str(args, 0))}
n_get_setting_int :: proc(c: ^Call, args: []Value) -> Value {return gamedb.setting_int(c.db, arg_str(args, 0))}
n_get_setting_string :: proc(c: ^Call, args: []Value) -> Value {return gamedb.setting_string(c.db, arg_str(args, 0))}
