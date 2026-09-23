package worldstate

// World-state overlay (ROADMAP Phase 3c — the keystone; design in docs/saves.md §4.1). The
// MUTABLE, authoritative in-RAM world-delta layer that sits BETWEEN the immutable `gamedb`
// baseline and the transient `world.Scene`. `gamedb` says where the ESM placed every ref; the
// overlay stores only DIVERGENCE from that baseline (sparse — a fresh game has zero deltas and a
// full world). The streamer builds each cell as "baseline ⊕ overlay": `world.apply_overlay`
// patches instances from here on load, `world.capture_settles` writes deltas back when physics
// settles a moved object. Save/load (Phase 3d) is just (de)serialising this struct.
//
// As of Phase 4b the overlay carries every §4.1 category: the per-ref deltas (moved/scaled/
// disabled/open/locked/dead/deleted), created refs, and the coarse stores (globals, quests,
// inventories, actor values, factions, relationships, player). Inventory divergence lives in
// its own `inventories` store rather than a Ref_Field — see World_State below.

import "core:strings"
import smath "../math"

// Form_ID is the global form handle (= gamedb.Form_ID = u64): (slot<<32)|local. Kept as a local
// alias so worldstate stays independent of gamedb; both resolve to u64, so handles pass freely.
Form_ID :: u64

// HOLE(world, blocker): no game clock — nothing tracks the in-game hour or date. There is no day/night, no schedule for a package to follow, and GameHour / GetCurrentGameTime have nothing to read.

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
}

// HOLE(combat, blocker): `Dead` is a flag a script sets. Nothing computes it — there is no health value anywhere in the engine, no damage application, no hostility and no death path.

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

// CREATED_FORM_BASE starts the runtime-created FormID space: a ref minted at runtime (PlaceAtMe /
// spawn) has no ESM baseline, so its FormID must not collide with any plugin's. We reserve the top
// slot (0xFFFFFFFF) — no load order reaches it — and hand out sequential locals within it. (The wide
// Form_ID generalises Skyrim's 0xFF prefix to a full reserved slot.)
CREATED_FORM_BASE :: Form_ID(0xFFFF_FFFF) << 32

// An alias handle addresses one quest alias as a form, so its scripts, registrations and filters key
// like any other form's. It encodes (quest, alias id): high word ALIAS_TAG | id << 16 | the quest's
// slot, low word the quest's local id. The slot stays where a save's remap finds it.
ALIAS_TAG :: u32(0x4000_0000)

alias_handle :: proc(quest: Form_ID, id: u32) -> (Form_ID, bool) {
	slot := u32(quest >> 32)
	if slot > 0xFFFF || id > 0x3FFF {return 0, false}
	return Form_ID(ALIAS_TAG | id << 16 | slot) << 32 | (quest & 0xFFFF_FFFF), true
}

// alias_key splits an alias handle into its quest and alias id; ok=false for any other form.
alias_key :: proc(h: Form_ID) -> (quest: Form_ID, id: u32, ok: bool) {
	hi := u32(h >> 32)
	if hi & 0xC000_0000 != ALIAS_TAG {return}
	return Form_ID(hi & 0xFFFF) << 32 | (h & 0xFFFF_FFFF), (hi >> 16) & 0x3FFF, true
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
}

// Player_State is the player singleton (§4.1): where the player is, so a load returns them there
// instead of the default spawn. `cell` lets the loader decide exterior (set position directly) vs
// interior (must enter that cell first). `set` distinguishes "no player recorded" from origin.
Player_State :: struct {
	cell:  Form_ID,     // owning cell (0 / exterior worldspace handled by the loader)
	pos:   [3]f32,
	yaw:   f32,     // camera yaw/pitch (radians) — restored so you face the same way
	pitch: f32,
	level: i32,     // character level (shown on the load screen); real leveling lands later, default 1
	set:   bool,
}

// Objective_Flag / Objective_State mirror a quest objective's three independent runtime bits
// (an objective can be displayed AND completed, or displayed-then-failed). bit_set onto a byte so
// the save lowers it as a u8.
Objective_Flag :: enum u8 {
	Displayed,
	Completed,
	Failed,
}
Objective_State :: distinct bit_set[Objective_Flag;u8]

