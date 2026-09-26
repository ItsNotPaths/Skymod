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
import "../formula"
import "../gamedb"

// Form_ID is the global form handle (= gamedb.Form_ID = u64): (slot<<32)|local.
Form_ID :: u64

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
	inventories:     Deltas,                       // owner FormID -> (item FormID -> count delta from baseline)
	spells:          Deltas,                       // actor -> (spell or shout -> GIVEN / REMOVED against its records' list)
	spell_seeds:     Deltas,                       // RACE or NPC_ -> (spell -> GIVEN / REMOVED): rt.seed_spell (not saved; OnGameLoaded rebuilds it)
	rolled:          map[Form_ID][dynamic]gamedb.Content_Entry, // owner -> its starting contents with leveled entries rolled
	zone_levels:     map[Form_ID]i32,              // ECZN -> the level it took on the first ask
	actor_picks:     map[Form_ID]Form_ID,          // leveled actor ref -> the NPC_ its LVLN rolled (0 = none)
	outfits:         map[Form_ID]Form_ID,          // actor or NPC_ -> the OTFT a script set (SetOutfit), over its records'
	carried:         map[Form_ID]Form_ID,          // item ref taken into a container -> that container
	equipment:       map[Form_ID]Equipment,        // actor -> what it wears and holds; absent = not read yet
	zone_ranges:     map[Form_ID][2]i32,           // ECZN -> the min and max level a script set
	formulas:        [Formula_Name]formula.Formula, // the named formulas, mods' replacements included (not saved)
	level_choices:   map[string]Level_Choice,      // level-up choice name -> its changes (not saved; defaults + mods)
	levels:          map[Form_ID]Level_State,      // actor -> its leveling: level, XP, perk points
	level_listeners: map[Form_ID]bool,             // forms registered for OnLevelUp
	zone_listeners:  map[Form_ID]bool,             // forms registered for OnZoneLevelSet
	actor_values:    map[Form_ID]map[string]Actor_Value, // actor -> AV name -> its parts
	mod_avs:         map[string]Mod_AV,            // lower-case name -> a mod AV this game created (not saved; OnGameLoaded rebuilds it)
	pending_avs:     [dynamic]Saved_AV,            // loaded values of names no mod has created yet (not saved)
	factions:        map[Form_ID]map[Form_ID]i32,  // actor FormID -> (faction FormID -> rank); presence = membership
	relationships:   map[Form_ID]map[Form_ID]i32,  // actor FormID -> (other actor FormID -> relationship rank)
	perks:           Deltas,                       // actor -> (perk -> GIVEN / REMOVED against its records' PRKR)
	updates:         map[Form_ID]Update_Timers,    // form -> its OnUpdate registrations (the scheduler's timers)
	game_updates:    map[Form_ID]Update_Timers,    // form -> its OnUpdateGameTime registrations, in game hours
	item_filters:    map[Form_ID][dynamic]Form_ID, // container -> AddInventoryEventFilter forms; absent = every item passes
	aliases:         map[Form_ID]Form_ID,          // alias handle -> the form filling it; absent = empty
	alias_holders:   map[Form_ID][dynamic]Form_ID, // form -> the aliases it fills (the reverse of aliases; not saved)
	script_state:    map[Form_ID][dynamic]Script_Var, // form -> its scripts' changed members; presence = their OnInit ran
	list_adds:       map[Form_ID][dynamic]Form_ID, // FLST -> forms FormList.AddForm put after its authored members
	keyword_data:    map[Keyword_Key]f32,          // Location.SetKeywordData values; absent reads 0
	pending_moves:   map[Form_ID]Pending_Move,     // MoveToWhenUnloaded: ref -> the move that waits for both locations to unload
	anim_regs:       map[Form_ID][dynamic]Anim_Reg, // sender -> RegisterForAnimationEvent registrations on it
	effects:         map[Form_ID]Active_Effect,    // effect handle -> a scripted magic effect on a target
	next_effect:     u32,                          // the last effect handle's counter
	effects_on:      map[Form_ID][dynamic]Form_ID, // target -> its effect handles (the reverse of effects; not saved)
	clock:           Game_Clock,               // game time (clock.odin)
	cells:           map[Form_ID]Cell_State,       // cell -> its reset clock (reset.odin); absent = no reset pending
	cleared:         Form_Set,                     // locations cleared (Location.SetCleared)
	books_read:      Form_Set,                     // skill books the player has read (each teaches once)
	drops:           u32,                          // items dropped so far, which spreads them round the dropper (not saved)
	words:           Deltas,                       // actor -> word of power -> WORD_TAUGHT | WORD_UNLOCKED
	beast_form:      bool,                         // Game.SetBeastForm: the player is a werewolf or vampire lord now
	vampires:        Form_Set,                     // SendVampirismStateChanged(true)
	werewolves:      Form_Set,                     // SendLycanthropyStateChanged(true)
	restocks:        map[Form_ID]f64,              // vendor chest -> the game hour it last restocked
	quest_events:    map[Form_ID]Story_Event,      // running quest -> the story event that started it
	story_starts:    map[Form_ID]f64,              // quest -> the game hour the story manager last started it
	story_ran:       map[[2]Form_ID]bool,          // {quest node, quest} started this round (do all before repeating)
	alias_rounds:    map[[2]Form_ID]bool,          // {alias handle, ref or location} a searching fill took this round
	infos_said:      map[Speaker_Info]f64,         // {speaker, info} -> the game hour it was last said (dialogue.odin)
	random_said:     map[Speaker_Info]bool,        // Random infos said this round of their topic
	exclusive:       map[Form_ID]Form_ID,          // speaker -> the Exclusive branch it is in
	talked_to_pc:    Form_Set,                     // actors that have spoken to the player
	teammates:       Form_Set,                     // Actor.SetPlayerTeammate: followers
	no_pc_dialogue:  Form_Set,                     // Actor.AllowPCDialogue(false): will not talk to the player
	sneaking:        Form_Set,                     // actors in sneak mode (actors.odin)
	courier_waits:   [dynamic]Courier_Remove,      // Courier.RemoveRef calls waiting for the courier to stop talking
	scenes:          map[Form_ID]Scene_Run,        // scenes playing or waiting for their actors (scenes.odin)
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
	// Refs created and deleted since the VM last looked. It gives the new ones their scripts
	// (OnInit inside the native that made them) and drops the scripts of the gone ones.
	new_refs:        [dynamic]Form_ID,
	gone_refs:       [dynamic]Form_ID,
	// Refs a reset put back to baseline: the VM restarts their scripts and sends OnReset.
	reset_refs:      [dynamic]Form_ID,
	// Cells a reset changed: the app rebuilds their resident chunks from baseline and overlay.
	rebuild_cells:   [dynamic]Form_ID,
	// Effects started and ended since the VM last looked: it sends OnEffectStart / OnEffectFinish.
	new_effects:     [dynamic]Form_ID,
	ended_effects:   [dynamic]Form_ID,
	zone_level_sets: [dynamic]Form_ID, // zones that took their level since the VM last looked: OnZoneLevelSet
	equip_changes:   [dynamic]Equip_Change, // items on or off since the VM last looked: OnObject(Un)Equipped
	level_ups:       [dynamic]Level_Up,     // level-ups since the VM last looked: OnLevelUp
	deaths:          [dynamic]Death,        // deaths since the VM last looked: OnDying, OnDeath
	story_events:    [dynamic]Story_Event,  // engine events since the VM last looked: the story manager
	story_quests:    [dynamic]Form_ID,      // quests an event started since the VM last looked: their OnStory handler
	quest_steps:     [dynamic]Quest_Step,   // stages set and quests stopped since the VM last looked: their fragments run
	info_runs:       [dynamic]Info_Run,     // topic info fragments the dialogue asked for since the last tick
	talking:         Form_ID,               // the actor in dialogue with the player; 0 when none
	in_triggers:     Form_Set,              // trigger volumes the player is inside (script tick_triggers)
	effect_classes:  map[string]Effect_Class, // script class (lower case) -> its __effect formulas, compiled when it loads
	// The cells attached to the player's scene (the active scene's full-detail cells; the warm
	// exterior kept behind an interior does not count), each with its scripted refs. The tick's
	// transition step keeps it; Is3DLoaded reads it.
	attached:        map[Form_ID][dynamic]Form_ID,
	// Set while the script thread runs a script phase: only that thread may touch worldstate.
	script_phase:    bool,
}

