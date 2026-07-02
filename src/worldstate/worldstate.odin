package worldstate

// World-state overlay (ROADMAP Phase 3c — the keystone; design in docs/saves.md §4.1). The
// MUTABLE, authoritative in-RAM world-delta layer that sits BETWEEN the immutable `gamedb`
// baseline and the transient `world.Scene`. `gamedb` says where the ESM placed every ref; the
// overlay stores only DIVERGENCE from that baseline (sparse — a fresh game has zero deltas and a
// full world). The streamer builds each cell as "baseline ⊕ overlay": `world.apply_overlay`
// patches instances from here on load, `world.capture_settles` writes deltas back when physics
// settles a moved object. Save/load (Phase 3d) is just (de)serialising this struct.
//
// This first slice implements the MOVED field (dynamic clutter coming to rest). The remaining
// categories from §4.1 (scale/disable/open/lock/inventory/life, created refs, cells/locations/
// globals/factions, player) slot in as new `Ref_Field`s + struct fields without reshaping the
// file — that forward-compatibility is the whole point.

import smath "../math"

// Form_ID is the global form handle (= gamedb.Form_ID = u64): (slot<<32)|local. Kept as a local
// alias so worldstate stays independent of gamedb; both resolve to u64, so handles pass freely.
Form_ID :: u64

// Ref_Field mirrors Skyrim's ChangeForm `changeFlags`: which fields of a ref diverge from the
// ESM. Only Moved is captured today; the rest are reserved (see docs/saves.md §4.1).
Ref_Field :: enum u8 {
	Moved,     // transform changed (clutter pushed/settled, object relocated)
	Scaled,    // uniform scale changed
	Disabled,  // ref disabled/enabled at runtime
	Open,      // door/container open-state
	Locked,    // lock-state
	Inventory, // container / corpse contents
	Dead,      // actor life-state
	Deleted,   // ESM ref destroyed (streaming must suppress the baseline)
}

// Ref_Delta is a sparse override of one ESM ref — the in-RAM equivalent of a ChangeForm. `live`
// says which fields are valid (so we patch/serialise only those). The Moved transform is held as
// a matrix in RAM (the settled pose, which a tumbled body reaches at an arbitrary orientation that
// the engine's transpose-euler `trs` convention makes awkward to round-trip as angles); Phase 3d
// TRS-decomposes it for the on-disk form. Strings/model paths are never stored here — they live in
// gamedb, borrowed.
Ref_Delta :: struct {
	cell:     Form_ID, // owning cell (by_cell index)
	live:     bit_set[Ref_Field],
	world:    smath.Mat4, // Moved: settled placement transform (replaces the ESM trs(pos,rot,scale))
	pos:      smath.Vec3, // Moved: its translation (proximity / by_cell convenience, == world col 3)
	scale:    f32,  // Scaled: uniform scale (replaces REFR XSCL)
	disabled: bool, // Disabled: runtime enable-state (diverges from REFR "Initially Disabled")
	open:     bool, // Open: door/container open-state
	locked:   bool, // Locked: lock-state (level/key reserved for the lock subsystem)
}

// CREATED_FORM_BASE starts the runtime-created FormID space: a ref minted at runtime (PlaceAtMe /
// spawn) has no ESM baseline, so its FormID must not collide with any plugin's. We reserve the top
// slot (0xFFFFFFFF) — no load order reaches it — and hand out sequential locals within it. (The wide
// Form_ID generalises Skyrim's 0xFF prefix to a full reserved slot.)
CREATED_FORM_BASE :: Form_ID(0xFFFF_FFFF) << 32

// Created_Ref is a runtime-spawned reference with NO ESM baseline — the overlay stores its WHOLE
// placement (not just a divergence), since gamedb has nothing to ⊕ against. The world layer builds an
// Instance from it (base→model via gamedb) when its cell loads. pos/rot are [3]f32 (== gamedb.Ref).
Created_Ref :: struct {
	base:  Form_ID,
	cell:  Form_ID,
	pos:   [3]f32,
	rot:   [3]f32, // XYZ euler radians
	scale: f32,
}

// Player_State is the player singleton (§4.1): where the player is, so a load returns them there
// instead of the default spawn. `cell` lets the loader decide exterior (set position directly) vs
// interior (must enter that cell first). `set` distinguishes "no player recorded" from origin.
Player_State :: struct {
	cell:  Form_ID,     // owning cell (0 / exterior worldspace handled by the loader)
	pos:   [3]f32,
	yaw:   f32,     // camera yaw/pitch (radians) — restored so you face the same way
	pitch: f32,
	set:   bool,
}