// Quest_State is a quest's runtime divergence from its ESM baseline (docs/scripting-natives.md §B):
// the current stage (INDX u16 — see the string-label design note), the set of stages that have run
// (IsStageDone), per-objective flags, and run-state. A fresh game has no entry for any quest (its
// baseline start-game-enabled state drives it); the store only records what a script has touched.
// `done`/`objectives` are owned maps — quest_free releases them on destroy/clear/load.
Quest_State :: struct {
	stage:       u16, // current stage id (raw last-set; GetRecentStageID)
	running:     bool, // Start/Stop — the quest instance is live (authoritative only if running_set)
	running_set: bool, // has Start/Stop been called? if not, IsRunning defers to the baseline SGE flag
	started:     bool, // has ever been Start()ed (distinguishes "never run" from "stopped")
	active:      bool, // SetActive — shown as the tracked quest in the log
	completed:   bool, // CompleteQuest — reached a completion stage
	done:        map[u16]bool, // stages that have executed
	objectives:  map[u16]Objective_State, // objective id -> its flags
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
	globals:         map[Form_ID]f32,              // GLOB FormID -> value (script globals; NOT quest stages)
	quests:          map[Form_ID]Quest_State,      // QUST FormID -> its runtime state (stages/objectives/run-state)
	inventories:     map[Form_ID]map[Form_ID]i32,  // owner FormID -> (item FormID -> count delta from baseline)
	actor_values:    map[Form_ID]map[string]f32,   // actor FormID -> (AV name, lower+owned -> value)
	factions:        map[Form_ID]map[Form_ID]i32,  // actor FormID -> (faction FormID -> rank); presence = membership
	relationships:   map[Form_ID]map[Form_ID]i32,  // actor FormID -> (other actor FormID -> relationship rank)
	perks:           map[Form_ID]map[Form_ID]bool, // actor FormID -> the perks it has taken (presence = taken)
	updates:         map[Form_ID]Update_Timers,    // form -> its OnUpdate registrations (the scheduler's timers)
	item_filters:    map[Form_ID][dynamic]Form_ID, // container -> AddInventoryEventFilter forms; absent = every item passes
	aliases:         map[Form_ID]Form_ID,          // alias handle -> the form filling it; absent = empty
	alias_holders:   map[Form_ID][dynamic]Form_ID, // form -> the aliases it fills (the reverse of aliases; not saved)
	player:          Player_State,             // the player singleton (position/facing; stats later)
	// Deferred scene-apply queue (docs/script-runtime-decisions.md §3): writers that DON'T touch the
	// live scene themselves (script natives) append the form they changed here; the app drains it at
	// one fixed frame point and re-applies each to the resident scene. The world's own *_ref verbs
	// apply live at call time and DON'T enqueue. Ordered; a form may repeat (drain is idempotent).
	scene_dirty:     [dynamic]Form_ID,
	// Activations a script requested (ObjectReference.Activate). The app runs them at the next tick,
	// through the same path as the player's Activate key, and clears the list. Never saved.
	activations:     [dynamic]Activation,
	// Items scripts moved since the last tick; the tick sends their inventory events. Never saved.
	item_moves:      [dynamic]Item_Move,
	// The cells attached to the player's scene (the active scene's full-detail cells; the warm
	// exterior kept behind an interior does not count), each with its scripted refs. The tick's
	// transition step keeps it; Is3DLoaded reads it. Never saved.
	attached:        map[Form_ID][dynamic]Form_ID,
}

// Update_Timers is one form's OnUpdate registrations, as real seconds left until each fires. The
// single and the repeating one are independent, and registering again replaces that kind (Papyrus).
// A registration belongs to the form: its OnUpdate goes to every script on it.
Update_Timers :: struct {
	single:    f32, // seconds until the single update (single_on)
	repeat:    f32, // seconds until the next repeating update (repeat_on)
	interval:  f32, // the repeating update's period
	single_on: bool,
	repeat_on: bool,
}

