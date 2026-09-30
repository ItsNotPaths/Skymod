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

import "core:fmt"
import "../actorstate"
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
	player:          Form_ID,                      // the actor the player controls: what formid.PLAYER (0x14) means
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
	sleep_outfits:   map[Form_ID]Form_ID,          // actor or NPC_ -> the sleep OTFT a script set
	units:           map[Form_ID]Unit,             // item unit -> its data (items.odin)
	units_of:        map[Form_ID][dynamic]Form_ID, // holder -> the units it has (not saved; rebuilt)
	equipment:       map[Form_ID]Equipment,        // actor -> what it wears and holds; absent = not read yet
	zone_ranges:     map[Form_ID][2]i32,           // ECZN -> the min and max level a script set
	formulas:        [Formula_Name]formula.Formula, // the named formulas, mods' replacements included (not saved)
	stolen_marks:    map[Form_ID]bool,             // item -> whether a theft marks it, over the value rule: gold false, and mods' (ownership.odin; not saved)
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
	los_regs:        [dynamic]Los_Reg,             // RegisterForLOS and the single gain/lost registrations
	projectiles:     [dynamic]Flight,              // projectiles that can still hit (projectiles.odin)
	zones:           map[Form_ID]Zone,             // zone ref -> a volume made at runtime (zones.odin)
	effects:         map[Form_ID]Active_Effect,    // effect handle -> a scripted magic effect on a target
	next_effect:     u32,                          // the last effect handle's counter
	visuals:         map[u32]Visual,               // visual handle -> an effect the graphics seam draws (visuals.odin)
	effects_on:      map[Form_ID][dynamic]Form_ID, // target -> its effect handles (the reverse of effects; not saved)
	clock:           Game_Clock,               // game time (clock.odin)
	difficulty:      Difficulty,               // the game difficulty, saved with the game
	weather:         Weather_State,            // the weather in force (weather.odin)
	weathers_offered: [dynamic]Form_ID,        // what the player's place offers, regions first (FindWeather; not saved)
	cells:           map[Form_ID]Cell_State,       // cell -> its reset clock (reset.odin); absent = no reset pending
	cleared:         Form_Set,                     // locations cleared (Location.SetCleared)
	books_read:      Form_Set,                     // skill books the player has read (each teaches once)
	drops:           u32,                          // items dropped so far, which spreads them round the dropper (not saved)
	words:           Deltas,                       // actor -> word of power -> WORD_TAUGHT | WORD_UNLOCKED
	beast_form:      bool,                         // Game.SetBeastForm: the player is a werewolf or vampire lord now
	camera:          Camera,                       // the player's point of view (camera.odin)
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
	states:          actorstate.Model,             // what each actor does with its body
	plugin_blobs:    map[string][]u8,              // native plugins' saved data by plugin ID, orphans too
	grounded:        Form_Set,                     // Actor.SetAllowFlying(false): may not fly
	destruction:     map[Form_ID]f32,              // destructible ref -> the damage it has taken (destruction.odin)
	deferred_kills:  Form_Set,                     // StartDeferredKill: it does not die at 0 Health until EndDeferredKill
	causes:          map[Form_ID]Form_ID,          // SetActorCause: ref -> the actor its hits count as
	dont_move:       Form_Set,                     // Actor.SetDontMove: stands (ai_link.odin)
	restrained:      Form_Set,                     // Actor.SetRestrained: stands
	actor_flags:     map[Form_ID]Flag_Override,    // actor or NPC_ -> ACBS bits a script set: ghost, essential, protected, invulnerable
	owners:          map[Form_ID]Form_ID,          // ref or cell -> the owner a script set; 0 = none (ownership.odin)
	crime_factions:  map[Form_ID]Form_ID,          // actor -> the crime faction a script set; 0 = none (crime.odin)
	faction_relations: map[[2]Form_ID]gamedb.Faction_Relation, // {faction, other} -> a script's relation (factions.odin)
	script_factions: map[Form_ID]Script_Faction,  // the factions scripts made (factions.odin)
	crime_victims:   map[[2]Form_ID]bool,          // {victim, offender}: a crime it has not paid for (IsActorAVictim; crime.odin)
	friend_hits:     map[[2]Form_ID]i32,           // {victim, attacker}: hits a friend let go (friend_hit)
	days_jailed:     map[Form_ID]i32,              // actor -> days it has served in all (GetDaysInJail; crime.odin)
	wanted:          map[[2]Form_ID]Wanted,        // {offender, crime faction} -> the faction-wide bounty (crime.odin)
	known_bounties:  map[[2]Form_ID]Known_Bounty,  // {knower, offender} -> a bounty only the knower holds (crime.odin)
	victim_waits:    [dynamic]Victim_Wait,         // victims about to turn witness (crime.odin)
	jailed:          map[Form_ID]Jailed,           // actors serving a sentence (crime.odin)
	jail_orders:     [dynamic]Jail_Order,          // moves into and out of jail for the app; not saved
	crime_members:   map[Form_ID][dynamic]Form_ID, // crime faction -> the actors in it; a cache, not saved (crime_census)
	spread_in:       f32,                          // seconds to the next bounty spread; not saved
	crime_members_built: int,                      // len(created) + 1 when crime_members was built; 0 = stale
	unreported:      Form_Set,                     // offenders whose crimes nobody reports (SetPlayerReportCrime)
	killers:         map[Form_ID]Form_ID,          // dead actor -> Actor.Kill's akKiller
	display_names:   map[Form_ID]string,           // ref -> the name an alias gave it (owned)
	courier_waits:   [dynamic]Courier_Remove,      // Courier.RemoveRef calls waiting for the courier to stop talking
	scenes:          map[Form_ID]Scene_Run,        // scenes playing or waiting for their actors (scenes.odin)
	packages_done:   map[[2]Form_ID]f64,           // {actor, OncePerDay package} -> the game hour it finished (ai_link.odin)
	awareness:       map[[2]Form_ID]Awareness,     // {viewer, target} -> what the viewer knows of it (awareness.odin)
}