// World_State is the live overlay: a sparse FormID→delta map + per-cell index (patches to EXISTING ESM
// refs), the created-ref space (refs ADDED at runtime), plus the coarse singletons — globals and the
// player — from §4.1. Everything here is "what diverges from a fresh game"; a new game is all zero.
World_State :: struct {
	ref_deltas:      map[Form_ID]Ref_Delta,       // FormID -> delta (the ChangeForm-equivalent table)
	by_cell:         map[Form_ID][dynamic]Form_ID,     // CellFormID -> FormIDs with deltas (patch index)
	created:         map[Form_ID]Created_Ref,      // FormID (0xFF space) -> runtime-spawned ref
	created_by_cell: map[Form_ID][dynamic]Form_ID,     // CellFormID -> created FormIDs to spawn (stream index)
	next_created:    Form_ID,                      // next FormID to hand out (>= CREATED_FORM_BASE)
	globals:         map[Form_ID]f32,              // GLOB FormID / script var -> value (quests, flags, timers)
	player:          Player_State,             // the player singleton (position/facing; stats later)
	// Deferred scene-apply queue (docs/script-runtime-decisions.md §3): writers that DON'T touch the
	// live scene themselves (script natives) append the form they changed here; the app drains it at
	// one fixed frame point and re-applies each to the resident scene. The world's own *_ref verbs
	// apply live at call time and DON'T enqueue. Ordered; a form may repeat (drain is idempotent).
	scene_dirty:     [dynamic]Form_ID,
}

init :: proc(ws: ^World_State) {
	ws.ref_deltas = make(map[Form_ID]Ref_Delta)
	ws.by_cell = make(map[Form_ID][dynamic]Form_ID)
	ws.created = make(map[Form_ID]Created_Ref)
	ws.created_by_cell = make(map[Form_ID][dynamic]Form_ID)
	ws.next_created = CREATED_FORM_BASE
	ws.globals = make(map[Form_ID]f32)
	ws.scene_dirty = make([dynamic]Form_ID)
}

destroy :: proc(ws: ^World_State) {
	for _, &list in ws.by_cell {
		delete(list)
	}
	for _, &list in ws.created_by_cell {
		delete(list)
	}
	delete(ws.by_cell)
	delete(ws.ref_deltas)
	delete(ws.created_by_cell)
	delete(ws.created)
	delete(ws.globals)
	delete(ws.scene_dirty)
	ws^ = {}
}

// mark_scene_dirty enqueues `form_id` for deferred live-apply. Called by writers that only touch the
// overlay (script natives) so the app's per-frame drain re-applies the change to the resident scene.
mark_scene_dirty :: proc(ws: ^World_State, form_id: Form_ID) {
	append(&ws.scene_dirty, form_id)
}

// pending_scene returns the queued dirty forms (drain-and-apply, then clear_scene_dirty).
pending_scene :: proc(ws: ^World_State) -> []Form_ID {
	return ws.scene_dirty[:]
}

// clear_scene_dirty empties the deferred-apply queue (after the app has applied it this frame).
clear_scene_dirty :: proc(ws: ^World_State) {
	clear(&ws.scene_dirty)
}

// create_ref mints a runtime ref in the 0xFF space (no ESM baseline), stores its full placement, and
// indexes it by cell so the loader can spawn it. Returns the new FormID. The world layer turns it
// into an Instance (spawn_created) when its cell is/loads resident.
create_ref :: proc(ws: ^World_State, base, cell: Form_ID, pos, rot: [3]f32, scale: f32) -> Form_ID {
	id := ws.next_created
	ws.next_created += 1
	ws.created[id] = Created_Ref{base = base, cell = cell, pos = pos, rot = rot, scale = scale}
	list, ok := &ws.created_by_cell[cell]
	if !ok {
		ws.created_by_cell[cell] = make([dynamic]Form_ID)
		list = &ws.created_by_cell[cell]
	}
	append(list, id)
	return id
}

// created_in lists the created-ref FormIDs spawned into `cell` (the loader's spawn index).
created_in :: proc(ws: ^World_State, cell: Form_ID) -> []Form_ID {
	if list, ok := ws.created_by_cell[cell]; ok {
		return list[:]
	}
	return nil
}