// Activation is one request to activate `target` by `by`. `default_only` skips OnActivate and ignores
// BlockActivation (Papyrus abDefaultProcessingOnly).
Activation :: struct {
	target, by:   Form_ID,
	default_only: bool,
}

// Item_Move is `count` of `base` leaving `from` for `to`; 0 is the world (or destroyed). `ref` is the
// moved reference, 0 when the items are not one.
Item_Move :: struct {
	base, ref, from, to: Form_ID,
	count:               i32,
}

init :: proc(ws: ^World_State) {
	ws.ref_deltas = make(map[Form_ID]Ref_Delta)
	ws.by_cell = make(map[Form_ID][dynamic]Form_ID)
	ws.created = make(map[Form_ID]Created_Ref)
	ws.created_by_cell = make(map[Form_ID][dynamic]Form_ID)
	ws.next_created = CREATED_FORM_BASE
	ws.globals = make(map[Form_ID]f32)
	ws.quests = make(map[Form_ID]Quest_State)
	ws.inventories = make(map[Form_ID]map[Form_ID]i32)
	ws.actor_values = make(map[Form_ID]map[string]f32)
	ws.factions = make(map[Form_ID]map[Form_ID]i32)
	ws.relationships = make(map[Form_ID]map[Form_ID]i32)
	ws.perks = make(map[Form_ID]map[Form_ID]bool)
	ws.updates = make(map[Form_ID]Update_Timers)
	ws.item_filters = make(map[Form_ID][dynamic]Form_ID)
	ws.aliases = make(map[Form_ID]Form_ID)
	ws.alias_holders = make(map[Form_ID][dynamic]Form_ID)
	ws.scene_dirty = make([dynamic]Form_ID)
	ws.activations = make([dynamic]Activation)
	ws.item_moves = make([dynamic]Item_Move)
	ws.attached = make(map[Form_ID][dynamic]Form_ID)
	ws.player.level = 1 // default until real leveling / save round-trip sets it
}

// player_level returns the player's character level (>=1). Real leveling + save round-trip land later;
// for now it's the default seeded in init (surfaced on the load screen).
player_level :: proc(ws: ^World_State) -> i32 {
	return max(ws.player.level, 1)
}

destroy :: proc(ws: ^World_State) {
	for _, &list in ws.by_cell {
		delete(list)
	}
	for _, &list in ws.created_by_cell {
		delete(list)
	}
	free_stores(ws)
	delete(ws.by_cell)
	delete(ws.ref_deltas)
	delete(ws.created_by_cell)
	delete(ws.created)
	delete(ws.globals)
	delete(ws.quests)
	delete(ws.inventories)
	delete(ws.actor_values)
	delete(ws.factions)
	delete(ws.relationships)
	delete(ws.perks)
	delete(ws.updates)
	delete(ws.item_filters)
	delete(ws.aliases)
	delete(ws.alias_holders)
	delete(ws.scene_dirty)
	delete(ws.activations)
	delete(ws.item_moves)
	for _, &refs in ws.attached {
		delete(refs)
	}
	delete(ws.attached)
	ws^ = {}
}

// quest_free releases a Quest_State's owned nested maps (called on destroy/clear/load-replace).
@(private)
quest_free :: proc(q: ^Quest_State) {
	delete(q.done)
	delete(q.objectives)
}

// free_stores releases every store's owned nested maps + AV key strings, WITHOUT deleting/clearing the
// outer maps themselves — the shared teardown for both destroy (which then deletes the outers) and
// save.clear_overlay (which then clears them). Keeps the free logic in one place as stores are added.
@(private)
free_stores :: proc(ws: ^World_State) {
	for _, &q in ws.quests {
		quest_free(&q)
	}
	for _, &inner in ws.inventories {
		delete(inner)
	}
	for _, &inner in ws.actor_values {
		for k in inner {
			delete(k)
		}
		delete(inner)
	}
	for _, &inner in ws.factions {
		delete(inner)
	}
	for _, &inner in ws.relationships {
		delete(inner)
	}
	for _, &inner in ws.perks {
		delete(inner)
	}
	for _, &list in ws.item_filters {
		delete(list)
	}
	for _, &list in ws.alias_holders {
		delete(list)
	}
}

