package script

// Alias fills at quest start (CK wiki, Quest Alias Tab). Aliases fill in declaration order, so a
// fill or a Match Condition can read an alias above it. A required alias left empty fails the start.
// Match Conditions run on the candidate, except for Unique_Actor and Create_Ref, which run them on
// the player.

import "core:math/rand"
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
		form: Form_ID
		known: bool
		if a.location {
			form, known = fill_location(c, quest, a)
		} else {
			form, known = fill_ref(c, quest, h, a, used, new_game)
		}
		if !known {continue}
		worldstate.fill_alias(c.ws, h, form)
		if form == 0 {
			if a.flags & esm.ALIAS_OPTIONAL == 0 {return false}
			continue
		}
		used[form] = true
		if into, iok := formid.alias_handle(quest, u32(a.force_into)); iok && a.force_into >= 0 {
			worldstate.fill_alias(c.ws, into, form)
		}
	}
	return true
}

// fill_ref finds a reference alias's ref: 0 when nothing fits. known=false for a fill this engine
// does not resolve yet, which leaves the alias alone and never fails the start.
@(private = "file")
fill_ref :: proc(c: ^Call, quest, h: Form_ID, a: gamedb.Quest_Alias, used: map[Form_ID]bool, new_game: bool) -> (form: Form_ID, known: bool) {
	fits :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias, ref: Form_ID, used: map[Form_ID]bool, new_game: bool, external := false) -> bool {
		return usable(c, quest, a, ref, used if a.fill == .Matching else nil, new_game, external) && passes(c, quest, a, ref)
	}
	switch a.fill {
	case .None, .Location_Ref:
		return 0, false
	case .Specific:
		return a.target if fits(c, quest, a, a.target, used, new_game) else 0, true
	case .External:
		other, ok := formid.alias_handle(a.target, u32(a.alias))
		ref := c.ws.aliases[other] if ok && a.alias >= 0 else 0
		return ref if fits(c, quest, a, ref, used, new_game, true) else 0, true
	case .Unique_Actor:
		ref, _ := gamedb.unique_actor_ref(c.db, a.target)
		return ref if passes(c, quest, a, formid.PLAYER) && usable(c, quest, a, ref, nil, new_game) else 0, true
	case .Create_Ref:
		return create_ref(c, quest, a) if passes(c, quest, a, formid.PLAYER) else 0, true
	case .Matching:
		found := make([dynamic]Form_ID, context.temp_allocator)
		for ref in candidates(c, quest, a) {
			if fits(c, quest, a, ref, used, new_game) {append(&found, ref)}
		}
		if len(found) == 0 {return 0, true}
		if a.flags & (esm.ALIAS_IN_LOADED_AREA | esm.ALIAS_CLOSEST) == esm.ALIAS_IN_LOADED_AREA | esm.ALIAS_CLOSEST {
			return closest(c, found[:]), true
		}
		return pick_round(c, h, found[:]), true
	}
	return 0, false
}

// fill_location finds a location alias's location; known=false for the fills location-alias-fills
// has not built.
@(private = "file")
fill_location :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias) -> (form: Form_ID, known: bool) {
	#partial switch a.fill {
	case .Specific:
		return a.target if passes(c, quest, a, a.target) else 0, true
	case .External:
		other, ok := formid.alias_handle(a.target, u32(a.alias))
		loc := c.ws.aliases[other] if ok && a.alias >= 0 else 0
		return loc if loc != 0 && passes(c, quest, a, loc) else 0, true
	}
	return 0, false
}

// candidates are the refs a Matching fill tests: the event member (From Event), the refs whose
// default link is another alias's ref (Near Alias), the loaded cells' refs, or else every
// persistent ref, unique actor and created ref.
@(private = "file")
candidates :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	switch {
	case a.event_member != 0:
		e, ok := &c.ws.quest_events[quest]
		if ref, rok := conditions.event_form(e if ok else nil, a.event_member); rok && ref != 0 {append(&out, ref)}
	case a.alias >= 0:
		if kids, ok := c.db.linked_children[worldstate.alias_ref(c.ws, quest, a.alias)]; ok {append(&out, ..kids[:])}
	case a.flags & esm.ALIAS_IN_LOADED_AREA != 0:
		for cell in c.ws.attached {
			for r in gamedb.refs_of(c.db, cell) {append(&out, r.form_id)}
			for r in gamedb.actors_of(c.db, cell) {append(&out, r.form_id)}
			append(&out, ..worldstate.created_in(c.ws, cell))
		}
	case:
		append(&out, ..c.db.persistent_refs)
		for _, ref in c.db.unique_refs {
			if r, _ := gamedb.ref_by_formid(c.db, ref); !r.persistent {append(&out, ref)}
		}
		for ref in c.ws.created {append(&out, ref)}
	}
	return out[:]
}

// usable applies the alias's flags: a dead actor, a disabled or deleted ref, a ref another quest's
// Reserves alias holds, or one this quest already took (`used`; searches only: the wiki exempts
// fixed fills such as Unique_Actor), fits only when the flag allows it.
@(private = "file")
usable :: proc(c: ^Call, quest: Form_ID, a: gamedb.Quest_Alias, ref: Form_ID, used: map[Form_ID]bool, new_game: bool, external := false) -> bool {
	switch {
	case ref == 0, worldstate.is_deleted(c.ws, ref):
		return false
	case a.flags & esm.ALIAS_ALLOW_DEAD == 0 && worldstate.is_dead(c.ws, ref):
		return false
	case a.flags & esm.ALIAS_ALLOW_DISABLED == 0 && !ref_enabled(c.ws, c.db, ref):
		return false
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
	holders, ok := c.ws.alias_holders[ref]
	if !ok {return false}
	for h in holders {
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

// create_ref makes a ref of the alias's base at its alias's ref, or inside it.
// (hole alias-create-level :tags (quest records) :sev polish) Create_Ref ignores ALCL (easy..very hard): a leveled base rolls at the zone's level, not the alias's.
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
	worldstate.mark_scene_dirty(c.ws, ref)
	return ref
}

@(private = "file")
closest :: proc(c: ^Call, found: []Form_ID) -> Form_ID {
	best, best_d := found[0], worldstate.FAR_DISTANCE
	for ref in found {
		if d := worldstate.ref_distance(c.ws, c.db, formid.PLAYER, ref); d < best_d {best, best_d = ref, d}
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
