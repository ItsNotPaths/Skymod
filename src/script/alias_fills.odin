package script

// Alias fills at quest start (CK wiki, Quest Alias Tab). Aliases fill in declaration order, so a
// fill or a Match Condition can read an alias above it. A required alias left empty fails the start.
// Match Conditions run on the candidate, except for Unique_Actor and Create_Ref, which run them on
// the player.

import "core:log"
import "core:math/rand"
import "core:time"
import "../conditions"
import "../formats/esm"
import "../formid"
import "../gamedb"
import "../worldstate"

// fill_aliases fills a starting quest's aliases; false when a required alias stays empty.
// `new_game`: at a new game every alias of a Start Game Enabled quest may take a reserved ref.
fill_aliases :: proc(c: ^Call, quest: Form_ID, new_game := false) -> bool {
	used := make(map[Form_ID]bool, 8, context.temp_allocator)
	for a in gamedb.quest_aliases_of(c.db, quest) {
		h, ok := formid.alias_handle(quest, a.id)
		if !ok {continue}
		t := time.tick_now()
		form, known := fill(c, quest, h, a, used, new_game)
		if ms := time.duration_milliseconds(time.tick_since(t)); ms > SLOW_STORY_MS {
			log.warnf("alias: quest 0x%08X alias %d (%v fill) took %.1fms, got 0x%08X", quest, a.id, a.fill, ms, form)
		}
		if !known {continue}
		enter_alias(c, h, form)
		if form == 0 {
			if a.flags & esm.ALIAS_OPTIONAL == 0 {return false}
			continue
		}
		used[form] = true
		if into, iok := formid.alias_handle(quest, u32(a.force_into)); iok && a.force_into >= 0 {
			enter_alias(c, into, form)
		}
	}
	return true
}

// fill finds an alias's ref or location: 0 when nothing fits. known=false for an alias with no
// fill, which a script fills and which never fails the start.
@(private = "file")
fill :: proc(c: ^Call, quest, h: Form_ID, a: gamedb.Quest_Alias, used: map[Form_ID]bool, new_game: bool) -> (form: Form_ID, known: bool) {
	fits :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias, form: Form_ID, used: map[Form_ID]bool, new_game: bool, external := false) -> bool {
		return usable(c, quest, a, form, used if a.fill == .Matching else nil, new_game, external) && passes(c, quest, a, form)
	}
	switch a.fill {
	case .None:
		return 0, false
	case .Specific:
		return a.target if fits(c, quest, a, a.target, used, new_game) else 0, true
	case .External:
		other, ok := formid.alias_handle(a.target, u32(a.alias))
		form = c.ws.aliases[other] if ok && a.alias >= 0 else 0
		if c.ws.units[form].holder != 0 {return 0, true} // inside a container it fails (CK Quest Alias Tab)
		return form if fits(c, quest, a, form, used, new_game, true) else 0, true
	case .Unique_Actor:
		ref, _ := gamedb.unique_actor_ref(c.db, a.target)
		return ref if passes(c, quest, a, c.ws.player) && usable(c, quest, a, ref, nil, new_game) else 0, true
	case .Create_Ref:
		return create_ref(c, quest, a) if passes(c, quest, a, c.ws.player) else 0, true
	case .Location_Ref, .Matching:
		if a.location && a.fill == .Location_Ref {
			loc := ref_alias_location(c, quest, a)
			return loc if fits(c, quest, a, loc, used, new_game) else 0, true
		}
		found := make([dynamic]Form_ID, context.temp_allocator)
		for f in candidates(c, quest, a) {
			if fits(c, quest, a, f, used, new_game) {append(&found, f)}
		}
		if len(found) == 0 {return 0, true}
		if a.flags & (esm.ALIAS_IN_LOADED_AREA | esm.ALIAS_CLOSEST) == esm.ALIAS_IN_LOADED_AREA | esm.ALIAS_CLOSEST {
			return closest(c, found[:]), true
		}
		return pick_round(c, h, found[:]), true
	}
	return 0, false
}

// ref_alias_location is where a location alias's ref alias stands: its current location, or the
// nearest parent of it with the keyword (CK wiki, Quest Alias Tab).
@(private = "file")
ref_alias_location :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias) -> Form_ID {
	ref := worldstate.alias_ref(c.ws, quest, a.alias)
	if ref == 0 {return 0}
	return gamedb.location_with_keyword(c.db, worldstate.ref_location(c.ws, c.db, ref), a.target)
}