// get_created returns a created ref's placement data.
get_created :: proc(ws: ^World_State, form_id: Form_ID) -> (Created_Ref, bool) {
	c, ok := ws.created[form_id]
	return c, ok
}

// upsert returns a (mutable) delta for `form_id`, creating one and indexing it under `cell` on
// first sight — the shared primitive every mutation verb routes through (Layer 1 chokepoint;
// docs/live-state.md §7.1). The returned pointer is valid until the next ref_deltas insert, so
// each verb writes through it immediately and never retains it.
@(private)
upsert :: proc(ws: ^World_State, form_id, cell: Form_ID) -> ^Ref_Delta {
	if _, existed := ws.ref_deltas[form_id]; !existed {
		ws.ref_deltas[form_id] = Ref_Delta{cell = cell}
		list, ok := &ws.by_cell[cell]
		if !ok {
			ws.by_cell[cell] = make([dynamic]Form_ID)
			list = &ws.by_cell[cell]
		}
		append(list, form_id)
	}
	d := &ws.ref_deltas[form_id]
	d.cell = cell
	return d
}

// set_moved records (or updates) a Moved delta. Re-settling the same ref overwrites its transform.
set_moved :: proc(ws: ^World_State, form_id, cell: Form_ID, world: smath.Mat4, pos: smath.Vec3) {
	d := upsert(ws, form_id, cell)
	d.live += {.Moved}
	d.world = world
	d.pos = pos
}

// set_scale records a Scaled delta (uniform scale override).
set_scale :: proc(ws: ^World_State, form_id, cell: Form_ID, scale: f32) {
	d := upsert(ws, form_id, cell)
	d.live += {.Scaled}
	d.scale = scale
}

// set_disabled records a Disabled delta (runtime enable/disable, e.g. a script DisableRef).
set_disabled :: proc(ws: ^World_State, form_id, cell: Form_ID, disabled: bool) {
	d := upsert(ws, form_id, cell)
	d.live += {.Disabled}
	d.disabled = disabled
}

// set_open records an Open delta (door/container open-state).
set_open :: proc(ws: ^World_State, form_id, cell: Form_ID, open: bool) {
	d := upsert(ws, form_id, cell)
	d.live += {.Open}
	d.open = open
}

// set_locked records a Locked delta (lock-state; level/key reserved for the lock subsystem).
set_locked :: proc(ws: ^World_State, form_id, cell: Form_ID, locked: bool) {
	d := upsert(ws, form_id, cell)
	d.live += {.Locked}
	d.locked = locked
}

// set_deleted marks an ESM ref destroyed: the cell-build suppresses it entirely (never instantiated).
// No data beyond the flag — the ref is gone. (Distinct from Disabled, which can be re-enabled.)
set_deleted :: proc(ws: ^World_State, form_id, cell: Form_ID) {
	d := upsert(ws, form_id, cell)
	d.live += {.Deleted}
}

// set_global / get_global: the coarse world-fact store (GLOB FormIDs, quest stages, script vars,
// timers). A plain id→value map — the simplest overlay category, but the one scripting leans on most.
set_global :: proc(ws: ^World_State, id: Form_ID, value: f32) {
	ws.globals[id] = value
}

get_global :: proc(ws: ^World_State, id: Form_ID) -> (f32, bool) {
	v, ok := ws.globals[id]
	return v, ok
}

// set_player / get_player: the player singleton — where the player is + facing, so a load returns
// them there. get_player's ok is false until a position has been recorded (fresh game = default spawn).
set_player :: proc(ws: ^World_State, cell: Form_ID, pos: [3]f32, yaw, pitch: f32) {
	ws.player = Player_State{cell = cell, pos = pos, yaw = yaw, pitch = pitch, set = true}
}

get_player :: proc(ws: ^World_State) -> (Player_State, bool) {
	return ws.player, ws.player.set
}

// get returns the delta for a form, if one exists.
get :: proc(ws: ^World_State, form_id: Form_ID) -> (Ref_Delta, bool) {
	d, ok := ws.ref_deltas[form_id]
	return d, ok
}

// refs_in lists the FormIDs that carry a delta in `cell` (the stream index, for cell-scoped patching).
refs_in :: proc(ws: ^World_State, cell: Form_ID) -> []Form_ID {
	if list, ok := ws.by_cell[cell]; ok {
		return list[:]
	}
	return nil
}

// count reports how many refs currently diverge from the baseline (overlay-size probe / overlay UI).
count :: proc(ws: ^World_State) -> int {
	return len(ws.ref_deltas)
}