// on_script_thread is true on the thread that runs script phases.
@(thread_local)
on_script_thread: bool

// assert_owner checks that the calling thread owns worldstate (script_phase).
assert_owner :: #force_inline proc(ws: ^World_State, loc := #caller_location) {
	when ODIN_DEBUG {assert(ws.script_phase == on_script_thread, "worldstate: touched by a thread that does not own it", loc)}
}

Keyword_Key :: struct {
	location, keyword: Form_ID,
}

init :: proc(ws: ^World_State) {
	init_overlay(&ws.overlay)
	ws.scene_dirty = make([dynamic]Form_ID)
	ws.activations = make([dynamic]Activation)
	ws.item_moves = make([dynamic]Item_Move)
	ws.new_refs = make([dynamic]Form_ID)
	ws.gone_refs = make([dynamic]Form_ID)
	ws.reset_refs = make([dynamic]Form_ID)
	ws.rebuild_cells = make([dynamic]Form_ID)
	ws.new_effects = make([dynamic]Form_ID)
	ws.ended_effects = make([dynamic]Form_ID)
	ws.attached = make(map[Form_ID][dynamic]Form_ID)
	ws.zone_level_sets = make([dynamic]Form_ID)
	ws.equip_changes = make([dynamic]Equip_Change)
	ws.level_ups = make([dynamic]Level_Up)
	ws.deaths = make([dynamic]Death)
	ws.story_events = make([dynamic]Story_Event)
	ws.story_quests = make([dynamic]Form_ID)
	ws.quest_steps = make([dynamic]Quest_Step)
	ws.info_runs = make([dynamic]Info_Run)
	ws.effect_classes = make(map[string]Effect_Class)
}