// candidates are what a searching fill tests: a Location_Ref fill's refs of its type in its
// location alias; for Matching the event member (From Event), then for a location alias every
// location, and for a ref alias the refs whose default link is another alias's ref (Near Alias),
// the loaded cells' refs, or else every persistent ref, unique actor and created ref.
@(private = "file")
candidates :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias) -> []Form_ID {
	if a.fill == .Location_Ref {
		return gamedb.location_special_refs(c.db, worldstate.alias_ref(c.ws, quest, a.alias), a.target)
	}
	out := make([dynamic]Form_ID, context.temp_allocator)
	switch {
	case a.event_member != 0:
		e, ok := &c.ws.quest_events[quest]
		if ref, rok := conditions.event_form(e if ok else nil, a.event_member); rok && ref != 0 {append(&out, ref)}
	case a.location:
		for loc in c.db.locations {append(&out, loc)}
	case a.alias >= 0:
		if kids, ok := c.db.linked_children[worldstate.alias_ref(c.ws, quest, a.alias)]; ok {append(&out, ..kids[:])}
	case a.flags & esm.ALIAS_IN_LOADED_AREA != 0:
		for cell in c.ws.attached {
			for r in gamedb.refs_of(c.db, cell) {append(&out, r.form_id)}
			for r in gamedb.actors_of(c.db, cell) {append(&out, r.form_id)}
			append(&out, ..worldstate.created_in(c.ws, cell))
		}
	case:
		if refs, ok := indexed(c, a); ok {return refs}
		// (hole alias-faction-candidates :tags quest :sev gap) with no HasRefType or GetIsID to narrow it, this search tests every persistent ref, unique actor and created ref: ~25 ms per fill, a hitch each time a quest like BQ01 tries to start. Wanted: the same narrowing for a must-pass GetInFaction (212 aliases) and HasKeyword (391), following runtime AddToFaction, AddKeyword and alias factions and keywords.
		append(&out, ..c.db.persistent_refs)
		for _, ref in c.db.unique_refs {
			if r, _ := gamedb.ref_by_formid(c.db, ref); !r.persistent {append(&out, ref)}
		}
		for ref in c.ws.created {append(&out, ref)}
	}
	return out[:]
}

// indexed is the part of the world search that can pass the alias's first must-pass HasRefType or
// GetIsID. The conditions still run on each ref, so the fill is the full search's, only cheaper.
@(private = "file")
indexed :: proc(c: ^Call, a: gamedb.Quest_Alias) -> ([]Form_ID, bool) {
	GET_IS_ID :: 72
	HAS_REF_TYPE :: 561
	for cond, i in a.conditions {
		if !must_pass(a.conditions, i) {continue}
		f := gamedb.condition_param1_form(cond)
		out := make([dynamic]Form_ID, context.temp_allocator)
		switch cond.function {
		case HAS_REF_TYPE:
			if refs, ok := c.db.search_by_type[f]; ok {append(&out, ..refs[:])}
		case GET_IS_ID:
			if refs, ok := c.db.search_by_base[f]; ok {append(&out, ..refs[:])}
			append(&out, ..c.db.search_leveled[:])
			for ref in c.ws.created {append(&out, ref)}
		case:
			continue
		}
		return out[:], true
	}
	return nil, false
}

// must_pass: condition i is ANDed with the whole list (no OR on it or on the one before), runs on
// the candidate as written, and holds only when its function answers true.
@(private = "file")
must_pass :: proc(conds: []gamedb.Condition, i: int) -> bool {
	c := conds[i]
	if .Or in c.flags || (i > 0 && .Or in conds[i - 1].flags) {return false}
	if c.run_on != .Subject || c.flags & {.Swap, .Use_Global} != {} {return false}
	#partial switch c.op {
	case .Equal, .GreaterOrEqual:
		return c.value == 1
	case .NotEqual, .Greater:
		return c.value == 0
	}
	return false
}

