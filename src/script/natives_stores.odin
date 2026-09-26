package script

// A-tier overlay natives (docs/scripting-natives.md §A) — the ones whose backing store already
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

// Kill(akKiller) -> None. First slice: flip the Dead flag (ragdoll/loot behaviours are Phase-7
// actor work). The killer arg is recorded by no store yet — ignored.
n_actor_kill :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_dead(c.ws, c.self, worldstate.ref_cell(c.ws, c.db, c.self), true)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_actor_is_dead :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.is_dead(c.ws, c.self)
}

// ── PlaceAtMe ──────────────────────────────────────────────────────────────────

// PlaceAtMe(akFormToPlace, aiCount, abForcePersist, abInitiallyDisabled) -> ObjectReference. Mints
// runtime refs of the base form at the caller's current position/cell (rotation from the caller's
// baseline). aiCount copies are spawned; Papyrus returns the LAST. abForcePersist is a persistence
// hint with no bearing on our overlay (created refs already persist). abInitiallyDisabled writes a
// Disabled delta on the new ref so the streamer skips it until Enable.
n_place_at_me :: proc(c: ^Call, args: []Value) -> Value {
	base := arg_form(args, 0)
	if base == 0 {return nil} // Papyrus: placing None places nothing and returns None
	count := max(1, int(arg_i32(args, 1, 1)))
	disabled := arg_bool(args, 3, false)

	cell := worldstate.ref_cell(c.ws, c.db, c.self)
	pos := worldstate.ref_pos(c.ws, c.db, c.self)
	rot: [3]f32
	if r, ok := gamedb.ref_by_formid(c.db, c.self); ok {
		rot = r.rot
	}

	last: Form_ID
	for _ in 0 ..< count {
		last = worldstate.create_ref(c.ws, base, cell, {pos.x, pos.y, pos.z}, rot, 1)
		if disabled {
			worldstate.set_disabled(c.ws, last, cell, true)
		}
		worldstate.mark_scene_dirty(c.ws, last)
	}
	return last
}