destroy :: proc(ws: ^World_State) {
	destroy_overlay(&ws.overlay)
	delete(ws.scene_dirty)
	delete(ws.activations)
	delete(ws.item_moves)
	delete(ws.new_refs)
	delete(ws.gone_refs)
	delete(ws.reset_refs)
	delete(ws.rebuild_cells)
	delete(ws.new_effects)
	delete(ws.ended_effects)
	delete(ws.zone_level_sets)
	delete(ws.equip_changes)
	for l in ws.level_ups {delete(l.choice)}
	delete(ws.level_ups)
	delete(ws.deaths)
	delete(ws.in_triggers)
	delete(ws.story_events)
	delete(ws.story_quests)
	delete(ws.quest_steps)
	delete(ws.info_runs)
	for k, &c in ws.effect_classes {
		delete(k)
		free_effect_class(&c)
	}
	delete(ws.effect_classes)
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
	o.inventories = make(Deltas)
	o.spells = make(Deltas)
	o.spell_seeds = make(Deltas)
	o.rolled = make(map[Form_ID][dynamic]gamedb.Content_Entry)
	o.zone_levels = make(map[Form_ID]i32)
	o.actor_picks = make(map[Form_ID]Form_ID)
	o.outfits = make(map[Form_ID]Form_ID)
	o.carried = make(map[Form_ID]Form_ID)
	init_formulas(o)
	init_level_choices(o)
	o.levels = make(map[Form_ID]Level_State)
	o.level_listeners = make(map[Form_ID]bool)
	o.equipment = make(map[Form_ID]Equipment)
	o.zone_ranges = make(map[Form_ID][2]i32)
	o.zone_listeners = make(map[Form_ID]bool)
	o.actor_values = make(map[Form_ID]map[string]Actor_Value)
	o.mod_avs = make(map[string]Mod_AV)
	o.pending_avs = make([dynamic]Saved_AV)
	o.factions = make(map[Form_ID]map[Form_ID]i32)
	o.relationships = make(map[Form_ID]map[Form_ID]i32)
	o.perks = make(Deltas)
	o.updates = make(map[Form_ID]Update_Timers)
	o.game_updates = make(map[Form_ID]Update_Timers)
	o.cells = make(map[Form_ID]Cell_State)
	o.cleared = make(Form_Set)
	o.books_read = make(Form_Set)
	o.words = make(Deltas)
	o.vampires = make(Form_Set)
	o.werewolves = make(Form_Set)
	o.restocks = make(map[Form_ID]f64)
	o.quest_events = make(map[Form_ID]Story_Event)
	o.story_starts = make(map[Form_ID]f64)
	o.story_ran = make(map[[2]Form_ID]bool)
	o.alias_rounds = make(map[[2]Form_ID]bool)
	o.infos_said = make(map[Speaker_Info]f64)
	o.random_said = make(map[Speaker_Info]bool)
	o.exclusive = make(map[Form_ID]Form_ID)
	o.talked_to_pc = make(Form_Set)
	o.teammates = make(Form_Set)
	o.no_pc_dialogue = make(Form_Set)
	o.sneaking = make(Form_Set)
	o.scenes = make(map[Form_ID]Scene_Run)
	o.item_filters = make(map[Form_ID][dynamic]Form_ID)
	o.aliases = make(map[Form_ID]Form_ID)
	o.alias_holders = make(map[Form_ID][dynamic]Form_ID)
	o.script_state = make(map[Form_ID][dynamic]Script_Var)
	o.list_adds = make(map[Form_ID][dynamic]Form_ID)
	o.keyword_data = make(map[Keyword_Key]f32)
	o.pending_moves = make(map[Form_ID]Pending_Move)
	o.anim_regs = make(map[Form_ID][dynamic]Anim_Reg)
	o.effects = make(map[Form_ID]Active_Effect)
	o.effects_on = make(map[Form_ID][dynamic]Form_ID)
}