// usable applies the alias's flags: a dead actor, a disabled or deleted ref, a cleared location, a
// form another quest's Reserves alias holds, or one this quest already took (`used`; searches only:
// the wiki exempts fixed fills such as Unique_Actor), fits only when the flag allows it.
@(private = "file")
usable :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias, ref: Form_ID, used: map[Form_ID]bool, new_game: bool, external := false) -> bool {
	switch {
	case ref == 0, worldstate.is_deleted(c.ws, ref):
		return false
	case a.location && a.flags & esm.ALIAS_ALLOW_CLEARED == 0 && ref in c.ws.cleared:
		return false
	case a.flags & esm.ALIAS_ALLOW_DEAD == 0 && worldstate.is_dead(c.ws, c.db, ref):
		return false
	case a.flags & esm.ALIAS_ALLOW_DESTROYED == 0 && worldstate.is_destroyed(c.ws, ref):
		return false
	case a.fill != .Specific && a.flags & esm.ALIAS_ALLOW_DISABLED == 0 && !worldstate.ref_enabled(c.ws, c.db, ref):
		return false // a forced ref fills disabled: its quest enables it (C00GiantAttack's giant)
	case a.flags & esm.ALIAS_ALLOW_REUSE == 0 && used[ref]:
		return false
	case !external && !new_game && a.flags & esm.ALIAS_ALLOW_RESERVED == 0 && reserved(c, quest, ref):
		return false
	}
	return true
}

// reserved: another quest's Reserves alias holds the ref.
@(private = "file")
reserved :: proc(c: ^Call, quest, ref: Form_ID) -> bool {
	for h in worldstate.aliases_of(c.ws, ref) {
		q, id, _ := formid.alias_key(h)
		if a, aok := gamedb.quest_alias(c.db, q, id); aok && q != quest && a.flags & esm.ALIAS_RESERVES != 0 {return true}
	}
	return false
}

// passes runs the alias's Match Conditions on `subject`, as the quest sees them.
@(private = "file")
passes :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias, subject: Form_ID) -> bool {
	ctx := condition_context(c, subject, 0, quest)
	if e, ok := &c.ws.quest_events[quest]; ok {ctx.event = e}
	return conditions.all(&ctx, a.conditions)
}

// create_ref makes a ref of the alias's base at its alias's ref, or inside it. A leveled actor
// rolls at once at the zone's level times the alias's difficulty (ALCL), as PlaceActorAtMe does.
@(private = "file")
create_ref :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias) -> Form_ID {
	at := worldstate.alias_ref(c.ws, quest, a.alias)
	if at == 0 || a.target == 0 {return 0}
	if a.create_in {
		ref := worldstate.create_ref(c.ws, a.target, 0, {}, {}, 1)
		move_items(c, {base = a.target, ref = ref, to = at, count = 1})
		return ref
	}
	cell := worldstate.ref_cell(c.ws, c.db, at)
	pos := worldstate.ref_pos(c.ws, c.db, at)
	ref := worldstate.create_ref(c.ws, a.target, cell, {pos.x, pos.y, pos.z}, worldstate.ref_rot(c.ws, c.db, at), 1)
	if a.flags & esm.ALIAS_INITIALLY_DISABLED != 0 {worldstate.set_disabled(c.ws, ref, cell, true)}
	if worldstate.pick_list(c.ws, c.db, ref) != 0 {
		worldstate.roll_pick(c.ws, c.db, ref, f32(worldstate.encounter_level(c.ws, c.db, gamedb.zone_of(c.db, at), i32(a.create_level))))
	}
	worldstate.mark_scene_dirty(c.ws, ref)
	return ref
}

@(private = "file")
closest :: proc(c: ^Call, found: []Form_ID) -> Form_ID {
	best, best_d := found[0], worldstate.FAR_DISTANCE
	for ref in found {
		if d := worldstate.ref_distance(c.ws, c.db, c.ws.player, ref); d < best_d {best, best_d = ref, d}
	}
	return best
}

// pick_round picks at random among the matches this alias has not taken yet; when it has taken them
// all, a new round starts.
// (hole alias-fill-rounds :tags quest :sev polish) NOT VANILLA (user choice 2026-09-26): a searching alias fill picks in rounds, preferring what it has not filled before; vanilla picks uniformly at random. It may keep a quest from a target vanilla would pick again, or grow the saved rounds for aliases that search the whole world; watch radiant quests.
@(private = "file")
pick_round :: proc(c: ^Call, h: Form_ID, found: []Form_ID) -> Form_ID {
	fresh := make([dynamic]Form_ID, 0, len(found), context.temp_allocator)
	for ref in found {
		if !c.ws.alias_rounds[{h, ref}] {append(&fresh, ref)}
	}
	if len(fresh) == 0 {
		for ref in found {delete_key(&c.ws.alias_rounds, [2]Form_ID{h, ref})}
		append(&fresh, ..found)
	}
	pick := rand.choice(fresh[:])
	c.ws.alias_rounds[{h, pick}] = true
	return pick
}
