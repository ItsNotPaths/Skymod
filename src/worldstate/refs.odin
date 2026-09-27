package worldstate

import "core:math"
import "core:slice"
import smath "../math"
import "../gamedb"

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
	Lock_Level, // SetLockLevel: the lock's level
	Destroyed, // SetDestroyed: at its last destruction stage. The bit is the whole state
}

// (hole combat-damage :tags combat :sev blocker) `Dead` is set only by Actor.Kill: Health at 0 does not kill, no weapon does damage, and nothing is hostile or in combat.

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
	lock_level: u8, // Lock_Level: 0 Novice .. 100 Master, 255 key only
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
	if d, existed := &ws.ref_deltas[form_id]; existed && d.cell != cell {
		if list, ok := &ws.by_cell[d.cell]; ok {remove_id(list, form_id)}
	} else if existed {
		return d
	} else {
		ws.ref_deltas[form_id] = {}
	}
	if cell not_in ws.by_cell {ws.by_cell[cell] = make([dynamic]Form_ID)}
	append(&ws.by_cell[cell], form_id)
	d := &ws.ref_deltas[form_id]
	d.cell = cell
	return d
}

// set_moved records (or updates) a Moved delta. Re-settling the same ref overwrites its transform. A
// created ref moved to another cell spawns there.
set_moved :: proc(ws: ^World_State, form_id, cell: Form_ID, world: smath.Mat4, pos: smath.Vec3) {
	if cr, ok := &ws.created[form_id]; ok && cr.cell != cell {
		if list, lok := &ws.created_by_cell[cr.cell]; lok {remove_id(list, form_id)}
		cr.cell = cell
		if cell not_in ws.created_by_cell {ws.created_by_cell[cell] = make([dynamic]Form_ID)}
		append(&ws.created_by_cell[cell], form_id)
	}
	d := upsert(ws, form_id, cell)
	d.live += {.Moved}
	d.world = world
	d.pos = pos
}

// Refile is a ref the transitions tick must file again among the attached cells. `moved` is false
// when an alias took it where it stands.
Refile :: struct {
	ref:   Form_ID,
	moved: bool,
}