// mark_scene_dirty enqueues `form_id` for deferred live-apply. Called by writers that only touch the
// overlay (script natives) so the app's per-frame drain re-applies the change to the resident scene.
mark_scene_dirty :: proc(ws: ^World_State, form_id: Form_ID) {
	append(&ws.scene_dirty, form_id)
}

// register_update is RegisterForSingleUpdate / RegisterForUpdate: `form` gets OnUpdate after
// `seconds`, once or every `seconds`. A negative or zero interval fires at the next tick.
register_update :: proc(ws: ^World_State, form: Form_ID, seconds: f32, repeat: bool) {
	if form not_in ws.updates {ws.updates[form] = {}}
	u := &ws.updates[form]
	s := max(seconds, 0)
	if repeat {
		u.repeat, u.interval, u.repeat_on = s, s, true
	} else {
		u.single, u.single_on = s, true
	}
}

// unregister_updates is UnregisterForUpdate: both kinds stop.
unregister_updates :: proc(ws: ^World_State, form: Form_ID) {
	delete_key(&ws.updates, form)
}

// move_items records items moving for the next tick's inventory events.
move_items :: proc(ws: ^World_State, m: Item_Move) {
	append(&ws.item_moves, m)
}

// add_item_filter is AddInventoryEventFilter: filters stack.
add_item_filter :: proc(ws: ^World_State, container, filter: Form_ID) {
	if container not_in ws.item_filters {ws.item_filters[container] = make([dynamic]Form_ID)}
	append(&ws.item_filters[container], filter)
}

// remove_item_filter is RemoveInventoryEventFilter.
remove_item_filter :: proc(ws: ^World_State, container, filter: Form_ID) {
	list, ok := &ws.item_filters[container]
	if !ok {return}
	for i := len(list) - 1; i >= 0; i -= 1 {
		if list[i] == filter {ordered_remove(list, i)}
	}
	if len(list) == 0 {remove_item_filters(ws, container)}
}

// remove_item_filters is RemoveAllInventoryEventFilters.
remove_item_filters :: proc(ws: ^World_State, container: Form_ID) {
	if list, ok := ws.item_filters[container]; ok {delete(list)}
	delete_key(&ws.item_filters, container)
}

// fill_alias puts `form` in `alias`, replacing what it held.
fill_alias :: proc(ws: ^World_State, alias, form: Form_ID) {
	clear_alias(ws, alias)
	if form == 0 {return}
	ws.aliases[alias] = form
	if form not_in ws.alias_holders {ws.alias_holders[form] = make([dynamic]Form_ID)}
	append(&ws.alias_holders[form], alias)
}

// clear_alias empties `alias`.
clear_alias :: proc(ws: ^World_State, alias: Form_ID) {
	form, ok := ws.aliases[alias]
	if !ok {return}
	delete_key(&ws.aliases, alias)
	list := &ws.alias_holders[form]
	for a, i in list {
		if a == alias {
			unordered_remove(list, i)
			break
		}
	}
	if len(list) == 0 {
		delete(list^)
		delete_key(&ws.alias_holders, form)
	}
}

