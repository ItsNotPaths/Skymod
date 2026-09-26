package worldstate

import smath "../math"

// Ref_Field mirrors Skyrim's ChangeForm `changeFlags`: which fields of a ref diverge from the
// ESM. Every field has a set_* writer below; Inventory is tracked by the `inventories` store
// instead (kept here so the on-disk bit layout stays stable). Open/Locked record state today —
// their scene live-apply (door swings open, lock click) is 4c work.
Ref_Field :: enum u8 {
	Moved,     // transform changed (clutter pushed/settled, object relocated)
	Scaled,    // uniform scale changed
	Disabled,  // ref disabled/enabled at runtime
	Open,      // door/container open-state
	Locked,    // lock-state
	Inventory, // container / corpse contents
	Dead,      // actor life-state
	Deleted,   // ESM ref destroyed (streaming must suppress the baseline)
	Activation_Blocked, // BlockActivation: no default action on Activate. The bit is the whole state (a baseline ref is never blocked)
	Delete_When_Detached, // DeleteWhenAble on an attached ref: deleted when its cell detaches. The bit is the whole state
	Harvested, // flora picked; a cell reset grows it back. The bit is the whole state
}

// (hole combat-damage :tags combat :sev blocker :needs (spatial-queries)) `Dead` is set only by Actor.Kill: Health at 0 does not kill, no weapon does damage, and nothing is hostile or in combat.

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
	dead:     bool, // Dead: actor life-state (Actor.Kill / IsDead)
}

// Created_Ref is a runtime-spawned reference with NO ESM baseline — the overlay stores its WHOLE
// placement (not just a divergence), since gamedb has nothing to ⊕ against. The world layer builds an
// Instance from it (base→model via gamedb) when its cell loads. pos/rot are [3]f32 (== gamedb.Ref).
Created_Ref :: struct {
	base:  Form_ID,
	cell:  Form_ID,
	pos:   [3]f32,
	rot:   [3]f32, // XYZ euler radians
	scale: f32,
	count: i32, // an item stack's size (DropObject); 0 = 1
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
	append(&ws.new_refs, id)
	return id
}

// created_in lists the created-ref FormIDs spawned into `cell` (the loader's spawn index).
created_in :: proc(ws: ^World_State, cell: Form_ID) -> []Form_ID {
	assert_owner(ws)
	if list, ok := ws.created_by_cell[cell]; ok {
		return list[:]
	}
	return nil
}

// get_created returns a created ref's placement data.
get_created :: proc(ws: ^World_State, form_id: Form_ID) -> (Created_Ref, bool) {
	assert_owner(ws)
	c, ok := ws.created[form_id]
	return c, ok
}

// upsert returns a (mutable) delta for `form_id`, creating one and indexing it under `cell` on
// first sight — the shared primitive every mutation verb routes through (Layer 1 chokepoint;
// docs/live-state.md §7.1). The returned pointer is valid until the next ref_deltas insert, so
// each verb writes through it immediately and never retains it.
@(private)
upsert :: proc(ws: ^World_State, form_id, cell: Form_ID) -> ^Ref_Delta {
	assert_owner(ws)
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

// set_activation_blocked records BlockActivation: while set, activating the ref only sends its
// scripts OnActivate; the engine's default action (open, take, talk) does not run.
set_activation_blocked :: proc(ws: ^World_State, form_id, cell: Form_ID, blocked: bool) {
	if blocked {
		upsert(ws, form_id, cell).live += {.Activation_Blocked}
	} else if d, ok := &ws.ref_deltas[form_id]; ok {
		d.live -= {.Activation_Blocked}
	}
}

// set_delete_when_detached records DeleteWhenAble on a ref whose cell is attached: the ref is
// deleted when that cell detaches (script-api.md section 5).
set_delete_when_detached :: proc(ws: ^World_State, form_id, cell: Form_ID) {
	upsert(ws, form_id, cell).live += {.Delete_When_Detached}
}

// Pending_Move is a MoveToWhenUnloaded that waits: MoveTo(target, offset) once neither the ref's
// location nor the target's is loaded (script-api.md section 5).
Pending_Move :: struct {
	target: Form_ID,
	offset: smath.Vec3,
}

// delete_detached deletes the refs of `cell` that waited for it to detach.
delete_detached :: proc(ws: ^World_State, cell: Form_ID) {
	for id in refs_in(ws, cell) {
		d := &ws.ref_deltas[id]
		if .Delete_When_Detached not_in d.live {continue}
		d.live -= {.Delete_When_Detached}
		d.live += {.Deleted}
		append(&ws.gone_refs, id)
	}
}

set_harvested :: proc(ws: ^World_State, form_id, cell: Form_ID) {
	upsert(ws, form_id, cell).live += {.Harvested}
}

harvested :: proc(ws: ^World_State, form_id: Form_ID) -> bool {
	d, ok := ws.ref_deltas[form_id]
	return ok && .Harvested in d.live
}

// activation_blocked reports whether a script blocked the ref's default activation.
activation_blocked :: proc(ws: ^World_State, form_id: Form_ID) -> bool {
	assert_owner(ws)
	d, ok := ws.ref_deltas[form_id]
	return ok && .Activation_Blocked in d.live
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

// (hole story-kill :tags (quest combat) :sev gap :needs (story-manager)) a death queues no KILL story event with victim and killer (13 quests: TG and MG monitors, DA02, DA08, WIKill).
// set_dead records a Dead delta (actor life-state; Actor.Kill flips it, IsDead reads it).
set_dead :: proc(ws: ^World_State, form_id, cell: Form_ID, dead: bool) {
	d := upsert(ws, form_id, cell)
	d.live += {.Dead}
	d.dead = dead
}

// set_deleted marks an ESM ref destroyed: the cell-build suppresses it entirely (never instantiated).
// No data beyond the flag — the ref is gone. (Distinct from Disabled, which can be re-enabled.)
set_deleted :: proc(ws: ^World_State, form_id, cell: Form_ID) {
	d := upsert(ws, form_id, cell)
	d.live += {.Deleted}
	append(&ws.gone_refs, form_id)
}

// is_deleted reports whether a runtime Delete removed the ref.
is_deleted :: proc(ws: ^World_State, form_id: Form_ID) -> bool {
	d, ok := ws.ref_deltas[form_id]
	return ok && .Deleted in d.live
}

// get returns the delta for a form, if one exists.
get :: proc(ws: ^World_State, form_id: Form_ID) -> (Ref_Delta, bool) {
	assert_owner(ws)
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