// relocate puts a ref at a new placement for a script or the engine, and queues it for refiling.
relocate :: proc(ws: ^World_State, form, cell: Form_ID, pos, rot: smath.Vec3) {
	set_moved(ws, form, cell, smath.trs(pos, rot, 1), pos)
	mark_scene_dirty(ws, form)
	append(&ws.refiles, Refile{form, true})
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

// (hole destruction-stages :tags (combat world) :sev gap :needs combat-damage) damage never moves a ref through its DEST stages: only SetDestroyed marks one destroyed, GetCurrentDestructionStage and GetDestructionStage do not read it, and nothing swaps in the destroyed model or explodes.
// set_destroyed records SetDestroyed and ClearDestruction.
set_destroyed :: proc(ws: ^World_State, form_id, cell: Form_ID, destroyed: bool) {
	if destroyed {
		upsert(ws, form_id, cell).live += {.Destroyed}
	} else if d, ok := &ws.ref_deltas[form_id]; ok {
		d.live -= {.Destroyed}
	}
}

is_destroyed :: proc(ws: ^World_State, form_id: Form_ID) -> bool {
	d, ok := ws.ref_deltas[form_id]
	return ok && .Destroyed in d.live
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

set_lock_level :: proc(ws: ^World_State, form_id, cell: Form_ID, level: u8) {
	d := upsert(ws, form_id, cell)
	d.live += {.Lock_Level}
	d.lock_level = level
}

// lock_level is GetLockLevel: a script's SetLockLevel, else the ref's XLOC; 0 with neither.
lock_level :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> u8 {
	if d, ok := get(ws, form); ok && .Lock_Level in d.live {return d.lock_level}
	lock, _ := gamedb.lock_of(db, form)
	return lock.level
}

// is_locked is a ref's current lock state: a script's or the player's change, else an XLOC on the ref.
is_locked :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> bool {
	if d, ok := get(ws, form); ok && .Locked in d.live {return d.locked}
	_, locked := gamedb.lock_of(db, form)
	return locked
}

// (hole door-default-open :tags world :sev gap) a door's authored open-by-default flag is not decoded; an untouched door reads closed.
// open_state is GetOpenState: 1 open or 3 closed for a door or a ref SetOpen touched, else 0 (none).
open_state :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> i32 {
	if d, ok := get(ws, form); ok && .Open in d.live {return 1 if d.open else 3}
	return 3 if gamedb.is_door(db, ref_base(ws, db, form)) else 0
}

// set_dead records a Dead delta (actor life-state; Actor.Kill flips it, IsDead reads it).
set_dead :: proc(ws: ^World_State, form_id, cell: Form_ID, dead: bool) {
	d := upsert(ws, form_id, cell)
	d.live += {.Dead}
	d.dead = dead
}

// Death is an actor that died since the VM last looked, for OnDying and OnDeath.
Death :: struct {
	actor, killer: Form_ID,
}

// is_dead reads the Dead delta. No baseline "starts dead" is surfaced yet.
is_dead :: proc(ws: ^World_State, form_id: Form_ID) -> bool {
	d, ok := get(ws, form_id)
	return ok && .Dead in d.live && d.dead
}

// dead_count is how many actors placed from the NPC_ `base` are dead.
dead_count :: proc(ws: ^World_State, db: ^gamedb.DB, base: Form_ID) -> i32 {
	n: i32
	for ref, d in ws.ref_deltas {
		if .Dead in d.live && d.dead && ref_base(ws, db, ref) == base {n += 1}
	}
	return n
}

// ref_type_count is how many of a location's refs of a location ref type are dead, or alive.
ref_type_count :: proc(ws: ^World_State, db: ^gamedb.DB, location, ref_type: Form_ID, dead: bool) -> i32 {
	n: i32
	for ref in gamedb.location_special_refs(db, location, ref_type) {
		if is_dead(ws, ref) == dead {n += 1}
	}
	return n
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

// ref_cell resolves a ref's CURRENT owning cell: the overlay (if it moved), the baseline, or a
// created ref's cell. 0 when the ref has none.
ref_cell :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> Form_ID {
	if d, ok := get(ws, form); ok && d.cell != 0 {return d.cell}
	if r, ok := gamedb.ref_by_formid(db, form); ok {return r.cell_form_id}
	if cr, ok := get_created(ws, form); ok {return cr.cell}
	return 0
}

// ref_pos resolves a ref's CURRENT position, in the same order as ref_cell.
ref_pos :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> smath.Vec3 {
	if d, ok := get(ws, form); ok && .Moved in d.live {return d.pos}
	if r, ok := gamedb.ref_by_formid(db, form); ok {return r.pos}
	if cr, ok := get_created(ws, form); ok {return cr.pos}
	return {}
}

// ref_rot resolves a ref's CURRENT rotation, XYZ euler radians, in the same order as ref_cell.
ref_rot :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> [3]f32 {
	if d, ok := get(ws, form); ok && .Moved in d.live {return smath.trs_rot(d.world)}
	if r, ok := gamedb.ref_by_formid(db, form); ok {return r.rot}
	if cr, ok := get_created(ws, form); ok {return cr.rot}
	return {}
}

// ref_grid_cell is the cell under a ref, with a worldspace-persistent ref resolved to its grid cell.
ref_grid_cell :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> Form_ID {
	return gamedb.grid_cell(db, ref_cell(ws, db, form), ref_pos(ws, db, form))
}

// ref_space is the interior cell or the worldspace a ref is in; 0 when it has no cell.
ref_space :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> Form_ID {
	cell, ok := gamedb.cell_by_formid(db, ref_cell(ws, db, form))
	if !ok {return 0}
	return cell.form_id if cell.interior else cell.world_form_id
}

// ref_location is the location of the cell under a ref, else its worldspace's.
ref_location :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> Form_ID {
	return gamedb.cell_location(db, ref_grid_cell(ws, db, form))
}

// FAR_DISTANCE is the distance between refs in different cells or worldspaces, or with no position.
FAR_DISTANCE :: f32(1e9)

ref_distance :: proc(ws: ^World_State, db: ^gamedb.DB, a, b: Form_ID) -> f32 {
	space := ref_space(ws, db, a)
	if space == 0 || space != ref_space(ws, db, b) {return FAR_DISTANCE}
	return smath.length3(ref_pos(ws, db, a) - ref_pos(ws, db, b))
}

// heading_angle is the turn from a's facing to b, in degrees, -180 to 180; positive is clockwise.
heading_angle :: proc(ws: ^World_State, db: ^gamedb.DB, a, b: Form_ID) -> f32 {
	return turn_to(ws, db, a, ref_pos(ws, db, b) - ref_pos(ws, db, a))
}

// turn_to is the turn from a's facing to the direction d, in degrees, -180 to 180; positive is clockwise.
turn_to :: proc(ws: ^World_State, db: ^gamedb.DB, a: Form_ID, d: [3]f32) -> f32 {
	turn := math.to_degrees(math.atan2(d.x, d.y) - ref_rot(ws, db, a).z)
	return math.mod(math.mod(turn, 360) + 540, 360) - 180
}

// has_keyword checks the form, a ref's base form, and the aliases that hold it.
has_keyword :: proc(ws: ^World_State, db: ^gamedb.DB, form, keyword: Form_ID) -> bool {
	if gamedb.has_keyword(db, form, keyword) || gamedb.has_keyword(db, ref_base(ws, db, form), keyword) {return true}
	for a in holder_aliases(ws, db, form) {
		if slice.contains(a.keywords, keyword) {return true}
	}
	return false
}

// ref_scale is a ref's current scale: a script's SetScale, else its placement's.
ref_scale :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> f32 {
	if d, ok := get(ws, form); ok && .Scaled in d.live {return d.scale}
	if r, ok := gamedb.ref_by_formid(db, form); ok {return r.scale}
	if cr, ok := get_created(ws, form); ok {return cr.scale}
	return 1
}

// ref_3d_loaded reports whether a ref is enabled and in an attached cell.
ref_3d_loaded :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> bool {
	cell := ref_grid_cell(ws, db, form)
	return cell != 0 && cell in ws.attached && ref_enabled(ws, db, form)
}

// ref_enabled is a ref's current enable state: a script's Enable/Disable wins, else the REFR
// flag, else its enable parent's current state (XOR the opposite flag), up the chain.
ref_enabled :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID, depth := 0) -> bool {
	if d, ok := get(ws, form); ok && .Disabled in d.live {
		return !d.disabled
	}
	r, ok := gamedb.ref_by_formid(db, form)
	if !ok {return true} // a ref with no baseline (created) is enabled
	if r.disabled {return false}
	if _, known := gamedb.ref_by_formid(db, r.enable_parent); !known || depth > 16 {return true}
	return ref_enabled(ws, db, r.enable_parent, depth + 1) != r.enable_opposite
}
