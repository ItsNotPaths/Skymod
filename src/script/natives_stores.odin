package script

// A-tier overlay natives (mydocs/scripting-natives.md §A) — the ones whose backing store already
// exists: GlobalVariable read/write over worldstate.globals, actor life-state over the new Dead
// field, and PlaceAtMe over the created-ref space. Small, high-frequency, no new store.

import "../gamedb"
import "../worldstate"
import "../formid"

register_stores :: proc(reg: ^Registry) {
	// GlobalVariable — `self` is the GLOB form; value lives in worldstate.globals.
	register(reg, "GlobalVariable", "GetValue", n_glob_get)
	register(reg, "GlobalVariable", "SetValue", n_glob_set)

	// Actor life-state.
	register(reg, "Actor", "Kill", n_actor_kill)
	register(reg, "Actor", "Resurrect", n_resurrect)
	register(reg, "Actor", "IsDead", n_actor_is_dead)

	// Spawning.
	register(reg, "ObjectReference", "PlaceAtMe", n_place_at_me)
}

// ── GlobalVariable ─────────────────────────────────────────────────────────────

n_glob_get :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.global_value(c.ws, c.db, c.self)
}

n_glob_set :: proc(c: ^Call, args: []Value) -> Value {
	v := arg_f32(args, 0, 0)
	if c.self == formid.GAME_HOUR {
		worldstate.set_game_hour(c.ws, v)
		return nil
	}
	worldstate.set_global(c.ws, c.self, v)
	return nil
}

// ── Actor life-state ───────────────────────────────────────────────────────────

// Kill(akKiller) -> None: the Dead flag, the death cry (a DETH bark), OnDying and OnDeath, cleared
// boss locations and the KILL story event. A dead actor does not die again.
// (hole kill-essential :tags combat :sev polish) Kill does not read IsEssential (worldstate.actor_flag); unsourced whether Skyrim refuses, or sends the actor to bleedout.
n_actor_kill :: proc(c: ^Call, args: []Value) -> Value {
	kill(c, c.self, arg_form(c, args, 0))
	return nil
}

// Resurrect: a dead actor lives again at full Health and picks its package anew. Its inventory stays.
n_resurrect :: proc(c: ^Call, args: []Value) -> Value {
	if !worldstate.is_dead(c.ws, c.db, c.self) {return nil}
	worldstate.set_dead(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), false)
	delete_key(&c.ws.killers, c.self)
	worldstate.av_restore(c.ws, c.self, "Health", max(f32))
	c.ws.ai.evaluate[c.self] = true
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

kill :: proc(c: ^Call, actor, killer: Form_ID) {
	if worldstate.is_dead(c.ws, c.db, actor) {return}
	crime := worldstate.report_crime(c.ws, c.db, killer, actor, .Murder, 0)
	append(&c.ws.deaths, worldstate.Death{actor, killer})
	c.ws.killers[actor] = killer
	worldstate.set_dead(c.ws, actor, worldstate.ref_cell(c.ws, c.db, actor), true)
	// The death cry replaces whatever the actor was about to say.
	#reverse for b, i in c.ws.barks {
		if b.speaker == actor {ordered_remove(&c.ws.barks, i)}
	}
	append(&c.ws.barks, worldstate.Bark{speaker = actor, subtype = worldstate.SUBTYPE_DEATH})
	worldstate.stop_doing(c.ws, c.db, actor)
	worldstate.mark_scene_dirty(c.ws, actor)
	boss_died(c, actor)
	worldstate.queue_story_event(c.ws, {
		type      = worldstate.STORY_KILL,
		ref1      = actor,
		ref2      = killer,
		location1 = worldstate.ref_location(c.ws, c.db, actor),
		value1    = i32(crime),
		value2    = worldstate.rel_rank(c.ws, c.db, actor, c.ws.player),
	})
}

n_actor_is_dead :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.is_dead(c.ws, c.db, c.self)
}

// ── PlaceAtMe ──────────────────────────────────────────────────────────────────

// PlaceAtMe(akFormToPlace, aiCount, abForcePersist, abInitiallyDisabled) -> ObjectReference. Mints
// runtime refs of the base form at the caller's current position/cell (rotation from the caller's
// baseline). aiCount copies are spawned; Papyrus returns the LAST. abForcePersist is a persistence
// hint with no bearing on our overlay (created refs already persist). abInitiallyDisabled writes a
// Disabled delta on the new ref so the streamer skips it until Enable.
n_place_at_me :: proc(c: ^Call, args: []Value) -> Value {
	return form_or_none(place_at_me(c, arg_form(c, args, 0), max(1, int(arg_i32(args, 1, 1))), arg_bool(args, 3, false)))
}

// place_at_me mints `count` refs of `base` where the caller stands and returns the last; 0 for no base.
place_at_me :: proc(c: ^Call, base: Form_ID, count := 1, disabled := false) -> Form_ID {
	if base == 0 {return 0} // Papyrus: placing None places nothing and returns None
	cell := worldstate.ref_cell(c.ws, c.db, c.self)
	pos := worldstate.ref_pos(c.ws, c.db, c.self)
	rot: [3]f32
	if r, ok := gamedb.ref_by_formid(c.db, c.self); ok {
		rot = r.rot
	}

	// A hazard is a zone: an actor that places one is its caster; a trap's hits everyone.
	caster := c.self if gamedb.is_actor(c.db, worldstate.ref_base(c.ws, c.db, c.self)) else 0
	zone, h, hazard := worldstate.hazard_zone(c.db, base, caster)
	last: Form_ID
	for _ in 0 ..< count {
		last = worldstate.make_zone(c.ws, c.db, base, c.self, zone, int(h.limit)) if hazard else worldstate.create_ref(c.ws, base, cell, {pos.x, pos.y, pos.z}, rot, 1)
		if disabled {
			worldstate.set_disabled(c.ws, last, cell, true)
		}
		worldstate.mark_scene_dirty(c.ws, last)
	}
	return last
}
