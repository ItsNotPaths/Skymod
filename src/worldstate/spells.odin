package worldstate

// An actor's spell list: its spells, abilities, powers and shouts. It is its records' list
// (gamedb.spell_sources) with a delta per spell, like inventory. GIVEN (AddSpell) stays when a mod
// update drops the spell from the records; REMOVED (RemoveSpell) keeps it gone while they list it.
// A mod edits a race's or an NPC_'s list from OnGameLoaded (rt.seed_spell) with the same delta.

import "core:math/rand"
import "core:slice"
import "../gamedb"

GIVEN :: 1
REMOVED :: -1

// spell_list is what `actor` knows now: its race's list, its NPC_'s, the spells of the aliases
// that hold it, then what it was given.
spell_list :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> []Form_ID {
	seeded := make([dynamic]Form_ID, context.temp_allocator)
	for src in gamedb.spell_sources(db, record_of(ws, actor), actor_pick(ws, db, actor)) {
		edits, _ := ws.spell_seeds[src.owner]
		append(&seeded, ..with_delta(rolled_spells(ws, db, actor, src.spells), edits))
	}
	for a in holder_aliases(ws, db, actor) {append(&seeded, ..a.spells)}
	delta, _ := ws.spells[actor]
	return with_delta(seeded[:], delta)
}

// seed_spell is rt.seed_spell / rt.unseed_spell: GIVEN or REMOVED on a race's or an NPC_'s list.
seed_spell :: proc(ws: ^World_State, owner, spell: Form_ID, change: i32) {
	delta_upsert(&ws.spell_seeds, owner)[spell] = change
}

has_spell :: proc(ws: ^World_State, db: ^gamedb.DB, actor, spell: Form_ID) -> bool {
	return slice.contains(spell_list(ws, db, actor), spell)
}

// give_spell is AddSpell / AddShout; false when `actor` already knew it.
give_spell :: proc(ws: ^World_State, db: ^gamedb.DB, actor, spell: Form_ID) -> bool {
	had := has_spell(ws, db, actor, spell)
	delta_upsert(&ws.spells, actor)[spell] = GIVEN
	return !had
}

// remove_spell is RemoveSpell / RemoveShout; false when `actor` did not know it.
remove_spell :: proc(ws: ^World_State, db: ^gamedb.DB, actor, spell: Form_ID) -> bool {
	if !has_spell(ws, db, actor, spell) {return false}
	delta_upsert(&ws.spells, actor)[spell] = REMOVED
	return true
}

// with_delta is `base` without what `delta` removed, then what it gave, each once.
@(private)
with_delta :: proc(base: []Form_ID, delta: map[Form_ID]i32) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for s in base {
		if delta[s] != REMOVED && !slice.contains(out[:], s) {append(&out, s)}
	}
	given := make([dynamic]Form_ID, context.temp_allocator)
	for s, d in delta {
		if d == GIVEN && !slice.contains(out[:], s) {append(&given, s)}
	}
	slice.sort(given[:])
	append(&out, ..given[:])
	return out[:]
}

// rolled_spells rolls the leveled lists in `spells` at the actor's level. The roll is seeded by
// actor and list, so it answers the same until the level or the records change.
// (hole spell-roll-timing :tags (magic records) :sev polish) leveled spell lists roll on every read; Skyrim probably rolls when the NPC loads (unsourced). Check the timing, and whether a pick should stay.
@(private)
rolled_spells :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, spells: []Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	level := actor_level(ws, db, actor)
	for s in spells {
		if _, leveled := gamedb.leveled_list_of(db, s); !leveled {
			append(&out, s)
			continue
		}
		state := rand.create(u64(actor) ~ u64(s) * 0x9E3779B97F4A7C15)
		context.random_generator = rand.default_random_generator(&state)
		rolled := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
		roll(ws, db, s, level, 1, &rolled)
		for e in rolled {append(&out, e.item)}
	}
	return out[:]
}