// Runtime is per-session state: queues the tick drains and the attached cells. Never saved.
Runtime :: struct {
	next_visual:     u32, // the last visual handle; a load does not reset it, so a handle is never reused
	// Deferred scene-apply queue (docs/script-runtime-decisions.md §3): writers that DON'T touch the
	// live scene themselves (script natives) append the form they changed here; the app drains it at
	// one fixed frame point and re-applies each to the resident scene. The world's own *_ref verbs
	// apply live at call time and DON'T enqueue. Ordered; a form may repeat (drain is idempotent).
	scene_dirty:     [dynamic]Form_ID,
	// Activations a script requested (ObjectReference.Activate). The app runs them at the next tick,
	// through the same path as the player's Activate key, and clears the list.
	activations:     [dynamic]Activation,
	fires:           [dynamic]Fire, // Weapon.Fire calls for the app to launch
	swings:          [dynamic]Swing, // weapon swings for the app to land
	launches:        [dynamic]Spell_Launch, // spells cast at a target, for the app to give bodies
	critical:        map[Form_ID]Critical, // SetCriticalStage and AttachAshPile (not saved: a death in progress)
	destruction_changes: [dynamic]Destruction_Change, // stages refs entered since the last tick, for their event
	// Items scripts moved since the last tick; the tick sends their inventory events.
	item_moves:      [dynamic]Item_Move,
	// Refs created and deleted since the VM last looked. It gives the new ones their scripts
	// (OnInit inside the native that made them) and drops the scripts of the gone ones.
	new_refs:        [dynamic]Form_ID,
	gone_refs:       [dynamic]Form_ID,
	// Refs whose attached cell may have changed since the last tick: moved, or taken by an alias.
	refiles:         [dynamic]Refile,
	// Refs a reset put back to baseline: the VM restarts their scripts and sends OnReset.
	// Quests likewise: the VM restarts their and their aliases' scripts, OnInit included.
	reset_quests:    [dynamic]Form_ID,
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
	hits:            [dynamic]Hit,          // hits since the VM last looked: OnHit
	casts:           [dynamic]Spell_Cast,   // casts since the VM last looked: OnSpellCast
	struck:          map[Form_ID]Form_ID,   // victim -> who last hit it, until its combat looks (projectiles.odin); not saved
	alarmed:         map[Form_ID]Form_ID,   // actor -> whom it fights or confronts, as the AI set it (GetAlarmed); not saved
	trespass_warnings: map[[2]Form_ID]Trespass_Warning, // {warner, trespasser} -> its warnings so far (crime.odin); not saved
	arresting:       map[Form_ID]Form_ID,   // guard -> the actor it arrests, as the AI set it (GetArrestingActor); not saved
	warn_tick:       u64,                   // counts crime ticks, to end warnings nobody runs (crime.odin)
	story_events:    [dynamic]Story_Event,  // engine events since the VM last looked: the story manager
	story_quests:    [dynamic]Form_ID,      // quests an event started since the VM last looked: their OnStory handler
	quest_steps:     [dynamic]Quest_Step,   // stages set and quests stopped since the VM last looked: their fragments run
	info_runs:       [dynamic]Info_Run,     // topic info fragments the dialogue asked for since the last tick
	talking:         Form_ID,               // the actor in dialogue with the player; 0 when none
	force_greet:     Force_Greet,           // an NPC asking to talk to the player; 0 speaker when none
	barks:           [dynamic]Bark,         // lines said outside conversations and scenes
	notes:           [dynamic]Note,         // notifications, oldest first (hud.odin); not saved
	foe:             Foe,                   // the actor the player last hit (hud.odin); not saved
	noises:          [dynamic]Noise,        // sounds since detection last listened (awareness.odin); not saved
	asks:            [dynamic]Ask,          // message boxes asked for, oldest first (asks.odin); not saved
	answers:         map[Form_ID]i32,       // message -> the button picked on its last box; not saved
	ai:              AI_Link,               // script asks of the AI, and what it publishes
	regen:           Regen_Turns,           // whose turn it is to regenerate outside the loaded cells (av_regen)
	in_triggers:     map[[2]Form_ID]bool,   // {trigger volume, actor inside it} (script tick_triggers)
	zone_waits:      map[[2]Form_ID]f32,    // {zone, actor inside it} -> seconds until the zone casts on it again; not saved
	effect_classes:  map[string]Effect_Class, // script class (lower case) -> its __effect formulas, compiled when it loads
	effect_terms:    map[Form_ID][]Effect_Term, // MGEF -> its classes' terms, until a class loads (effects.odin)
	effect_defs:     map[Form_ID]Effect_Def,   // form -> the effect content defined (effect_defs.odin)
	hooks:           Hooks,                    // landing and cost hooks; the VM sets them
	spell_defs:      map[Form_ID]Spell_Def,    // form -> the spell content defined (spell_defs.odin)
	power_defs:      map[Form_ID]Power_Def,    // form -> the power or shout content defined (power_defs.odin)
	item_defs:       map[Form_ID]Item_Def,     // item -> what content says using it does (item_defs.odin)
	tags:            map[Form_ID][]string,     // form -> the tags content gave it (tags.odin)
	summing:         [dynamic]AV_Sum,          // the actor values av_live is summing, innermost last
	loop_warned:     map[string]bool,          // actor values whose read loop was warned about (av_live)
	// The cells attached to the player's scene (the active scene's full-detail cells; the warm
	// exterior kept behind an interior does not count), each with its scripted refs. The tick's
	// transition step keeps it; Is3DLoaded reads it.
	attached:        map[Form_ID][dynamic]Form_ID,
}

