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
//
// Files: refs (per-ref deltas, created refs), quests, actors (inventory, AVs, factions,
// relationships, perks), scripts (script-runtime state), save ((de)serialises the Overlay).

import "../formid"

// Form_ID is the global form handle (= gamedb.Form_ID = u64): (slot<<32)|local. Kept as a local
// alias so worldstate stays independent of gamedb; both resolve to u64, so handles pass freely.
Form_ID :: u64

// HOLE(world, blocker): no game clock — nothing tracks the in-game hour or date. There is no day/night, no schedule for a package to follow, and GameHour and GetCurrentGameTime (GameDaysPassed) stand still at their authored values.

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

// World_State is the overlay a save holds plus the session state a load leaves alone.
World_State :: struct {
	using overlay: Overlay,
	using runtime: Runtime,
}

// Overlay is what diverges from a fresh game (§4.1), and the indexes rebuilt from it: a sparse
// FormID→delta map + per-cell index (patches to EXISTING ESM refs), the created-ref space, the
// coarse stores and the player. A new game is all zero; a load replaces it whole.
Overlay :: struct {
	ref_deltas:      map[Form_ID]Ref_Delta,       // FormID -> delta (the ChangeForm-equivalent table)
	by_cell:         map[Form_ID][dynamic]Form_ID,     // CellFormID -> FormIDs with deltas (patch index)
	created:         map[Form_ID]Created_Ref,      // FormID (0xFF space) -> runtime-spawned ref
	created_by_cell: map[Form_ID][dynamic]Form_ID,     // CellFormID -> created FormIDs to spawn (stream index)
	next_created:    Form_ID,                      // next FormID to hand out (>= formid.CREATED_FORM_BASE)
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
	script_state:    map[Form_ID][dynamic]Script_Var, // form -> its scripts' changed members; presence = their OnInit ran
	list_adds:       map[Form_ID][dynamic]Form_ID, // FLST -> forms FormList.AddForm put after its authored members
	keyword_data:    map[Keyword_Key]f32,          // Location.SetKeywordData values; absent reads 0
	player:          Player_State,             // the player singleton (position/facing; stats later)
}

// Runtime is per-session state: queues the tick drains and the attached cells. Never saved.
Runtime :: struct {
	// Deferred scene-apply queue (docs/script-runtime-decisions.md §3): writers that DON'T touch the
	// live scene themselves (script natives) append the form they changed here; the app drains it at
	// one fixed frame point and re-applies each to the resident scene. The world's own *_ref verbs
	// apply live at call time and DON'T enqueue. Ordered; a form may repeat (drain is idempotent).
	scene_dirty:     [dynamic]Form_ID,
	// Activations a script requested (ObjectReference.Activate). The app runs them at the next tick,
	// through the same path as the player's Activate key, and clears the list.
	activations:     [dynamic]Activation,
	// Items scripts moved since the last tick; the tick sends their inventory events.
	item_moves:      [dynamic]Item_Move,
	// The cells attached to the player's scene (the active scene's full-detail cells; the warm
	// exterior kept behind an interior does not count), each with its scripted refs. The tick's
	// transition step keeps it; Is3DLoaded reads it.
	attached:        map[Form_ID][dynamic]Form_ID,
	// Where the player stands this tick: the interior or exterior grid cell under them (0 = not placed,
	// as in a headless run). The app writes it before the script phase.
	player_at:       Placement,
}

Placement :: struct {
	cell: Form_ID,
	pos:  [3]f32,
}

Keyword_Key :: struct {
	location, keyword: Form_ID,
}

init :: proc(ws: ^World_State) {
	init_overlay(&ws.overlay)
	ws.scene_dirty = make([dynamic]Form_ID)
	ws.activations = make([dynamic]Activation)
	ws.item_moves = make([dynamic]Item_Move)
	ws.attached = make(map[Form_ID][dynamic]Form_ID)
}

destroy :: proc(ws: ^World_State) {
	destroy_overlay(&ws.overlay)
	delete(ws.scene_dirty)
	delete(ws.activations)
	delete(ws.item_moves)
	for _, &refs in ws.attached {
		delete(refs)
	}
	delete(ws.attached)
	ws^ = {}
}

