package script

// A-tier overlay natives (docs/scripting-natives.md §A) — the ones whose backing store already
// exists: GlobalVariable read/write over worldstate.globals, actor life-state over the new Dead
// field, and PlaceAtMe over the created-ref space. Small, high-frequency, no new store.

import "../gamedb"
import "../worldstate"

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
	return global_value(c, c.self)
}

// global_value is a global's value: a script's write, else its authored FLTV, else 0.
global_value :: proc(c: ^Call, global: Form_ID) -> f32 {
	if v, ok := worldstate.get_global(c.ws, global); ok {return v}
	v, _ := gamedb.global_value(c.db, global)
	return v
}

n_glob_set :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_global(c.ws, c.self, arg_f32(args, 0, 0))
	return nil
}

// ── Actor life-state ───────────────────────────────────────────────────────────

// Kill(akKiller) -> None. First slice: flip the Dead flag (ragdoll/loot behaviours are Phase-7
// actor work). The killer arg is recorded by no store yet — ignored.
n_actor_kill :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_dead(c.ws, c.self, ref_cell(c, c.self), true)
	worldstate.mark_scene_dirty(c.ws, c.self)
	return nil
}

n_actor_is_dead :: proc(c: ^Call, args: []Value) -> Value {
	if d, ok := worldstate.get(c.ws, c.self); ok && .Dead in d.live {
		return d.dead
	}
	return false // no baseline "starts dead" surfaced yet
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

	cell := ref_cell(c, c.self)
	pos := ref_pos(c, c.self)
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