// sim_depth counts the sim contexts this thread is inside: the sim thread's life, a park, setup.
// Code outside all of them must not touch worldstate.
@(thread_local)
sim_depth: int

sim_enter :: proc() {sim_depth += 1}
sim_leave :: proc() {sim_depth -= 1}

// assert_owner checks that the calling thread owns worldstate.
assert_owner :: #force_inline proc(ws: ^World_State, loc := #caller_location) {
	when ODIN_DEBUG {
		assert(sim_depth > 0, "worldstate: touched outside the sim", loc)
	}
}

Keyword_Key :: struct {
	location, keyword: Form_ID,
}

// Difficulty is the game difficulty; Adept is the zero value, so a save without one reads Adept.
Difficulty :: enum i8 {
	Novice     = -2,
	Apprentice = -1,
	Adept      = 0,
	Expert     = 1,
	Master     = 2,
	Legendary  = 3,
}

// (hole difficulty-setting :tags (ui player) :sev gap) nothing calls set_difficulty: no menu picks the game difficulty, so every game plays at Adept.
set_difficulty :: proc(ws: ^World_State, d: Difficulty) {
	ws.difficulty = d
}

init :: proc(ws: ^World_State) {
	init_overlay(&ws.overlay)
	ws.scene_dirty = make([dynamic]Form_ID)
	ws.activations = make([dynamic]Activation)
	ws.fires = make([dynamic]Fire)
	ws.swings = make([dynamic]Swing)
	ws.launches = make([dynamic]Spell_Launch)
	ws.critical = make(map[Form_ID]Critical)
	ws.destruction_changes = make([dynamic]Destruction_Change)
	ws.item_moves = make([dynamic]Item_Move)
	ws.new_refs = make([dynamic]Form_ID)
	ws.gone_refs = make([dynamic]Form_ID)
	ws.refiles = make([dynamic]Refile)
	ws.reset_refs = make([dynamic]Form_ID)
	ws.reset_quests = make([dynamic]Form_ID)
	ws.rebuild_cells = make([dynamic]Form_ID)
	ws.new_effects = make([dynamic]Form_ID)
	ws.ended_effects = make([dynamic]Form_ID)
	ws.attached = make(map[Form_ID][dynamic]Form_ID)
	ws.zone_level_sets = make([dynamic]Form_ID)
	ws.equip_changes = make([dynamic]Equip_Change)
	ws.level_ups = make([dynamic]Level_Up)
	ws.deaths = make([dynamic]Death)
	ws.hits = make([dynamic]Hit)
	ws.casts = make([dynamic]Spell_Cast)
	ws.struck = make(map[Form_ID]Form_ID)
	ws.alarmed = make(map[Form_ID]Form_ID)
	ws.trespass_warnings = make(map[[2]Form_ID]Trespass_Warning)
	ws.arresting = make(map[Form_ID]Form_ID)
	ws.story_events = make([dynamic]Story_Event)
	ws.barks = make([dynamic]Bark)
	ws.noises = make([dynamic]Noise)
	ws.story_quests = make([dynamic]Form_ID)
	ws.quest_steps = make([dynamic]Quest_Step)
	ws.info_runs = make([dynamic]Info_Run)
	ws.effect_classes = make(map[string]Effect_Class)
	ws.effect_terms = make(map[Form_ID][]Effect_Term)
}