// destroy_overlay frees every store with what it owns; init_overlay after it gives a fresh game.
destroy_overlay :: proc(o: ^Overlay) {
	for _, &list in o.by_cell {delete(list)}
	for _, &list in o.created_by_cell {delete(list)}
	for _, &q in o.quests {quest_free(&q)}
	for _, &list in o.rolled {delete(list)}
	for _, &inner in o.actor_values {delete(inner)}
	for k, m in o.mod_avs {delete(k); delete(m.name)}
	for a in o.pending_avs {delete(a.name)}
	for _, &inner in o.factions {delete(inner)}
	for _, &inner in o.relationships {delete(inner)}
	for _, &list in o.item_filters {delete(list)}
	for _, &list in o.alias_holders {delete(list)}
	for _, vars in o.script_state {free_script_vars(vars)}
	for _, &list in o.list_adds {delete(list)}
	for _, &list in o.anim_regs {
		for r in list {delete(r.event)}
		delete(list)
	}
	delete(o.ref_deltas)
	delete(o.by_cell)
	delete(o.created)
	delete(o.created_by_cell)
	delete(o.globals)
	delete(o.quests)
	free_deltas(&o.inventories)
	free_deltas(&o.spells)
	free_deltas(&o.spell_seeds)
	delete(o.rolled)
	delete(o.zone_levels)
	delete(o.actor_picks)
	delete(o.outfits)
	delete(o.carried)
	for &f in o.formulas {formula.destroy(&f)}
	free_choices(&o.level_choices)
	delete(o.levels)
	delete(o.level_listeners)
	for _, eq in o.equipment {delete(eq.worn)}
	delete(o.equipment)
	delete(o.zone_ranges)
	delete(o.zone_listeners)
	delete(o.actor_values)
	delete(o.mod_avs)
	delete(o.pending_avs)
	delete(o.factions)
	delete(o.relationships)
	free_deltas(&o.perks)
	delete(o.updates)
	delete(o.game_updates)
	delete(o.cells)
	delete(o.cleared)
	delete(o.books_read)
	free_deltas(&o.words)
	delete(o.vampires)
	delete(o.werewolves)
	delete(o.restocks)
	delete(o.quest_events)
	delete(o.story_starts)
	delete(o.story_ran)
	delete(o.alias_rounds)
	delete(o.infos_said)
	delete(o.random_said)
	delete(o.exclusive)
	delete(o.talked_to_pc)
	delete(o.teammates)
	delete(o.no_pc_dialogue)
	delete(o.sneaking)
	delete(o.courier_waits)
	free_scene_runs(&o.scenes)
	delete(o.scenes)
	delete(o.item_filters)
	delete(o.aliases)
	delete(o.alias_holders)
	delete(o.script_state)
	delete(o.list_adds)
	delete(o.keyword_data)
	delete(o.pending_moves)
	delete(o.anim_regs)
	delete(o.effects)
	for _, &list in o.effects_on {delete(list)}
	delete(o.effects_on)
	o^ = {}
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

// global_value is a global's value: a write, else its authored FLTV, else 0.
global_value :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) -> f32 {
	if v, ok := ws.globals[id]; ok {return v}
	v, _ := gamedb.global_value(db, id)
	return v
}

// add_to_list is FormList.AddForm: a form already added stays once.
// list_has is FormList.HasForm: an authored member or one a script added.
list_has :: proc(ws: ^World_State, db: ^gamedb.DB, list, form: Form_ID) -> bool {
	authored, _ := gamedb.form_list_of(db, list)
	for f in authored {if f == form {return true}}
	for f in list_added(ws, list) {if f == form {return true}}
	return false
}

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

// ── quest store (docs/scripting-natives.md §B — the highest-leverage new store) ────────────────
// The natives (script/natives_quest.odin) route every quest mutation through these typed procs so
// worldstate owns the store's invariants (nested-map init, objective bit flips), mirroring the ref
// verbs. Reads that need the whole struct take the non-creating pointer via quest_get.