// request_activation queues a script's Activate for the app's next tick.
request_activation :: proc(ws: ^World_State, target, by: Form_ID, default_only: bool) {
	append(&ws.activations, Activation{target, by, default_only})
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

// set_activation_blocked records BlockActivation: while set, activating the ref only sends its
// scripts OnActivate; the engine's default action (open, take, talk) does not run.
set_activation_blocked :: proc(ws: ^World_State, form_id, cell: Form_ID, blocked: bool) {
	if blocked {
		upsert(ws, form_id, cell).live += {.Activation_Blocked}
	} else if d, ok := &ws.ref_deltas[form_id]; ok {
		d.live -= {.Activation_Blocked}
	}
}

// activation_blocked reports whether a script blocked the ref's default activation.
activation_blocked :: proc(ws: ^World_State, form_id: Form_ID) -> bool {
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

// ── quest store (docs/scripting-natives.md §B — the highest-leverage new store) ────────────────
// The natives (script/natives_quest.odin) route every quest mutation through these typed procs so
// worldstate owns the store's invariants (nested-map init, objective bit flips), mirroring the ref
// verbs. Reads that need the whole struct take the non-creating pointer via quest_get.

// quest_upsert returns a mutable Quest_State for `quest`, creating + initialising its nested maps on
// first sight. The pointer is valid until the next quests insert — writers use it immediately.
@(private)
quest_upsert :: proc(ws: ^World_State, quest: Form_ID) -> ^Quest_State {
	if _, existed := ws.quests[quest]; !existed {
		ws.quests[quest] = Quest_State {
			done       = make(map[u16]bool),
			objectives = make(map[u16]Objective_State),
		}
	}
	return &ws.quests[quest]
}

// quest_get returns a (read) pointer to a quest's state without creating one (ok=false if untouched).
quest_get :: proc(ws: ^World_State, quest: Form_ID) -> (^Quest_State, bool) {
	q, ok := &ws.quests[quest]
	return q, ok
}

// quest_set_stage records the current stage + marks it done. It does NOT change run-state — Papyrus
// SetCurrentStageID advances a RUNNING quest but doesn't start one (the native gates on running).
quest_set_stage :: proc(ws: ^World_State, quest: Form_ID, stage: u16) {
	q := quest_upsert(ws, quest)
	q.stage = stage
	q.done[stage] = true
}

// quest_set_running is the explicit Start/Stop — it sets running AND running_set, so IsRunning now
// reads this value instead of deferring to the baseline Start-Game-Enabled flag.
quest_set_running :: proc(ws: ^World_State, quest: Form_ID, running: bool) {
	q := quest_upsert(ws, quest)
	q.running = running
	q.running_set = true
	if running {q.started = true}
}

quest_set_active :: proc(ws: ^World_State, quest: Form_ID, active: bool) {
	quest_upsert(ws, quest).active = active
}

quest_set_completed :: proc(ws: ^World_State, quest: Form_ID, completed: bool) {
	quest_upsert(ws, quest).completed = completed
}

// quest_set_objective flips one flag of one objective on/off (leaving the objective's other flags).
quest_set_objective :: proc(ws: ^World_State, quest: Form_ID, obj: u16, flag: Objective_Flag, on: bool) {
	q := quest_upsert(ws, quest)
	s := q.objectives[obj]
	if on {s += {flag}} else {s -= {flag}}
	q.objectives[obj] = s
}

// quest_set_all_objectives applies `flag` to EVERY objective the quest has touched (Complete/Fail-all).
// It can only reach objectives already in the map — objectives a script never referenced are unknown
// to the overlay (the ESM objective list isn't indexed yet).
quest_set_all_objectives :: proc(ws: ^World_State, quest: Form_ID, flag: Objective_Flag) {
	q, ok := quest_get(ws, quest)
	if !ok {return}
	for obj, s in q.objectives {
		q.objectives[obj] = s + {flag}
	}
}

// quest_reset clears a quest's runtime state back to baseline (stage 0, no done stages/objectives,
// stopped) — Papyrus Reset re-initialises the quest. Keeps the entry (empty) so nested maps persist.
quest_reset :: proc(ws: ^World_State, quest: Form_ID) {
	q := quest_upsert(ws, quest)
	clear(&q.done)
	clear(&q.objectives)
	q.stage = 0
	q.running = false
	q.running_set = true // Reset explicitly stops the quest — an override of the baseline, not a defer
	q.started = false
	q.active = false
	q.completed = false
}

// quest_stage / quest_is_stage_done / quest_objective are the read helpers (overlay only — baseline
// quest state isn't indexed yet, so an untouched quest reads as stage 0 / not-done / no flags).
// Papyrus GetCurrentStageID is the HIGHEST completed stage, not the last one set — so we return the
// max over the done-set (a quest set to 40 then 20 reports 40). `q.stage` keeps the raw last-set value.
quest_stage :: proc(ws: ^World_State, quest: Form_ID) -> u16 {
	q, ok := quest_get(ws, quest)
	if !ok {return 0}
	highest: u16
	for stage in q.done {
		if stage > highest {highest = stage}
	}
	return highest
}

// quest_last_stage returns the RAW last-set stage — the argument of the most recent SetCurrentStageID,
// even if a later call set a LOWER one — as opposed to quest_stage's highest-completed. 0 if untouched.
// A skymod extension: vanilla Papyrus only exposes the highest (GetCurrentStageID).
quest_last_stage :: proc(ws: ^World_State, quest: Form_ID) -> u16 {
	if q, ok := quest_get(ws, quest); ok {return q.stage}
	return 0
}

quest_is_stage_done :: proc(ws: ^World_State, quest: Form_ID, stage: u16) -> bool {
	if q, ok := quest_get(ws, quest); ok {return q.done[stage]}
	return false
}

quest_objective :: proc(ws: ^World_State, quest: Form_ID, obj: u16) -> Objective_State {
	if q, ok := quest_get(ws, quest); ok {return q.objectives[obj]}
	return {}
}

// ── inventory store (owner FormID -> item FormID -> count) ─────────────────────────────────────
// Overlay-only: the ESM baseline container/NPC contents aren't indexed, so counts are DELTAS from the
// baseline (a fresh game reads 0 for everything). A baseline-inventory index later makes these absolute.

@(private)
inv_upsert :: proc(ws: ^World_State, owner: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.inventories[owner]; !ok {
		ws.inventories[owner] = make(map[Form_ID]i32)
	}
	return &ws.inventories[owner]
}

// inv_add adjusts owner's count of `item` by `delta` (negative removes); the entry is dropped at or
// below 0 (can't hold a negative count). AddItem/RemoveItem both route here.
inv_add :: proc(ws: ^World_State, owner, item: Form_ID, delta: i32) {
	inner := inv_upsert(ws, owner)
	n := inner^[item] + delta
	if n <= 0 {
		delete_key(inner, item)
	} else {
		inner^[item] = n
	}
}

// inv_count returns owner's count of item (0 if none / owner untouched).
inv_count :: proc(ws: ^World_State, owner, item: Form_ID) -> i32 {
	if inner, ok := ws.inventories[owner]; ok {
		return inner[item]
	}
	return 0
}

// HOLE(records, gap): the ESM baseline contents of a container are never indexed, so every inventory count here is a DELTA from an unknown start. GetItemCount reads 0 on a fresh game for a chest that is visibly full.
// inv_clear empties owner's inventory overlay (RemoveAllItems' local half).
inv_clear :: proc(ws: ^World_State, owner: Form_ID) {
	if inner, ok := &ws.inventories[owner]; ok {
		clear(inner)
	}
}

// ── actor-value store (actor -> AV name -> value) ──────────────────────────────────────────────
// AV names are case-insensitive → keys are lowercased + owned by the store. Overlay-only: base AV
// defaults (ActorBase) aren't indexed, so an unset AV reads 0 and GetBaseActorValue == the stored
// value (no base/current split yet — that arrives with the actor phase).

@(private)
av_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[string]f32 {
	if _, ok := ws.actor_values[actor]; !ok {
		ws.actor_values[actor] = make(map[string]f32)
	}
	return &ws.actor_values[actor]
}

// av_set stores `value` for actor's AV `name` (case-folded); clones the key on first insert (the
// existing owned key is kept + reused on overwrite, since string map keys compare by content).
av_set :: proc(ws: ^World_State, actor: Form_ID, name: string, value: f32) {
	inner := av_upsert(ws, actor)
	key := strings.to_lower(name, context.temp_allocator)
	if _, ok := inner^[key]; ok {
		inner^[key] = value
	} else {
		inner^[strings.clone(key)] = value
	}
}

// av_get returns actor's AV value (ok=false if unset).
av_get :: proc(ws: ^World_State, actor: Form_ID, name: string) -> (f32, bool) {
	if inner, ok := ws.actor_values[actor]; ok {
		key := strings.to_lower(name, context.temp_allocator)
		if v, has := inner[key]; has {
			return v, true
		}
	}
	return 0, false
}

// av_mod adds `delta` to actor's AV (Mod/Damage/Restore all bottom out here).
av_mod :: proc(ws: ^World_State, actor: Form_ID, name: string, delta: f32) {
	cur, _ := av_get(ws, actor, name)
	av_set(ws, actor, name, cur + delta)
}

// ── faction membership/rank + relationship rank ────────────────────────────────────────────────
// Overlay-only: baseline faction memberships (NPC_/ACHR) + relationships aren't indexed, so these
// see only runtime changes; a non-member reads rank -1, an unset relationship reads 0 (Acquaintance).

@(private)
faction_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.factions[actor]; !ok {
		ws.factions[actor] = make(map[Form_ID]i32)
	}
	return &ws.factions[actor]
}

// faction_set_rank sets actor's rank in faction — also the "add to faction" verb (membership =
// presence of the entry, so setting a rank adds the actor).
faction_set_rank :: proc(ws: ^World_State, actor, faction: Form_ID, rank: i32) {
	inner := faction_upsert(ws, actor)
	inner^[faction] = rank
}

// faction_rank returns (rank, member?). A non-member's rank is meaningless (callers use -1).
faction_rank :: proc(ws: ^World_State, actor, faction: Form_ID) -> (i32, bool) {
	if inner, ok := ws.factions[actor]; ok {
		if r, has := inner[faction]; has {
			return r, true
		}
	}
	return 0, false
}

faction_remove :: proc(ws: ^World_State, actor, faction: Form_ID) {
	if inner, ok := &ws.factions[actor]; ok {
		delete_key(inner, faction)
	}
}

faction_remove_all :: proc(ws: ^World_State, actor: Form_ID) {
	if inner, ok := &ws.factions[actor]; ok {
		clear(inner)
	}
}

// ── perk store (actor FormID -> the perks it has taken) ────────────────────────────────────────
// Overlay-only, and the whole truth: a perk is never baseline data. An NPC_ gets its perks from its
// PERK entries at load and the player takes them at the stats menu, so presence in this set IS
// having the perk. Backs Actor.AddPerk / HasPerk / RemovePerk and CTDA function 448.

@(private)
perk_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]bool {
	if _, ok := ws.perks[actor]; !ok {
		ws.perks[actor] = make(map[Form_ID]bool)
	}
	return &ws.perks[actor]
}