destroy :: proc(ws: ^World_State) {
	destroy_overlay(&ws.overlay)
	delete(ws.scene_dirty)
	delete(ws.activations)
	delete(ws.fires)
	delete(ws.swings)
	delete(ws.launches)
	delete(ws.critical)
	delete(ws.destruction_changes)
	delete(ws.item_moves)
	delete(ws.new_refs)
	delete(ws.gone_refs)
	delete(ws.refiles)
	delete(ws.reset_refs)
	delete(ws.reset_quests)
	delete(ws.rebuild_cells)
	delete(ws.new_effects)
	delete(ws.ended_effects)
	delete(ws.zone_level_sets)
	delete(ws.equip_changes)
	for l in ws.level_ups {delete(l.choice)}
	delete(ws.level_ups)
	delete(ws.deaths)
	delete(ws.hits)
	delete(ws.casts)
	delete(ws.struck)
	delete(ws.alarmed)
	delete(ws.trespass_warnings)
	delete(ws.arresting)
	delete(ws.in_triggers)
	delete(ws.zone_waits)
	delete(ws.story_events)
	delete(ws.barks)
	destroy_notes(ws)
	delete(ws.noises)
	delete(ws.asks)
	delete(ws.answers)
	destroy_ai_link(&ws.ai)
	delete(ws.story_quests)
	delete(ws.quest_steps)
	delete(ws.info_runs)
	for k, &c in ws.effect_classes {
		delete(k)
		free_effect_class(&c)
	}
	delete(ws.effect_classes)
	forget_effect_terms(ws)
	delete(ws.effect_terms)
	delete(ws.summing)
	delete(ws.loop_warned)
	for _, d in ws.item_defs {delete(d.entries)}
	delete(ws.item_defs)
	for _, &d in ws.power_defs {free_power_def(&d)}
	delete(ws.power_defs)
	for _, &d in ws.spell_defs {free_spell_def(&d)}
	delete(ws.spell_defs)
	for _, &d in ws.effect_defs {free_effect_def(&d)}
	delete(ws.effect_defs)
	for _, t in ws.tags {free_tags(t)}
	delete(ws.tags)
	for _, &refs in ws.attached {
		delete(refs)
	}
	delete(ws.attached)
	ws^ = {}
}

// resolve turns PlayerRef (0x14) into the actor the player controls; every other form stays.
resolve :: proc(ws: ^World_State, form: Form_ID) -> Form_ID {
	return ws.player if form == formid.PLAYER else form
}