init_overlay :: proc(o: ^Overlay) {
	o.ref_deltas = make(map[Form_ID]Ref_Delta)
	o.by_cell = make(map[Form_ID][dynamic]Form_ID)
	o.created = make(map[Form_ID]Created_Ref)
	o.created_by_cell = make(map[Form_ID][dynamic]Form_ID)
	o.next_created = formid.CREATED_FORM_BASE
	o.globals = make(map[Form_ID]f32)
	o.quests = make(map[Form_ID]Quest_State)
	o.inventories = make(map[Form_ID]map[Form_ID]i32)
	o.actor_values = make(map[Form_ID]map[string]f32)
	o.factions = make(map[Form_ID]map[Form_ID]i32)
	o.relationships = make(map[Form_ID]map[Form_ID]i32)
	o.perks = make(map[Form_ID]map[Form_ID]bool)
	o.updates = make(map[Form_ID]Update_Timers)
	o.item_filters = make(map[Form_ID][dynamic]Form_ID)
	o.aliases = make(map[Form_ID]Form_ID)
	o.alias_holders = make(map[Form_ID][dynamic]Form_ID)
	o.script_state = make(map[Form_ID][dynamic]Script_Var)
	o.list_adds = make(map[Form_ID][dynamic]Form_ID)
	o.keyword_data = make(map[Keyword_Key]f32)
	o.player.level = 1 // default until real leveling / save round-trip sets it
}

// destroy_overlay frees every store with what it owns; init_overlay after it gives a fresh game.
destroy_overlay :: proc(o: ^Overlay) {
	for _, &list in o.by_cell {delete(list)}
	for _, &list in o.created_by_cell {delete(list)}
	for _, &q in o.quests {quest_free(&q)}
	for _, &inner in o.inventories {delete(inner)}
	for _, &inner in o.actor_values {
		for k in inner {delete(k)}
		delete(inner)
	}
	for _, &inner in o.factions {delete(inner)}
	for _, &inner in o.relationships {delete(inner)}
	for _, &inner in o.perks {delete(inner)}
	for _, &list in o.item_filters {delete(list)}
	for _, &list in o.alias_holders {delete(list)}
	for _, vars in o.script_state {free_script_vars(vars)}
	for _, &list in o.list_adds {delete(list)}
	delete(o.ref_deltas)
	delete(o.by_cell)
	delete(o.created)
	delete(o.created_by_cell)
	delete(o.globals)
	delete(o.quests)
	delete(o.inventories)
	delete(o.actor_values)
	delete(o.factions)
	delete(o.relationships)
	delete(o.perks)
	delete(o.updates)
	delete(o.item_filters)
	delete(o.aliases)
	delete(o.alias_holders)
	delete(o.script_state)
	delete(o.list_adds)
	delete(o.keyword_data)
	o^ = {}
}

// player_level returns the player's character level (>=1). Real leveling + save round-trip land later;
// for now it's the default seeded in init (surfaced on the load screen).
player_level :: proc(ws: ^World_State) -> i32 {
	return max(ws.player.level, 1)
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

// set_global / get_global: the coarse world-fact store (GLOB FormIDs, quest stages, script vars,
// timers). A plain id→value map — the simplest overlay category, but the one scripting leans on most.
set_global :: proc(ws: ^World_State, id: Form_ID, value: f32) {
	ws.globals[id] = value
}

get_global :: proc(ws: ^World_State, id: Form_ID) -> (f32, bool) {
	v, ok := ws.globals[id]
	return v, ok
}

// add_to_list is FormList.AddForm: a form already added stays once.
add_to_list :: proc(ws: ^World_State, list, form: Form_ID) {
	if list not_in ws.list_adds {ws.list_adds[list] = make([dynamic]Form_ID)}
	adds := &ws.list_adds[list]
	for f in adds {if f == form {return}}
	append(adds, form)
}

// remove_from_list is FormList.RemoveAddedForm: only added forms leave.
remove_from_list :: proc(ws: ^World_State, list, form: Form_ID) {
	adds, ok := &ws.list_adds[list]
	if !ok {return}
	for f, i in adds {
		if f == form {ordered_remove(adds, i);break}
	}
}

// revert_list is FormList.Revert: drops every added form.
revert_list :: proc(ws: ^World_State, list: Form_ID) {
	if adds, ok := ws.list_adds[list]; ok {delete(adds)}
	delete_key(&ws.list_adds, list)
}

list_added :: proc(ws: ^World_State, list: Form_ID) -> []Form_ID {
	if adds, ok := ws.list_adds[list]; ok {return adds[:]}
	return nil
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