// perk_add gives actor a perk. Taking a perk twice is a no-op, not a second rank — Skyrim models
// ranks as separate PERK records linked by NNAM, so rank 2 is its own form.
perk_add :: proc(ws: ^World_State, actor, perk: Form_ID) {
	inner := perk_upsert(ws, actor)
	inner^[perk] = true
}

// perk_has reports whether actor has taken perk.
perk_has :: proc(ws: ^World_State, actor, perk: Form_ID) -> bool {
	if inner, ok := ws.perks[actor]; ok {
		return inner[perk]
	}
	return false
}

perk_remove :: proc(ws: ^World_State, actor, perk: Form_ID) {
	if inner, ok := &ws.perks[actor]; ok {
		delete_key(inner, perk)
	}
}

@(private)
rel_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.relationships[actor]; !ok {
		ws.relationships[actor] = make(map[Form_ID]i32)
	}
	return &ws.relationships[actor]
}

// rel_set stores the relationship rank for the (a,b) pair. Skyrim relationships are symmetric (one
// RELA record per pair), so we mirror it both ways → GetRelationshipRank works from either actor.
rel_set :: proc(ws: ^World_State, a, b: Form_ID, rank: i32) {
	ia := rel_upsert(ws, a)
	ia^[b] = rank
	ib := rel_upsert(ws, b)
	ib^[a] = rank
}

// rel_rank returns a's relationship rank toward b (0 = Acquaintance/neutral if unset).
rel_rank :: proc(ws: ^World_State, a, b: Form_ID) -> i32 {
	if inner, ok := ws.relationships[a]; ok {
		return inner[b]
	}
	return 0
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