init_overlay :: proc(o: ^Overlay) {
	o.ref_deltas = make(map[Form_ID]Ref_Delta)
	o.by_cell = make(map[Form_ID][dynamic]Form_ID)
	o.created = make(map[Form_ID]Created_Ref)
	o.created_by_cell = make(map[Form_ID][dynamic]Form_ID)
	o.next_created = formid.CREATED_FORM_BASE
	o.player = formid.START_CHARACTER
	o.globals = make(map[Form_ID]f32)
	o.quests = make(map[Form_ID]Quest_State)
	o.inventories = make(Deltas)
	o.spells = make(Deltas)
	o.spell_seeds = make(Deltas)
	o.rolled = make(map[Form_ID][dynamic]gamedb.Content_Entry)
	o.zone_levels = make(map[Form_ID]i32)
	o.actor_picks = make(map[Form_ID]Form_ID)
	o.outfits = make(map[Form_ID]Form_ID)
	o.sleep_outfits = make(map[Form_ID]Form_ID)
	o.units = make(map[Form_ID]Unit)
	o.units_of = make(map[Form_ID][dynamic]Form_ID)
	init_formulas(o)
	o.stolen_marks = make(map[Form_ID]bool)
	o.stolen_marks[formid.GOLD] = false
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
	actorstate.init(&o.states)
	o.plugin_blobs = make(map[string][]u8)
	o.unreported = make(Form_Set)
	o.grounded = make(Form_Set)
	o.destruction = make(map[Form_ID]f32)
	o.deferred_kills = make(Form_Set)
	o.causes = make(map[Form_ID]Form_ID)
	o.dont_move = make(Form_Set)
	o.restrained = make(Form_Set)
	o.actor_flags = make(map[Form_ID]Flag_Override)
	o.owners = make(map[Form_ID]Form_ID)
	o.crime_factions = make(map[Form_ID]Form_ID)
	o.wanted = make(map[[2]Form_ID]Wanted)
	o.jailed = make(map[Form_ID]Jailed)
	o.faction_relations = make(map[[2]Form_ID]gamedb.Faction_Relation)
	o.script_factions = make(map[Form_ID]Script_Faction)
	o.crime_victims = make(map[[2]Form_ID]bool)
	o.friend_hits = make(map[[2]Form_ID]i32)
	o.days_jailed = make(map[Form_ID]i32)
	o.known_bounties = make(map[[2]Form_ID]Known_Bounty)
	o.killers = make(map[Form_ID]Form_ID)
	o.display_names = make(map[Form_ID]string)
	o.scenes = make(map[Form_ID]Scene_Run)
	o.packages_done = make(map[[2]Form_ID]f64)
	o.awareness = make(map[[2]Form_ID]Awareness)
	o.item_filters = make(map[Form_ID][dynamic]Form_ID)
	o.aliases = make(map[Form_ID]Form_ID)
	o.alias_holders = make(map[Form_ID][dynamic]Form_ID)
	o.script_state = make(map[Form_ID][dynamic]Script_Var)
	o.list_adds = make(map[Form_ID][dynamic]Form_ID)
	o.keyword_data = make(map[Keyword_Key]f32)
	o.pending_moves = make(map[Form_ID]Pending_Move)
	o.anim_regs = make(map[Form_ID][dynamic]Anim_Reg)
	o.los_regs = make([dynamic]Los_Reg)
	o.projectiles = make([dynamic]Flight)
	o.zones = make(map[Form_ID]Zone)
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
	delete(o.stolen_marks)
	free_deltas(&o.spells)
	free_deltas(&o.spell_seeds)
	delete(o.rolled)
	delete(o.zone_levels)
	delete(o.actor_picks)
	delete(o.outfits)
	delete(o.sleep_outfits)
	delete(o.units)
	for _, l in o.units_of {delete(l)}
	delete(o.units_of)
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
	for _, v in o.visuals {delete(v.node)}
	delete(o.visuals)
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
	actorstate.destroy(&o.states)
	for id, data in o.plugin_blobs {delete(id);delete(data)}
	delete(o.plugin_blobs)
	delete(o.unreported)
	delete(o.grounded)
	delete(o.destruction)
	delete(o.deferred_kills)
	delete(o.causes)
	delete(o.dont_move)
	delete(o.restrained)
	delete(o.actor_flags)
	delete(o.owners)
	delete(o.crime_factions)
	delete(o.wanted)
	delete(o.faction_relations)
	for _, s in o.script_factions {delete(s.name);free_ranks(s.data.ranks)}
	delete(o.script_factions)
	delete(o.crime_victims)
	delete(o.friend_hits)
	delete(o.days_jailed)
	delete(o.known_bounties)
	delete(o.killers)
	for _, n in o.display_names {delete(n)}
	delete(o.display_names)
	delete(o.courier_waits)
	delete(o.victim_waits)
	delete(o.jailed)
	delete(o.jail_orders)
	for _, m in o.crime_members {delete(m)}
	delete(o.crime_members)
	free_scene_runs(&o.scenes)
	delete(o.scenes)
	delete(o.packages_done)
	delete(o.awareness)
	delete(o.item_filters)
	delete(o.aliases)
	delete(o.alias_holders)
	delete(o.script_state)
	delete(o.list_adds)
	delete(o.keyword_data)
	delete(o.pending_moves)
	delete(o.anim_regs)
	delete(o.los_regs)
	delete(o.weathers_offered)
	delete(o.projectiles)
	delete(o.zones)
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
