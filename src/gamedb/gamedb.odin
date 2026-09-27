package gamedb

// Game database (ROADMAP Phase 1b / Iteration 1, Milestone C): the parsed ESM
// records held in memory and queryable — by FormID, by cell. Built in one walk of a
// plugin's bytes (src/formats/esm) and consumed by src/world to build a scene.
//
// Iteration-1 scope: index interior cells, their REFR placements, and the base-form
// model paths those REFRs resolve to (the static-world subset). Multi-master: build_plugins
// merges a resolved load order (loadorder.odin), remapping every plugin's local FormIDs into
// global load-order space so a later plugin overrides an earlier one (last write wins).

import "base:runtime"
import "core:log"
import "core:math"
import "core:strings"
import "../formats/esm"
import "../formid"
import strtab "../formats/strings"

// Form_ID is the global form handle (esm.Form_ID = u64): (slot<<32)|local. All gamedb
// keys/handles are global — every plugin's FormIDs are remapped into this space at build.
Form_ID :: esm.Form_ID

// Ref is one placed reference inside a cell: its base form, world transform, and (for
// doors) a teleport to a destination door.
Ref :: struct {
	form_id:      Form_ID,
	cell_form_id: Form_ID, // the interior cell this ref belongs to
	base:         Form_ID,
	pos:          [3]f32,
	rot:          [3]f32,
	scale:        f32,
	count:        i32, // XCNT: how many items this ref is (1 without)
	teleport:     esm.Teleport,
	has_tp:       bool,
	disabled:     bool, // REFR "Initially Disabled" flag — not placed in the world
	deleted:      bool, // a plugin removed this ref (also sets `disabled`); it runs no scripts
	persistent:   bool, // in its cell's persistent group: its scripts start at game start
	no_respawn:   bool, // REFR "No Respawn": a cell reset leaves it as it is
	// XESP enable-parent: this ref is only placed when its parent is enabled (XOR opposite).
	// enable_parent 0 = no parent. The STATIC default gate (ref_effective_disabled) drops
	// quest/alternate debris; the eventual quest system flips the parent live.
	enable_parent:   Form_ID,
	enable_opposite: bool,
}

// REFR record-header flag: the ref starts disabled (an alternate-state placement).
REFR_INITIALLY_DISABLED :: 0x0000_0800
// Record-header DELETED flag — an override that removes a master's record (TESForm bit 5).
REFR_DELETED :: 0x0000_0020
// REFR/ACHR record-header flag: the ref does not reset with its cell.
REFR_NO_RESPAWN :: 0x4000_0000

// Form_Kind classifies a form by its record type, for script method-dispatch: which Papyrus class
// chain a bare form-handle resolves methods up (a Quest handle → {Quest, Form}, a GlobalVariable →
// {GlobalVariable, Form}). Only the record types that map to a Form-SUBTYPE class we dispatch
// specially are tracked — everything else stays Unknown and falls back to the object-reference /
// Form default chain, matching the naive pre-decoder behaviour. This is the first slice of the
// form→class decoder (docs: record-decoders); it grows as more base-form classes get natives.
//
// The base-object kinds classify a BASE form by its record signature — a bare weapon/NPC/potion
// handle dispatches up its own Papyrus base class (chain {Class, Form}) and prints as that class.
// Placed references (REFR/ACHR) are NOT classified here: they keep the Unknown object-ref chain,
// so a placed weapon stays an ObjectReference while its base form is a Weapon (the ref-vs-base
// split). Only records whose class carries declared natives are tracked — see base_class.
Form_Kind :: enum u8 {
	Unknown, // object ref or anything not specially classified → default chain
	Quest,   // QUST
	Global,  // GLOB
	Faction, // FACT
	// base-object / form-subtype classes (chain {Class, Form})
	ActorBase,          // NPC_
	Weapon,             // WEAP
	Potion,             // ALCH
	Ingredient,         // INGR
	Scroll,             // SCRL
	Spell,              // SPEL
	Enchantment,        // ENCH
	Keyword,            // KYWD
	FormList,           // FLST
	MagicEffect,        // MGEF
	Location,           // LCTN
	Weather,            // WTHR
	Cell_,              // CELL (trailing _ : `Cell` is the record struct above)
	Sound,              // SOUN
	VisualEffect,       // RFCT
	EffectShader,       // EFSH
	Scene,              // SCEN
	ImageSpaceModifier, // IMAD
	LeveledItem,        // LVLI
	Message,            // MESG
	MusicType,          // MUSC
	SoundCategory,      // SNCT
	ShaderParticleGeometry,// SPGD
	Package,            // PACK
	LeveledSpell,       // LVSP
	LeveledActor,       // LVLN
	TopicInfo,          // INFO
	Topic,              // DIAL
	Light,              // LIGH
	Armor,              // ARMO
	Ref_Alias,          // a quest's reference alias (an alias handle, not a record)
	Location_Alias,     // a quest's location alias
	Active_Effect,      // a magic effect on a target (an effect handle, not a record)
}

// Quest_Baseline is a QUST record's script-relevant baseline (the immutable half of a quest's state;
// the mutable half is worldstate.Quest_State). `start_game_enabled` (DNAM flag) means the quest is
// running from a new game — so an untouched SGE quest reads IsRunning=true. `stages` holds each
// defined stage; a key's presence = the stage exists (SetCurrentStageID validates against it).
Quest_Baseline :: struct {
	start_game_enabled: bool,
	run_once:           bool, // DNAM 0x100: the story manager starts it once per game
	priority:           u8, // DNAM: the higher quest's blocking dialogue wins
	event:              [4]u8, // ENAM: the story manager event that starts it ("KILL"), zero when none
	dialogue_conditions: []Condition, // gate every INFO of the quest (owned)
	event_conditions:   []Condition, // the story manager's conditions, after NEXT (owned)
	stages:             map[u16]Quest_Stage,
	objectives:         map[u16]bool, // defined objective indices (QOBJ); presence = defined
	// Display text (the journal half). Owned, English-resolved at index time. Only stages with a
	// CNAM log entry appear in stage_log (silent stages — script-only bookkeeping — are absent);
	// every QOBJ contributes to objective_text (its NNAM display line).
	stage_log:          map[u16]string, // stage index -> journal log entry text (resolved; owned)
	objective_text:     map[u16]string, // objective index -> display text (resolved; owned)
	objective_targets:  map[u16][]Objective_Target, // objective index -> its QSTA targets in order (owned)
	// Alias slots in declaration order (ALST/ALLS). The quest's scripts address these by id, so
	// consumers index by `id`, not position — quest_alias does that lookup. Owned.
	aliases:            []Quest_Alias,
}

// Objective_Target is one QSTA of an objective: the alias it points at, shown while its conditions pass.
Objective_Target :: struct {
	alias:      i32,
	flags:      u8, // TARGET_IGNORES_LOCKS
	conditions: []Condition, // owned
}

TARGET_IGNORES_LOCKS :: 0x1 // the compass marker ignores locked doors

// Stage flags (INDX).
STAGE_START_UP :: 0x2
STAGE_SHUT_DOWN :: 0x4

Quest_Stage :: struct {
	flags: u8,
	items: []Stage_Item, // owned
}

// Stage item flags (QSDT).
ITEM_COMPLETE_QUEST :: 0x1
ITEM_FAIL_QUEST :: 0x2

// Stage_Item is one log entry of a stage: its fragment runs when its conditions pass.
Stage_Item :: struct {
	flags:      u8,
	conditions: []Condition, // owned
}

// CELL_SIZE is the side of one exterior cell in world units: the grid step.
CELL_SIZE :: f32(4096)

// Cell is one cell's identity. Exterior cells carry their worldspace + grid (each
// grid step is CELL_SIZE); interior cells have world_form_id 0 and has_grid false.
Cell :: struct {
	form_id:       Form_ID,
	editor_id:     string, // owned by the DB
	interior:      bool,
	world_form_id: Form_ID, // owning WRLD (0 for interiors)
	gx, gy:        i32, // exterior grid coordinates
	has_grid:      bool, // false for interiors / the worldspace persistent cell
	water_height:  f32, // flat water-plane Z (esm.WATER_NONE = no water; sentinel already resolved to the worldspace default at index time)
	water_type:    Form_ID, // XCWT water-type WATR formID (0 = none/default; reserved for appearance)
	location:      Form_ID, // XLCN location LCTN (0 = none; an exterior then falls back to its worldspace's)
	zone:          Form_ID, // XEZN encounter zone ECZN (0 = none)
}

// DB is the in-memory record index. All strings / dynamic arrays are owned and freed
// by destroy.
DB :: struct {
	allocator:    runtime.Allocator,
	base_models:   map[Form_ID]string, // base formID -> mesh path (owned)
	names:         map[Form_ID]string, // base/ref formID -> display name (owned; FULL, localized or inline)
	base_lod:      map[Form_ID][esm.LOD_MODELS]string, // base formID -> MNAM distant-LOD meshes (owned; "" = absent)
	base_box:      map[Form_ID][2][3]f32, // base formID -> OBND box at scale 1 (size cull, LOS picks, no mesh load)
	base_value:    map[Form_ID]i32, // base formID -> gold value (carriable items; absent = not a valued item)
	base_weight:   map[Form_ID]f32, // base formID -> weight (carriable items; absent = not a valued item)
	containers:    map[Form_ID][]Content_Entry, // CONT base formID -> its baseline inventory (owned slices)
	form_lists:    map[Form_ID][]Form_ID, // FLST formID -> its ordered member forms (owned slices; remapped)
	leveled_lists: map[Form_ID]Leveled_List, // LVLI formID -> its decoded roll table (owned entries; resolution deferred)
	keywords:      map[Form_ID][]Form_ID, // any form -> its KWDA keyword forms (owned; the set HasKeyword tests)
	keyword_edid:  map[Form_ID]string, // KYWD formID -> its editor id (owned; a keyword has no FULL, the edid IS its name)
	keyword_by_edid: map[string]Form_ID, // lowercased keyword editor id -> formID (key owned)
	linked_refs:   map[Form_ID][]Linked_Ref, // REFR formID -> its XLKR links (owned; keyword 0 = the default link)
	factions:      map[Form_ID]Faction, // FACT formID -> its baseline (owned slices/titles)
	spells:        map[Form_ID]Spell, // SPEL/SCRL formID -> its cast parameters + effects (owned)
	enchantments:  map[Form_ID]Enchantment, // ENCH formID -> its parameters + effects (owned)
	potions:       map[Form_ID]Potion, // ALCH formID -> its effects (owned)
	magic_effects: map[Form_ID]Magic_Effect, // MGEF formID -> what the effect does (owned description)
	locations:     map[Form_ID]Location, // LCTN formID -> its place in the location tree + map marker
	weathers:      map[Form_ID]Weather, // WTHR formID -> its authored sky look (colours/fog/imagespaces)
	races:         map[Form_ID]Race, // RACE formID -> identity + skill bonuses + body scale (owned description)
	classes:       map[Form_ID]Class, // CLAS formID -> level-up weighting (owned description)
	voice_types:   map[Form_ID]u8, // VTYP formID -> its DNAM flags (identity is the form itself)
	outfits:       map[Form_ID][]Form_ID, // OTFT formID -> the gear it grants (owned; remapped)
	actor_value_info:     map[Form_ID]Actor_Value_Info, // AVIF formID -> its identity (owned strings)
	actor_value_by_index: map[i32]Form_ID, // engine ActorValue index -> its AVIF form
	global_values: map[Form_ID]f32, // GLOB formID -> its FLTV baseline value (worldstate.globals overlay overrides at runtime)
	global_by_edid: map[string]Form_ID, // lowercased GLOB editor id -> formID (key owned): text tags name globals
	settings:      map[string]Game_Setting, // lower-cased GMST editor id -> its value (key owned; a String value is owned too)
	messages:      map[Form_ID]Message, // MESG formID -> its on-screen text and buttons (owned strings)
	perks:         map[Form_ID]Perk, // PERK formID -> its identity and rank link (owned strings)
	perk_trees:    map[Form_ID][]Perk_Node, // skill AVIF formID -> its constellation nodes (owned)
	race_bounds:   map[Form_ID][2][3]f32, // race -> its skeleton's BBX box (set_race_bounds, from the app)
	recipes:       map[Form_ID]Recipe, // COBJ formID -> its crafting recipe (owned ingredient list)
	recipes_by_bench: map[Form_ID][dynamic]Form_ID, // workbench KEYWORD formID -> the recipes it shows (owned)
	actors:        map[Form_ID]Actor_Base, // NPC_ formID -> its decoded base identity (owned slices; the player is 0x00000007)
	doors:         map[Form_ID]bool, // base formID -> true if it's a DOOR record (door-panel cull)
	triggers:      map[Form_ID]esm.Primitive, // REFR formID -> its XPRM box or sphere (a trigger volume)
	locks:         map[Form_ID]esm.Lock_Data, // REFR formID -> its XLOC baseline lock (presence = starts locked)
	trees:         map[Form_ID]bool, // base formID -> true if it's a TREE record (distant billboard LOD)
	books:         map[Form_ID]Book, // BOOK base formID -> what reading it teaches (absent = teaches nothing)
	produce:       map[Form_ID]Form_ID, // FLOR / TREE base formID -> its PFIG harvest (an item or a leveled list)
	cells:         map[Form_ID]Cell, // cell formID -> identity
	form_by_edid:  map[string]Form_ID, // lowercased editor id -> quest, NPC_ or placed ref (key owned): the console's names
	cell_by_edid:  map[string]Form_ID, // lowercased editor id -> cell formID (key owned)
	cell_refs:     map[Form_ID][dynamic]Ref, // cell formID -> static placements (REFR)
	actor_refs:    map[Form_ID][dynamic]Ref, // cell formID -> actor placements (ACHR; base = an NPC_)
	ref_by_id:     map[Form_ID]Ref, // REFR formID -> its placement (for XTEL door targets)
	enable_parents: map[Form_ID]bool, // refs some XESP names; a live toggle re-gates their chain
	worlds:        map[Form_ID]string, // WRLD formID -> editor id (owned)
	world_by_edid: map[string]Form_ID, // lowercased worldspace editor id -> formID (key owned)
	world_cells:   map[Form_ID][dynamic]Form_ID, // WRLD formID -> its exterior cell formIDs
	world_persist: map[Form_ID]Form_ID, // WRLD formID -> its PERSISTENT cell formID (worldspace-wide refs)
	world_water:   map[Form_ID]f32, // WRLD formID -> default water height (a cell's XCLW sentinel resolves here)
	world_location: map[Form_ID]Form_ID, // WRLD formID -> its XLCN location (a cell without one is here)
	cell_at_grid:  map[Grid_Key]Form_ID, // (world, gx, gy) -> exterior cell formID (streaming)
	cell_heights:  map[Form_ID][]f32, // cell formID -> LAND_GRID² cumulative heightmap (owned)
	navmeshes:     map[Form_ID][dynamic]Navmesh, // cell formID -> its NAVMs (owned)
	navmesh_cell:  map[Form_ID]Form_ID, // NAVM formID -> the cell it is in
	nav_index:     map[Form_ID]Nav_Info, // NAVM formID -> its NAVI entry, merged over plugins (owned)
	cell_base_tex: map[Form_ID][4]Form_ID, // cell formID -> per-quadrant base LTEX formID (0=none)
	cell_dominant: map[Form_ID][]Form_ID, // cell formID -> LAND_GRID² dominant LTEX per vertex (owned)
	ltex_txst:     map[Form_ID]Form_ID, // LTEX formID -> its TXST texture-set formID
	txst_diffuse:  map[Form_ID]string, // TXST formID -> TX00 diffuse path (owned)
	ltex_grass:    map[Form_ID]Form_ID, // LTEX formID -> its GRAS grass-type formID (GNAM)
	grasses:       map[Form_ID]Grass, // GRAS formID -> grass type (model owned)
	form_kinds:    map[Form_ID]Form_Kind, // form -> Papyrus class kind (QUST/GLOB/FACT); absent = Unknown
	plugin_slots:  map[string]u32, // lower-cased plugin filename -> the global slot of its own forms (owned keys)
	zones:                 map[Form_ID]Zone,    // ECZN -> its levels, flags and location
	equip_slots:           map[Form_ID]Equip_Slot, // ARMO/WEAP/SPEL/... -> where it equips
	equip_types:           map[Form_ID]Equip_Type, // EQUP -> the slots it stands for
	ref_zones:             map[Form_ID]Form_ID, // REFR/ACHR -> its own XEZN zone (absent = its cell's)
	level_mods:            map[Form_ID]u8,      // ACHR -> its XLCM difficulty (esm.LEVEL_MOD_*); absent = none
	owners:                map[Form_ID]Form_ID, // REFR/ACHR/CELL -> its XOWN owner, an NPC_ or a FACT (queries.odin)
	activate_parents:      map[Form_ID][]Form_ID, // REFR/ACHR -> its XAPR activate parents (owned)
	packages:              map[Form_ID]Package, // PACK -> its decoded package (packages.odin)
	ingredients:           map[Form_ID][]Magic_Effect_Ref, // INGR -> its effects (owned)
	load_slots:            [dynamic]u32,        // load-order index -> that plugin's slot (Papyrus form ids)
	respawning_containers: map[Form_ID]bool, // CONT flagged Respawns: its contents reset with its cell
	vendor_chests:         map[Form_ID]bool, // FACT VENC refs: merchant chests, restocked on their own timer
	form_scripts:  map[Form_ID]esm.Form_Scripts, // form -> the scripts its VMAD attaches (owned; see index_scripts)
	quest_baseline: map[Form_ID]Quest_Baseline, // QUST form -> its baseline (SGE flag + defined stages)
	story_nodes:   map[Form_ID]Story_Node, // SMBN/SMQN/SMEN form -> its node in the story manager tree
	topics:        map[Form_ID]Topic,  // DIAL form -> its topic
	branches:      map[Form_ID]Branch, // DLBR form -> its dialogue branch
	infos:         map[Form_ID]Info,   // INFO form -> its response
	scenes:        map[Form_ID]Scene,  // SCEN form -> its phases, actors and actions
	relationships: map[[2]Form_ID]Relationship, // {lower, higher} NPC_ pair -> RELA
	associations:  map[Form_ID]u32,    // ASTP form -> its flags
	story_roots:   []Form_ID, // the top nodes (event nodes), in sibling order; owned
	unique_refs:    map[Form_ID]Form_ID, // unique NPC_ -> its placed actor (lowest form id if placed twice)
	alias_targets:  map[Form_ID]bool,    // refs a Specific or Unique_Actor alias fill can hold
	persistent_refs: []Form_ID,          // every persistent placed ref, in form order: a world alias search (owned)
	ref_types:      map[Form_ID][dynamic]Form_ID, // ref -> its location ref types, from the locations' special refs
	linked_children: map[Form_ID][dynamic]Form_ID, // ref -> the refs whose default link is it (Near Alias)
	load_tips:     [dynamic]string, // LSCR DESC loading-tip text (owned; the load screen rotates through these)
	ref_index:     map[Form_ID]Ref_Loc, // build-time only: REFR formID -> its slot in cell_refs (override dedup); emptied after build
	actor_ref_index: map[Form_ID]Ref_Loc, // build-time only: ACHR formID -> its slot in actor_refs (override dedup); emptied after build
	cur_strings:   map[u32]string, // build-time only: the current plugin's STRINGS table (short text: names; borrowed, freed per plugin)
	cur_dlstrings: map[u32]string, // build-time only: the current plugin's DLSTRINGS table (long text: quest log CNAM, DESC; borrowed, freed per plugin)
	cur_ilstrings: map[u32]string, // build-time only: the current plugin's ILSTRINGS table (dialogue response text; borrowed, freed per plugin)
	cur_localized: bool, // build-time only: is the current plugin localized (FULL = string id vs inline)
}

// Ref_Loc locates a placed ref within cell_refs so a later plugin overriding the same
// REFR formID replaces it in place instead of appending a duplicate. Build-time scaffolding.
@(private)
Ref_Loc :: struct {
	cell: Form_ID,
	idx:  int,
}

// Content_Entry is one line of a container's baseline inventory: a base item form (remapped to
// global space) and how many. The immutable baseline — runtime add/remove lives in the overlay
// (the 4b inventory store reads this as the starting stack list).
Content_Entry :: struct {
	item:  Form_ID,
	count: i32,
}

// Leveled_Entry is one candidate of a leveled list: at player-level ≥ `level`, this `form` (remapped
// to global space; may itself be another leveled list) contributes `count` copies to the roll.
Leveled_Entry :: struct {
	level: u16,
	form:  Form_ID,
	count: u16,
}

// Leveled_List is a LVLI's decoded roll table (the DATA layer only — no rolling). `chance_none` is
// the percent chance the roll yields nothing (LVLD); `flags` is LVLF (esm.LVLI_* bits). `entries`
// is owned by the DB. Resolution (roll by player level, apply chance-none, expand nested lists,
// pin the outcome in the save overlay) is a consumer concern deferred to the item/loot store.
Leveled_List :: struct {
	chance_none:   u8,
	chance_global: Form_ID, // LVLG: a GLOB whose value replaces chance_none (0 = none)
	flags:         u8,
	entries:       []Leveled_Entry, // owned
}

// Zone is an ECZN: the level band a place rolls at (max 0 = no cap), its flags (esm.ECZN_*), and the
// location it names.
Zone :: struct {
	location:             Form_ID,
	min_level, max_level: i32,
	flags:                u8,
}

// Actor_Base is an NPC_'s decoded base identity (the DATA layer — no runtime actor state). Stats
// come from ACBS (flags/level/offsets) + DNAM (base attributes + skills); the linked forms
// (race/class/voice/outfit, spells, packages) are remapped to global space; inventory reuses the
// container CNTO shape. The player's base (0x00000007) is an Actor_Base like any other
// (docs/script-runtime-decisions.md §5). Spawning/capsules/stat-calc are consumers.
Actor_Base :: struct {
	flags:         u32, // ACBS flags (esm.ACBS_* — essential/unique/protected/…)
	level:         u16, // ACBS level (absolute, or ×1000 player-level mult if ACBS_PC_LEVEL_MULT)
	calc_min:      u16, // ACBS auto-calc level band
	calc_max:      u16,
	speed_mult:    u16, // ACBS speed %
	magicka_off:   i16, // ACBS offsets on top of the race's starting health/magicka/stamina
	stamina_off:   i16,
	health_off:    i16,
	base_health:   u16, // DNAM base attributes
	base_magicka:  u16,
	base_stamina:  u16,
	skills:        [esm.NPC_SKILLS]u8, // DNAM 18 base skill values
	skill_offsets: [esm.NPC_SKILLS]u8, // DNAM 18 skill offsets
	race:          Form_ID, // RNAM
	bounds:        [2][3]f32, // OBND; all zero on many (the CK left it unset)
	class:         Form_ID, // CNAM
	voice:         Form_ID, // VTCK
	outfit:        Form_ID, // DOFT default outfit
	gift_filter:   Form_ID, // GNAM FLST of what it accepts as a gift
	template:      Form_ID, // TPLT: an NPC_ or LVLN the template flags draw from
	template_flags: u16,    // ACBS (esm.ACBS_TEMPLATE_*)
	ai:            [6]u8,   // AIDT: the AI actor values 0..5 (Aggression .. Assistance)
	aggro:         esm.Aggro, // AIDT aggro radius behavior
	spells:        []Form_ID, // SPLO (owned)
	perks:         []Form_ID, // PRKR (owned)
	packages:      []Form_ID, // PKID AI packages (owned; empty on the player — control is our engine's package)
	default_packages: Form_ID, // DPLT: an FLST of packages
	inventory:     []Content_Entry, // CNTO starting inventory (owned)
	factions:      []Faction_Membership, // SNAM baseline faction ranks (owned; the overlay diverges from these)
}

// Faction_Membership is one baseline faction the actor belongs to, and its rank there (SNAM,
// remapped). The runtime faction store overlays this — IsInFaction reads the overlay first and
// falls through to these, so an untouched NPC answers from its authored memberships.
Faction_Membership :: struct {
	faction: Form_ID,
	rank:    i8,
}

// Faction_Relation is how this faction regards another (an XNAM row, remapped): a disposition
// shift plus the hard combat reaction that drives ally/enemy checks.
Faction_Relation :: struct {
	faction:  Form_ID,
	modifier: i32,
	combat:   esm.Combat_Reaction,
}

// Faction_Rank is one rung of a faction's ladder: the rank index a member holds and the titles
// shown for it. Titles are English-resolved and owned by the DB; either may be "" (most vanilla
// factions title only some ranks, and only 10 of 1084 carry a female title).
Faction_Rank :: struct {
	index:        u32,
	male_title:   string, // owned
	female_title: string, // owned
}

// Faction is a FACT's decoded baseline: its flags, who it likes, its rank ladder, and (for a
// crime faction) the bounty table its guards enforce. Runtime membership/reputation lives in the
// worldstate overlay; this is what the overlay diverges from.
Faction :: struct {
	flags:     u32, // esm.FACT_* bits
	relations: []Faction_Relation, // XNAM (owned)
	ranks:     []Faction_Rank, // RNAM + MNAM/FNAM titles (owned)
	crime:     esm.Crime_Values, // CRVA bounty table
	has_crime: bool, // false when the faction carries no CRVA (crime values read as zero)
	vendor:    Vendor, // VENV and the vendor conditions, for a FACT_VENDOR faction
}

// Vendor is when a vendor faction's members trade (FACT VENV, xEdit).
Vendor :: struct {
	start, end: u16, // hours; an end before the start wraps past midnight
	conditions: []Condition, // owned
}

// Magic_Effect_Ref is one effect a spell / scroll / enchantment applies: the MGEF (remapped) and
// the strength / area / duration this caster applies it at.
Magic_Effect_Ref :: struct {
	effect:    Form_ID,
	magnitude: f32,
	area:      u32,
	duration:  u32,
	conditions: []Condition, // the CTDAs after its EFIT (owned)
}

// Spell is a SPEL or SCRL baseline: its SPIT cast parameters plus the effects it applies. `scroll`
// separates the two record types (identical SPIT layout, different Papyrus class). The form fields
// inside `info` are the raw/local ones as authored — read the remapped handles beside it instead.
Spell :: struct {
	info:           esm.Spell_Info,
	half_cost_perk: Form_ID, // SPIT half-cost perk, remapped
	scroll:         bool, // SCRL rather than SPEL
	effects:        []Magic_Effect_Ref, // EFID/EFIT (owned)
}

// Enchantment is an ENCH baseline: its ENIT parameters plus the effects it grants the item it's
// applied to. Same raw-vs-remapped split as Spell.
Enchantment :: struct {
	info:              esm.Enchant_Info,
	base_enchantment:  Form_ID, // ENIT parent enchantment, remapped
	worn_restrictions: Form_ID, // ENIT slot FLST, remapped
	effects:           []Magic_Effect_Ref, // EFID/EFIT (owned)
}

// Potion is an ALCH baseline: a potion, food or poison. A poison goes on a weapon; the rest are
// drunk or eaten.
Potion :: struct {
	effects: []Magic_Effect_Ref, // owned
	poison:  bool,
}

// Magic_Effect is an MGEF baseline: what the effect does (archetype + the actor values it reads
// and writes), what it costs, and its player-facing description. Same raw-vs-remapped split as
// Spell. `description` is English-resolved and owned ("" when the effect has none).
Magic_Effect :: struct {
	info:        esm.Magic_Effect_Info,
	projectile:  Form_ID, // remapped
	explosion:   Form_ID, // remapped
	related:     Form_ID, // remapped: a Peak Value Modifier's no-stack keyword
	description: string, // DNAM (owned)
	conditions:  []Condition, // CTDA (owned)
}

// Linked_Ref is one XLKR link of a placed reference (both handles remapped). `keyword` 0 is the
// DEFAULT link — what a bare GetLinkedRef() returns; a non-zero keyword names the channel
// GetLinkedRef(akKeyword) selects.
Linked_Ref :: struct {
	keyword: Form_ID,
	ref:     Form_ID,
}

// (hole alias-data :tags (quest ai) :sev gap) an alias applies only its factions and keywords while filled: the Essential, Protected and Quest Object flags, spells (ALSP), override package lists, display name (ALDN, with SetDisplayName) and inventory (CNTO) are not decoded.
// Quest_Alias is one alias slot of a quest — the handle a quest script addresses by id
// (ReferenceAlias.GetReference) — and its AUTHORED fill rule (esm.Alias_Fill, esm.Quest_Alias);
// the quest engine fills it at start. `name` and `conditions` are owned by the DB.
Quest_Alias :: struct {
	id:           u32,
	location:     bool, // a location alias (ALLS) rather than a reference alias (ALST)
	flags:        u32, // esm.ALIAS_*
	fill:         esm.Alias_Fill,
	target:       Form_ID, // the fill's form operand, remapped (0 when the kind has none)
	alias:        i32, // the fill's alias operand; -1 when it has none
	force_into:   i32, // another alias filled with the same thing; -1 when none
	event_member: i32, // a From Event fill's event member (R1, L1...)
	create_in:    bool,
	create_level: u32,
	conditions:   []Condition, // the Match Conditions (owned)
	factions:     []Form_ID, // ALFC: the holder counts as a member while in the alias (owned)
	keywords:     []Form_ID, // KWDA: the holder has these keywords while in the alias (owned)
	packages:     []Form_ID, // ALPC: the holder may run these while in the alias (owned)
	name:         string, // owned
}

// LOCATION_TREE_MAX_DEPTH caps a location-parent walk. Vanilla nests ~4 deep (room → dungeon →
// hold → Skyrim); the cap only exists so a malformed plugin's parent cycle can't hang a query.
LOCATION_TREE_MAX_DEPTH :: 32

// Location is an LCTN's baseline: where it sits in the location tree and how its map marker
// draws. Its display name is in db.names and its keywords in the shared keyword index — the
// keyword set is what Location.GetKeywordData reads. The LCSR/LCEC/LCID membership lists (which
// refs/cells/actors belong to it) are the quest system's, and stay undecoded.
Location :: struct {
	parent:           Form_ID, // PNAM containing location (0 = a root location)
	marker_color:     u32, // CNAM packed RGBA
	has_marker_color: bool,
	special_refs:     []Special_Ref, // the refs of a location ref type in it: master_refs with the winning override's edits (owned)
	master_refs:      []Special_Ref, // the master's LCSR list, which overrides edit (owned)
}

// Special_Ref is a ref of a location ref type (LCRT) in a location, remapped.
Special_Ref :: struct {
	ref_type, ref: Form_ID,
}

// Weather_Class is a weather's kind — the low four DATA flag bits, and what
// Weather.GetClassification reports. None means the weather declares no class.
Weather_Class :: enum u8 {
	None,
	Pleasant,
	Cloudy,
	Rainy,
	Snow,
}

// Weather is a WTHR's authored sky look: classification + motion/precipitation scalars, fog
// distances, the NAM0 colour table, and the imagespace applied at each time of day. `color_rows`
// is how many rows NAM0 actually carried — the field is VARIABLE length (vanilla weathers author
// 16 or 17), so never iterate past it. Index rows with the esm.WTHR_COLOR_* constants and times
// with 0 sunrise / 1 day / 2 sunset / 3 night.
Weather :: struct {
	info:        esm.Weather_Info,
	fog:         esm.Weather_Fog,
	has_fog:     bool,
	colors:      [esm.WTHR_COLOR_ROWS_MAX][esm.WTHR_TIMES][4]u8,
	color_rows:  int,
	imagespaces: [esm.WTHR_TIMES]Form_ID, // IMSP, remapped (0 = none)
}

// Grass is one scatterable grass type (a GRAS record): the cluster mesh the engine
// instances over terrain and how densely (clusters per unit area).
Grass :: struct {
	model:   string, // owned (MODL grass-cluster mesh, e.g. "Plants\\Grass...")
	density: u8,
}

// Grid_Key identifies an exterior cell by its worldspace + grid coordinate — the
// streamer's lookup key as it windows cells around the player.
Grid_Key :: struct {
	world:  Form_ID,
	gx, gy: i32,
}

// base-form record types indexed for their MODL mesh (and, for carriable items, value/weight).
// The first row is the static-world subset an interior is built from (architecture, furniture,
// clutter, doors, lights); the second row is carriable item base-forms — they render as world
// models when placed AND identify (FULL name + value + weight, see item_value_weight). SCRL is
// in both worlds: a carriable item here AND a spell (index_spell reads its SPIT).
@(private)
is_base_type :: proc(s: string) -> bool {
	switch s {
	case "STAT", "MSTT", "FURN", "DOOR", "ACTI", "CONT", "FLOR", "TREE", "LIGH", "MISC":
		return true
	case "WEAP", "ARMO", "ALCH", "INGR", "BOOK", "KEYM", "AMMO", "SLGM", "SCRL":
		return true
	}
	return false
}

// base_class maps a record signature to the Papyrus class its forms dispatch as (chain {Class,
// Form}). The single source of form→kind truth: visit() classifies off this for EVERY signature,
// independent of what else it indexes off the record (a WEAP is both an indexed base mesh and a
// Weapon handle). Only signatures whose class carries declared natives are listed — everything
// else stays Unknown (object-ref chain).
@(private)
base_class :: proc(s: string) -> (Form_Kind, bool) {
	switch s {
	case "QUST":
		return .Quest, true
	case "GLOB":
		return .Global, true
	case "FACT":
		return .Faction, true
	case "CELL":
		return .Cell_, true
	case "NPC_":
		return .ActorBase, true
	case "WEAP":
		return .Weapon, true
	case "ALCH":
		return .Potion, true
	case "INGR":
		return .Ingredient, true
	case "SCRL":
		return .Scroll, true
	case "SPEL":
		return .Spell, true
	case "ENCH":
		return .Enchantment, true
	case "KYWD":
		return .Keyword, true
	case "FLST":
		return .FormList, true
	case "MGEF":
		return .MagicEffect, true
	case "LCTN":
		return .Location, true
	case "WTHR":
		return .Weather, true
	case "SOUN":
		return .Sound, true
	case "RFCT":
		return .VisualEffect, true
	case "EFSH":
		return .EffectShader, true
	case "SCEN":
		return .Scene, true
	case "IMAD":
		return .ImageSpaceModifier, true
	case "LVLI":
		return .LeveledItem, true
	case "MESG":
		return .Message, true
	case "MUSC":
		return .MusicType, true
	case "SNCT":
		return .SoundCategory, true
	case "SPGD":
		return .ShaderParticleGeometry, true
	case "PACK":
		return .Package, true
	case "LVSP":
		return .LeveledSpell, true
	case "LVLN":
		return .LeveledActor, true
	case "INFO":
		return .TopicInfo, true
	case "DIAL":
		return .Topic, true
	case "LIGH":
		return .Light, true
	case "ARMO":
		return .Armor, true
	}
	return .Unknown, false
}

// class_name is the display / most-derived Papyrus class for a form kind — used by a ref's
// `__tostring` and as the class a typed handle dispatches up first. Unknown (object refs /
// unclassified) reads "ObjectReference", the ref's nominal class.
class_name :: proc "contextless" (kind: Form_Kind) -> string {
	switch kind {
	case .Unknown:
		return "ObjectReference"
	case .Quest:
		return "Quest"
	case .Global:
		return "GlobalVariable"
	case .Faction:
		return "Faction"
	case .ActorBase:
		return "ActorBase"
	case .Weapon:
		return "Weapon"
	case .Potion:
		return "Potion"
	case .Ingredient:
		return "Ingredient"
	case .Scroll:
		return "Scroll"
	case .Spell:
		return "Spell"
	case .Enchantment:
		return "Enchantment"
	case .Keyword:
		return "Keyword"
	case .FormList:
		return "FormList"
	case .MagicEffect:
		return "MagicEffect"
	case .Location:
		return "Location"
	case .Weather:
		return "Weather"
	case .Cell_:
		return "Cell"
	case .Sound:
		return "Sound"
	case .VisualEffect:
		return "VisualEffect"
	case .EffectShader:
		return "EffectShader"
	case .Scene:
		return "Scene"
	case .ImageSpaceModifier:
		return "ImageSpaceModifier"
	case .LeveledItem:
		return "LeveledItem"
	case .Message:
		return "Message"
	case .MusicType:
		return "MusicType"
	case .SoundCategory:
		return "SoundCategory"
	case .ShaderParticleGeometry:
		return "ShaderParticleGeometry"
	case .Package:
		return "Package"
	case .LeveledSpell:
		return "LeveledSpell"
	case .LeveledActor:
		return "LeveledActor"
	case .TopicInfo:
		return "TopicInfo"
	case .Topic:
		return "Topic"
	case .Light:
		return "Light"
	case .Armor:
		return "Armor"
	case .Ref_Alias:
		return "ReferenceAlias"
	case .Location_Alias:
		return "LocationAlias"
	case .Active_Effect:
		return "ActiveMagicEffect"
	}
	return "ObjectReference"
}

// build walks a single plugin's bytes and returns the indexed DB — the convenience for a
// no-master file (Skyrim.esm standalone, tools, synthetic tests). FormIDs pass through
// unremapped (identity). For the real game load it onto build_plugins via resolve_load_order.
// The DB borrows nothing from `data` (all kept strings are cloned), so `data` may be freed.
build :: proc(data: []u8, allocator := context.allocator) -> DB {
	return build_plugins({{data = data}}, allocator)
}

// build_plugins merges a resolved load order into one DB, walking each plugin in order with
// its Form_Map so every FormID lands in global space and a later plugin overrides an earlier
// one (last write wins). `plugins` comes from resolve_load_order; the DB clones what it keeps
// so the plugin bytes may be freed after. A single identity-mapped plugin == build().
build_plugins :: proc(plugins: []Loaded_Plugin, allocator := context.allocator, progress: ^int = nil) -> DB {
	db := DB {
		allocator     = allocator,
		base_models   = make(map[Form_ID]string, 4096, allocator),
		names         = make(map[Form_ID]string, 8192, allocator),
		base_lod      = make(map[Form_ID][esm.LOD_MODELS]string, 2048, allocator),
		base_box      = make(map[Form_ID][2][3]f32, 4096, allocator),
		base_value    = make(map[Form_ID]i32, 4096, allocator),
		base_weight   = make(map[Form_ID]f32, 4096, allocator),
		containers    = make(map[Form_ID][]Content_Entry, 512, allocator),
		form_lists    = make(map[Form_ID][]Form_ID, 512, allocator),
		leveled_lists = make(map[Form_ID]Leveled_List, 2048, allocator),
		keywords      = make(map[Form_ID][]Form_ID, 4096, allocator),
		keyword_edid  = make(map[Form_ID]string, 1024, allocator),
		keyword_by_edid = make(map[string]Form_ID, 1024, allocator),
		linked_refs   = make(map[Form_ID][]Linked_Ref, 1024, allocator),
		factions      = make(map[Form_ID]Faction, 1024, allocator),
		spells        = make(map[Form_ID]Spell, 1024, allocator),
		enchantments  = make(map[Form_ID]Enchantment, 1024, allocator),
		potions       = make(map[Form_ID]Potion, 512, allocator),
		magic_effects = make(map[Form_ID]Magic_Effect, 1024, allocator),
		locations     = make(map[Form_ID]Location, 1024, allocator),
		weathers      = make(map[Form_ID]Weather, 128, allocator),
		races         = make(map[Form_ID]Race, 128, allocator),
		classes       = make(map[Form_ID]Class, 256, allocator),
		voice_types   = make(map[Form_ID]u8, 256, allocator),
		outfits       = make(map[Form_ID][]Form_ID, 512, allocator),
		actor_value_info     = make(map[Form_ID]Actor_Value_Info, 256, allocator),
		actor_value_by_index = make(map[i32]Form_ID, 256, allocator),
		global_values = make(map[Form_ID]f32, 1024, allocator),
		global_by_edid = make(map[string]Form_ID, 1024, allocator),
		settings      = make(map[string]Game_Setting, 2048, allocator),
		messages      = make(map[Form_ID]Message, 1024, allocator),
		perks         = make(map[Form_ID]Perk, 512, allocator),
		perk_trees    = make(map[Form_ID][]Perk_Node, 32, allocator),
		race_bounds   = make(map[Form_ID][2][3]f32, 128, allocator),
		recipes       = make(map[Form_ID]Recipe, 1024, allocator),
		recipes_by_bench = make(map[Form_ID][dynamic]Form_ID, 16, allocator),
		actors        = make(map[Form_ID]Actor_Base, 4096, allocator),
		doors         = make(map[Form_ID]bool, 512, allocator),
		locks         = make(map[Form_ID]esm.Lock_Data, 2048, allocator),
		triggers      = make(map[Form_ID]esm.Primitive, 4096, allocator),
		trees         = make(map[Form_ID]bool, 512, allocator),
		books         = make(map[Form_ID]Book, 256, allocator),
		produce       = make(map[Form_ID]Form_ID, 256, allocator),
		cells         = make(map[Form_ID]Cell, 1024, allocator),
		cell_by_edid  = make(map[string]Form_ID, 1024, allocator),
		form_by_edid  = make(map[string]Form_ID, 65536, allocator),
		cell_refs     = make(map[Form_ID][dynamic]Ref, 1024, allocator),
		actor_refs    = make(map[Form_ID][dynamic]Ref, 512, allocator),
		ref_by_id     = make(map[Form_ID]Ref, 4096, allocator),
		enable_parents = make(map[Form_ID]bool, 1024, allocator),
		worlds        = make(map[Form_ID]string, 64, allocator),
		world_by_edid = make(map[string]Form_ID, 64, allocator),
		world_cells   = make(map[Form_ID][dynamic]Form_ID, 64, allocator),
		world_persist = make(map[Form_ID]Form_ID, 64, allocator),
		world_water   = make(map[Form_ID]f32, 64, allocator),
		world_location = make(map[Form_ID]Form_ID, 64, allocator),
		cell_at_grid  = make(map[Grid_Key]Form_ID, 16384, allocator),
		cell_heights  = make(map[Form_ID][]f32, 1024, allocator),
		cell_base_tex = make(map[Form_ID][4]Form_ID, 1024, allocator),
		cell_dominant = make(map[Form_ID][]Form_ID, 1024, allocator),
		ltex_txst     = make(map[Form_ID]Form_ID, 128, allocator),
		txst_diffuse  = make(map[Form_ID]string, 1024, allocator),
		ltex_grass    = make(map[Form_ID]Form_ID, 128, allocator),
		grasses       = make(map[Form_ID]Grass, 64, allocator),
		form_kinds     = make(map[Form_ID]Form_Kind, 4096, allocator),
		plugin_slots   = make(map[string]u32, 64, allocator),
		zones                 = make(map[Form_ID]Zone, 1024, allocator),
		equip_slots           = make(map[Form_ID]Equip_Slot, 8192, allocator),
		equip_types           = make(map[Form_ID]Equip_Type, 16, allocator),
		ref_zones             = make(map[Form_ID]Form_ID, 1024, allocator),
		level_mods            = make(map[Form_ID]u8, 1024, allocator),
		owners                = make(map[Form_ID]Form_ID, 4096, allocator),
		activate_parents      = make(map[Form_ID][]Form_ID, 1024, allocator),
		packages              = make(map[Form_ID]Package, 8192, allocator),
		ingredients           = make(map[Form_ID][]Magic_Effect_Ref, 128, allocator),
		load_slots            = make([dynamic]u32, allocator),
		respawning_containers = make(map[Form_ID]bool, 512, allocator),
		vendor_chests         = make(map[Form_ID]bool, 256, allocator),
		quest_baseline = make(map[Form_ID]Quest_Baseline, 512, allocator),
		story_nodes   = make(map[Form_ID]Story_Node, 1024, allocator),
		topics        = make(map[Form_ID]Topic, 16384, allocator),
		branches      = make(map[Form_ID]Branch, 4096, allocator),
		infos         = make(map[Form_ID]Info, 32768, allocator),
		scenes        = make(map[Form_ID]Scene, 2048, allocator),
		relationships = make(map[[2]Form_ID]Relationship, 2048, allocator),
		associations  = make(map[Form_ID]u32, 16, allocator),
		ref_index      = make(map[Form_ID]Ref_Loc, 4096, allocator),
		actor_ref_index = make(map[Form_ID]Ref_Loc, 512, allocator),
		load_tips      = make([dynamic]string, allocator),
	}
	done_bytes := 0
	for &p in plugins {
		if p.name != "" {db.plugin_slots[strings.to_lower(p.name, allocator)] = p.self_slot}
		append(&db.load_slots, p.self_slot)
		// A LOCALIZED plugin stores FULL/DESC as string ids; resolve names via its STRINGS
		// table (loaded loose by the caller, attached to the input). Parse it once, expose it
		// to the visitor as build scaffolding, walk, then free it — the names we keep are
		// re-cloned into db.names. Non-localized plugins carry inline FULL (table stays nil).
		db.cur_localized = p.localized
		db.cur_strings = nil
		db.cur_dlstrings = nil
		db.cur_ilstrings = nil
		if p.localized {
			// Three tables: .STRINGS (short — names, objective NNAM), .DLSTRINGS (long — quest log
			// CNAM, book DESC) and .ILSTRINGS (dialogue — INFO NAM1). Different subrecords index
			// different files; load all so every lstring we decode resolves.
			if p.strings_data != nil {
				if tbl, ok := strtab.parse(p.strings_data, .Plain, allocator); ok {
					db.cur_strings = tbl
				}
			}
			if p.dlstrings_data != nil {
				if tbl, ok := strtab.parse(p.dlstrings_data, .Lengthed, allocator); ok {
					db.cur_dlstrings = tbl
				}
			}
			if p.ilstrings_data != nil {
				if tbl, ok := strtab.parse(p.ilstrings_data, .Lengthed, allocator); ok {
					db.cur_ilstrings = tbl
				}
			}
		}
		esm.walk(p.data, visit, &db, &p.fm, progress, done_bytes) // progress = cumulative bytes (for the load bar)
		if db.cur_strings != nil {
			strtab.destroy(&db.cur_strings, allocator)
		}
		if db.cur_ilstrings != nil {
			strtab.destroy(&db.cur_ilstrings, allocator)
		}
		if db.cur_dlstrings != nil {
			strtab.destroy(&db.cur_dlstrings, allocator)
		}
		done_bytes += len(p.data)
	}
	db.cur_strings = nil
	db.cur_dlstrings = nil
	// Bake XESP enable-parent into effective placement: no separate pass needed — the world
	// cull calls ref_effective_disabled(db, r) which resolves the parent's state on the fly.
	delete(db.ref_index) // build-time scaffolding — done once every plugin is walked
	db.ref_index = nil
	delete(db.actor_ref_index)
	db.actor_ref_index = nil
	index_alias_targets(&db)
	order_story_nodes(&db)
	order_topic_infos(&db)
	// No plugin holds the player ref: the engine makes it, in no cell. Its placement is its Moved delta.
	db.ref_by_id[formid.PLAYER] = Ref{form_id = formid.PLAYER, base = formid.PLAYER_BASE, scale = 1, count = 1, persistent = true}
	log.infof(
		"gamedb: %d base meshes, %d with prebaked LOD (%.0f%%)",
		len(db.base_models),
		len(db.base_lod),
		100 * f32(len(db.base_lod)) / f32(max(len(db.base_models), 1)),
	)
	// Sample a few LOD-mesh paths so we can eyeball the format (verify they resolve like MODL).
	shown := 0
	for fid, arr in db.base_lod {
		log.infof("  LOD sample 0x%08X: [0]=%q [3]=%q", fid, arr[0], arr[3])
		shown += 1
		if shown >= 4 {
			break
		}
	}
	return db
}

destroy :: proc(db: ^DB) {
	context.allocator = db.allocator
	for _, arr in db.base_lod {
		for s in arr {
			if s != "" {
				delete(s, db.allocator)
			}
		}
	}
	delete(db.base_lod)
	for _, m in db.base_models {
		delete(m)
	}
	delete(db.base_models)
	for _, n in db.names {
		delete(n)
	}
	delete(db.names)
	delete(db.base_box)
	delete(db.base_value)
	delete(db.base_weight)
	for _, c in db.containers {
		delete(c, db.allocator)
	}
	delete(db.containers)
	for _, m in db.form_lists {
		delete(m, db.allocator)
	}
	delete(db.form_lists)
	for _, ll in db.leveled_lists {
		delete(ll.entries, db.allocator)
	}
	delete(db.leveled_lists)
	delete(db.global_values) // plain f32 values — no owned data
	for k in db.global_by_edid {delete(k, db.allocator)}
	delete(db.global_by_edid)
	for k, v in db.settings {
		delete(k, db.allocator)
		if text, is_text := v.(string); is_text {
			delete(text, db.allocator)
		}
	}
	delete(db.settings)
	for _, m in db.messages {
		free_message(db, m)
	}
	delete(db.messages)
	for _, p in db.perks {
		free_perk(db, p)
	}
	delete(db.perks)
	for _, nodes in db.perk_trees {
		free_perk_tree(db, nodes)
	}
	delete(db.perk_trees)
	delete(db.race_bounds)
	for _, r in db.recipes {
		free_recipe(db, r)
	}
	delete(db.recipes)
	for _, list in db.recipes_by_bench {
		delete(list)
	}
	delete(db.recipes_by_bench)
	for s in db.load_tips {
		delete(s, db.allocator)
	}
	delete(db.load_tips)
	for _, a in db.actors {
		free_actor_base(db, a)
	}
	delete(db.actors)
	delete(db.doors)
	delete(db.locks)
	delete(db.triggers)
	delete(db.trees)
	delete(db.books)
	delete(db.produce)
	for _, c in db.cells {
		delete(c.editor_id)
	}
	delete(db.cells)
	for k in db.form_by_edid {delete(k, db.allocator)}
	delete(db.form_by_edid)
	for k, _ in db.cell_by_edid {
		delete(k)
	}
	delete(db.cell_by_edid)
	for _, refs in db.cell_refs {
		delete(refs)
	}
	delete(db.cell_refs)
	for _, refs in db.actor_refs {
		delete(refs)
	}
	delete(db.actor_refs)
	delete(db.ref_by_id)
	delete(db.enable_parents)
	for _, e in db.worlds {
		delete(e)
	}
	delete(db.worlds)
	for k, _ in db.world_by_edid {
		delete(k)
	}
	delete(db.world_by_edid)
	for _, cells in db.world_cells {
		delete(cells)
	}
	delete(db.world_cells)
	delete(db.world_persist)
	delete(db.world_water)
	delete(db.world_location)
	delete(db.cell_at_grid)
	for _, h in db.cell_heights {
		delete(h)
	}
	delete(db.cell_heights)
	delete(db.cell_base_tex)
	for _, d in db.cell_dominant {
		delete(d)
	}
	delete(db.cell_dominant)
	delete(db.ltex_txst)
	for _, p in db.txst_diffuse {
		delete(p)
	}
	delete(db.txst_diffuse)
	delete(db.ltex_grass)
	for _, g in db.grasses {
		delete(g.model)
	}
	delete(db.grasses)
	delete(db.form_kinds)
	for k in db.plugin_slots {delete(k, db.allocator)}
	delete(db.plugin_slots)
	delete(db.zones)
	delete(db.equip_slots)
	for _, t in db.equip_types {delete(t.parents, db.allocator)}
	delete(db.equip_types)
	delete(db.ref_zones)
	delete(db.level_mods)
	delete(db.respawning_containers)
	delete(db.vendor_chests)
	for _, fs in db.form_scripts {
		esm.free_form_scripts(fs, db.allocator)
	}
	delete(db.form_scripts)
	for _, qb in db.quest_baseline {
		free_quest_baseline(db, qb)
	}
	delete(db.quest_baseline)
	free_story_nodes(db)
	free_dialogue(db)
	free_scenes(db)
	delete(db.relationships)
	delete(db.associations)
	delete(db.unique_refs)
	delete(db.alias_targets)
	delete(db.persistent_refs, db.allocator)
	for _, kids in db.linked_children {delete(kids)}
	delete(db.linked_children)
	for _, types in db.ref_types {delete(types)}
	delete(db.ref_types)
	free_form_indexes(db) // keywords, linked refs, factions, spells/enchantments/magic effects
	free_query_indexes(db) // owners, activate parents, ingredients
	free_packages(db)
	free_nav_indexes(db)
	free_actor_indexes(db) // races, classes, voice types, outfits, actor values
	db^ = {}
}

// free_quest_baseline releases a Quest_Baseline's owned maps + resolved-text strings. Shared by
// destroy and the override path (a later plugin replacing the same QUST).
@(private)
free_quest_baseline :: proc(db: ^DB, qb: Quest_Baseline) {
	for _, st in qb.stages {
		for it in st.items {free_conditions(db, it.conditions)}
		delete(st.items, db.allocator)
	}
	delete(qb.stages)
	delete(qb.objectives)
	for _, s in qb.stage_log {
		delete(s, db.allocator)
	}
	delete(qb.stage_log)
	for _, s in qb.objective_text {
		delete(s, db.allocator)
	}
	delete(qb.objective_text)
	for _, ts in qb.objective_targets {
		for t in ts {free_conditions(db, t.conditions)}
		delete(ts, db.allocator)
	}
	delete(qb.objective_targets)
	for a in qb.aliases {
		delete(a.name, db.allocator)
		free_conditions(db, a.conditions)
		delete(a.factions, db.allocator)
		delete(a.keywords, db.allocator)
		delete(a.packages, db.allocator)
	}
	delete(qb.aliases, db.allocator)
	free_conditions(db, qb.dialogue_conditions)
	free_conditions(db, qb.event_conditions)
}

// find_cell looks up an interior cell by editor id (case-insensitive).
find_cell :: proc(db: ^DB, editor_id: string) -> (Cell, bool) {
	key := strings.to_lower(editor_id, context.temp_allocator)
	if fid, ok := db.cell_by_edid[key]; ok {
		return db.cells[fid], true
	}
	return {}, false
}

// find_world looks up a worldspace by editor id (case-insensitive), e.g.
// "WhiterunWorld" -> 0x0001A26F.
find_world :: proc(db: ^DB, editor_id: string) -> (form_id: Form_ID, ok: bool) {
	key := strings.to_lower(editor_id, context.temp_allocator)
	fid, found := db.world_by_edid[key]
	return fid, found
}

// world_persistent_cell returns a worldspace's persistent cell formID — the cell holding its
// worldspace-wide refs (load doors, bridges, city gates) at absolute coords. ok=false if none.
world_persistent_cell :: proc(db: ^DB, world_form_id: Form_ID) -> (cell_form_id: Form_ID, ok: bool) {
	c, found := db.world_persist[world_form_id]
	return c, found
}

// world_editor_id returns a worldspace's editor id by formID ("" if unknown).
world_editor_id :: proc(db: ^DB, world_form_id: Form_ID) -> string {
	if e, ok := db.worlds[world_form_id]; ok {
		return e
	}
	return ""
}

// cells_of returns a worldspace's exterior cell formIDs (empty if none / unknown
// world). Order follows the file (exterior block/sub-block order).
cells_of :: proc(db: ^DB, world_form_id: Form_ID) -> []Form_ID {
	if cells, ok := db.world_cells[world_form_id]; ok {
		return cells[:]
	}
	return nil
}

// cell_at resolves an exterior cell by its worldspace + grid coordinate (the
// streamer's per-cell lookup). ok=false where the grid has no cell (worldspace holes
// — common at the edges of Tamriel).
cell_at :: proc(db: ^DB, world_form_id: Form_ID, gx, gy: i32) -> (cell_form_id: Form_ID, ok: bool) {
	fid, found := db.cell_at_grid[Grid_Key{world_form_id, gx, gy}]
	return fid, found
}

// refs_of returns a cell's placed static references (REFR; empty if none / unknown cell).
refs_of :: proc(db: ^DB, cell_form_id: Form_ID) -> []Ref {
	if refs, ok := db.cell_refs[cell_form_id]; ok {
		return refs[:]
	}
	return nil
}

// actors_of returns a cell's placed actor references (ACHR; empty if none / unknown cell). Each
// ref's `base` is an NPC_ (actor_base resolves it); spawning them as live actors is a consumer.
actors_of :: proc(db: ^DB, cell_form_id: Form_ID) -> []Ref {
	if refs, ok := db.actor_refs[cell_form_id]; ok {
		return refs[:]
	}
	return nil
}

// model_of resolves a base form's mesh path.
model_of :: proc(db: ^DB, base_form_id: Form_ID) -> (string, bool) {
	m, ok := db.base_models[base_form_id]
	return m, ok
}

// lod_model_of resolves a base form's prebaked distant-LOD mesh for detail slot `idx` (0 = highest
// detail/LOD4 … 3 = lowest/LOD32). Clamps to the populated range — a request beyond the last filled
// slot returns the coarsest available, so an object always has *some* LOD mesh once it has any.
// ok=false when the form carries no MNAM LOD models at all (e.g. small clutter — drop at distance).
lod_model_of :: proc(db: ^DB, base_form_id: Form_ID, idx: int) -> (string, bool) {
	arr, ok := db.base_lod[base_form_id]
	if !ok {
		return "", false
	}
	i := clamp(idx, 0, esm.LOD_MODELS - 1)
	for i >= 0 && arr[i] == "" {
		i -= 1
	}
	if i < 0 {
		return "", false
	}
	return arr[i], true
}

// has_lod_models reports whether a base form carries any prebaked distant-LOD meshes.
has_lod_models :: proc(db: ^DB, base_form_id: Form_ID) -> bool {
	return base_form_id in db.base_lod
}

// base_size returns a base form's OBND bounding radius (world units), or 0 if unknown —
// a cheap size proxy for distance/LOD culling without loading the mesh.
base_size :: proc(db: ^DB, base_form_id: Form_ID) -> f32 {
	box := db.base_box[base_form_id]
	d := box[1] - box[0]
	return 0.5 * math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
}

// base_bounds returns a base form's OBND box at scale 1.
base_bounds :: proc(db: ^DB, base_form_id: Form_ID) -> (box: [2][3]f32, ok: bool) {
	box, ok = db.base_box[base_form_id]
	return
}

// ref_by_formid looks up a placed reference by its formID (e.g. an XTEL teleport's
// destination door). Every ref in an indexed cell (interior and exterior) is included.
ref_by_formid :: proc(db: ^DB, form_id: Form_ID) -> (Ref, bool) {
	r, ok := db.ref_by_id[form_id]
	return r, ok
}

// ref_attach_cell is the cell a ref loads and unloads with: its own cell, except an exterior
// persistent ref, which sits in the worldspace's persistent cell and goes with the grid cell under
// its position (as the streamer places it). 0 when that grid cell does not exist.
ref_attach_cell :: proc(db: ^DB, r: Ref) -> Form_ID {
	return grid_cell(db, r.cell_form_id, r.pos)
}

// grid_cell is the cell under `pos` in `cell`: the cell itself, unless it is a worldspace's
// persistent cell, which has no grid; then the grid cell at `pos` (0 when none exists).
grid_cell :: proc(db: ^DB, cell: Form_ID, pos: [3]f32) -> Form_ID {
	c, ok := db.cells[cell]
	if !ok || c.interior || (c.has_grid && db.world_persist[c.world_form_id] != cell) {return cell} // persistent cells carry XCLC 0,0 too
	return cell_under(db, c.world_form_id, pos)
}

// cell_under is the exterior cell of `world` at `pos` (0 when none exists).
cell_under :: proc(db: ^DB, world: Form_ID, pos: [3]f32) -> Form_ID {
	gx, gy := i32(math.floor(pos.x / CELL_SIZE)), i32(math.floor(pos.y / CELL_SIZE))
	cell, _ := cell_at(db, world, gx, gy)
	return cell
}

// cell_terrain returns a cell's LAND heightmap (a row-major esm.LAND_GRID² grid of
// cumulative heights — world Z = value × the terrain height scale). ok=false for
// cells without a LAND record (interiors, and exterior cells that have none).
cell_terrain :: proc(db: ^DB, cell_form_id: Form_ID) -> ([]f32, bool) {
	h, ok := db.cell_heights[cell_form_id]
	return h, ok
}

// cell_water returns a cell's resolved flat-water-plane height (sentinel + worldspace
// default already folded in at index time). ok=false when the cell has no water.
cell_water :: proc(db: ^DB, cell_form_id: Form_ID) -> (height: f32, ok: bool) {
	c, found := db.cells[cell_form_id]
	if !found || c.water_height == esm.WATER_NONE {
		return 0, false
	}
	return c.water_height, true
}

// cell_base_textures returns a cell's per-quadrant base landscape texture formIDs
// (0=SW,1=SE,2=NW,3=NE; 0 where a quadrant has none). ok=false for cells with no LAND
// texture data. Resolve each formID to a diffuse path with landscape_diffuse.
cell_base_textures :: proc(db: ^DB, cell_form_id: Form_ID) -> ([4]Form_ID, bool) {
	bt, ok := db.cell_base_tex[cell_form_id]
	return bt, ok
}

// cell_dominant_texture returns a cell's per-vertex dominant-texture grid (row-major
// esm.LAND_GRID², each the LTEX formID most opaque at that vertex). Drives per-point
// grass type/presence. ok=false for cells without LAND texture layers.
cell_dominant_texture :: proc(db: ^DB, cell_form_id: Form_ID) -> ([]Form_ID, bool) {
	d, ok := db.cell_dominant[cell_form_id]
	return d, ok
}

// grass_for_texture resolves the grass type scattered over terrain painted with an LTEX
// (LTEX → GNAM → GRAS), returning the grass cluster model + density. ok=false if the
// texture has no grass (no GNAM) or the GRAS is unknown.
grass_for_texture :: proc(db: ^DB, ltex_form_id: Form_ID) -> (Grass, bool) {
	gras, ok := db.ltex_grass[ltex_form_id]
	if !ok {
		return {}, false
	}
	g, gok := db.grasses[gras]
	return g, gok
}

// landscape_diffuse resolves an LTEX formID to its diffuse texture path, following
// LTEX → TNAM → TXST → TX00. ok=false if any link is missing.
landscape_diffuse :: proc(db: ^DB, ltex_form_id: Form_ID) -> (string, bool) {
	txst, ok := db.ltex_txst[ltex_form_id]
	if !ok {
		return "", false
	}
	path, pok := db.txst_diffuse[txst]
	return path, pok
}

// cell_by_formid looks up a cell's identity by formID.
cell_by_formid :: proc(db: ^DB, form_id: Form_ID) -> (Cell, bool) {
	c, ok := db.cells[form_id]
	return c, ok
}

// name_of resolves a form's display name (FULL), following ref → base: a REFR's own FULL
// override wins, else its base form's name. Works for a base formID directly too. "" when
// no name is known (unnamed forms, or a localized plugin whose STRINGS table didn't
// resolve). Names come from the localized STRINGS table — sourced through the VFS (loose
// Data/Strings or inside a BSA, see app read_plugin_into) — or inline FULL otherwise.
name_of :: proc(db: ^DB, form: Form_ID) -> string {
	if n, ok := db.names[form]; ok && n != "" {
		return n // the form's own FULL — a base name, or a ref's override
	}
	if r, ok := db.ref_by_id[form]; ok {
		if n, nok := db.names[r.base]; nok {
			return n // ref with no override → its base form's name
		}
	}
	return ""
}

// value_of resolves a form's gold value, following ref → base (a placed item ref inherits its
// base form's value; a base formID works directly). ok=false when the form isn't a valued item
// (statics, actors, or a ref whose base isn't indexed). See item_value_weight for the decode.
value_of :: proc(db: ^DB, form: Form_ID) -> (i32, bool) {
	if v, ok := db.base_value[form]; ok {
		return v, true
	}
	if r, ok := db.ref_by_id[form]; ok {
		if v, vok := db.base_value[r.base]; vok {
			return v, true
		}
	}
	return 0, false
}

// weight_of resolves a form's weight, following ref → base (same resolution as value_of).
// ok=false when the form isn't a valued/carriable item.
weight_of :: proc(db: ^DB, form: Form_ID) -> (f32, bool) {
	if w, ok := db.base_weight[form]; ok {
		return w, true
	}
	if r, ok := db.ref_by_id[form]; ok {
		if w, wok := db.base_weight[r.base]; wok {
			return w, true
		}
	}
	return 0, false
}

// contents_of returns a container's or an actor's starting contents, following ref → base: a CONT's
// CNTO, or an NPC_'s through its inventory template (template_part, `pick` standing in for a leveled
// template). Leveled entries stay as they are (worldstate.inv_start rolls them). The slice is owned
// by the DB. ok=false when the form holds no contents.
contents_of :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> ([]Content_Entry, bool) {
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	if c, ok := db.containers[base]; ok {return c, true}
	a, ok := db.actors[base]
	if !ok {return nil, false}
	return template_part(db, base, esm.ACBS_TEMPLATE_INVENTORY, pick).inventory, true
}

// form_list_of returns an FLST's ordered member forms (remapped to global space). The slice is
// owned by the DB — don't mutate/free it. ok=false when the form isn't an indexed form list. Order
// is significant (member N is the FLST's Nth entry). Members may themselves be any form kind
// (including nested FLSTs); the list is stored flat, resolution/expansion is a consumer concern.
form_list_of :: proc(db: ^DB, form: Form_ID) -> ([]Form_ID, bool) {
	m, ok := db.form_lists[form]
	return m, ok
}

// leveled_list_of returns a LVLI's decoded roll table (chance-none, flags, entries). The entries
// slice is owned by the DB — don't mutate/free it. ok=false when the form isn't an indexed leveled
// list. This is the static data only; rolling an actual outcome (by player level, chance-none,
// nested-list expansion) is a consumer concern the item/loot store owns.
leveled_list_of :: proc(db: ^DB, form: Form_ID) -> (Leveled_List, bool) {
	ll, ok := db.leveled_lists[form]
	return ll, ok
}

// global_value returns a GLOB's static FLTV baseline (the value in an untouched game). ok=false when
// the form isn't an indexed global. This is the BASELINE only — the runtime value is the worldstate
// overlay's override ⊕ this (GlobalVariable.GetValue reads the overlay first, falling back here).
global_value :: proc(db: ^DB, form: Form_ID) -> (f32, bool) {
	v, ok := db.global_values[form]
	return v, ok
}

// actor_base returns an NPC_'s decoded base identity (ok=false when the form isn't an indexed NPC_).
// The struct's slices (spells/packages/inventory) are owned by the DB — don't mutate/free them. The
// player is actor_base(db, 0x00000007). Its display name is in db.names (name_of); race/class/etc.
// are global forms resolvable through the DB. Runtime actor state lives in the worldstate overlay.
actor_base :: proc(db: ^DB, form: Form_ID) -> (Actor_Base, bool) {
	a, ok := db.actors[form]
	return a, ok
}

// ref_effective_disabled reports whether a placed ref is disabled in the STATIC default
// state: its own "Initially Disabled" flag, or its enable parent chain (XESP) gating it off.
// A ref with an enable parent is enabled iff the parent is enabled, XOR the "opposite" flag.
// An unindexed parent keeps the ref (don't over-cull); depth caps a cyclic chain.
ref_effective_disabled :: proc(db: ^DB, r: Ref, depth := 0) -> bool {
	if r.disabled {return true}
	if r.enable_parent == 0 || depth > 16 {return false}
	parent, ok := db.ref_by_id[r.enable_parent]
	if !ok {return false}
	return ref_effective_disabled(db, parent, depth + 1) != r.enable_opposite
}

// enable_chain_has reports whether `parent` gates r somewhere up its enable parent chain.
enable_chain_has :: proc(db: ^DB, r: Ref, parent: Form_ID) -> bool {
	p := r.enable_parent
	for _ in 0 ..< 16 {
		if p == 0 {return false}
		if p == parent {return true}
		up, ok := db.ref_by_id[p]
		if !ok {return false}
		p = up.enable_parent
	}
	return false
}

// --- walk visitor ---

@(private)
visit :: proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
	db := (^DB)(user)
	s := esm.sig(rec)

	// Classify the form's Papyrus class off its signature, independent of what else we index off
	// the record (a WEAP is both an indexed base mesh AND a Weapon handle). Last write wins on
	// override. Absent from base_class → stays Unknown (object-ref / unclassified).
	if k, ok := base_class(s); ok {
		db.form_kinds[rec.form_id] = k
	}

	// Which scripts the form carries, likewise independent of what else we index off it — VMAD sits
	// on 22 different signatures, cutting across base forms, placed refs, quests and magic effects.
	if carries_scripts(s) {
		index_scripts(db, rec, ctx.fm)
	}
	if kind, equips := equip_kind(s); equips {
		index_equip(db, rec, kind, ctx.fm)
	}

	switch {
	case s == "WRLD":
		index_world(db, rec, ctx.fm)
	case s == "CELL":
		index_cell(db, rec, ctx)
	case s == "REFR":
		// Keep refs whose owning cell is already indexed (the CELL record precedes its
		// children GRUP). Interiors and exterior worldspace cells both qualify — the
		// world loader gathers exterior cells by worldspace, the interior loader by cell.
		if _, ok := db.cells[ctx.cell_form_id]; ok {
			index_ref(db, rec, ctx)
			// An exterior ref under a cell's PERSISTENT children GRUP (ctx.temporary=false)
			// marks that cell as the worldspace's persistent cell — it holds worldspace-wide
			// refs (load doors, bridges, gates) at absolute coords, NOT confined to a grid
			// cell. Recorded once (the persistent cell precedes grid cells in world-children).
			if ctx.world_form_id != 0 && !ctx.temporary {
				if _, seen := db.world_persist[ctx.world_form_id]; !seen {
					db.world_persist[ctx.world_form_id] = ctx.cell_form_id
				}
			}
		}
	case s == "ACHR":
		// Actor placement (sibling of REFR; base = an NPC_). Same NAME+DATA layout, so it decodes
		// through the shared ref path but lands in actor_refs — keeping the static-render cell_refs
		// list clean. Only kept once its owning cell is indexed.
		if _, ok := db.cells[ctx.cell_form_id]; ok {
			index_achr(db, rec, ctx)
		}
	case s == "NAVM":
		if ctx.cell_form_id != 0 {index_navmesh(db, rec, ctx.cell_form_id, ctx.fm)}
	case s == "NAVI":
		index_nav_index(db, rec, ctx.fm)
	case s == "LAND":
		// Exterior terrain heightmap. LAND lives in its cell's children GRUP, so
		// ctx.cell_form_id names the owning cell (set before this record is reached).
		if ctx.cell_form_id != 0 {
			index_land(db, rec, ctx.cell_form_id, ctx.fm)
		}
	case s == "LTEX":
		index_ltex(db, rec, ctx.fm)
	case s == "TXST":
		index_txst(db, rec)
	case s == "GRAS":
		index_gras(db, rec)
	case s == "QUST":
		index_quest(db, rec, ctx.fm)
	case s == "SMBN", s == "SMQN", s == "SMEN":
		index_story_node(db, rec, ctx.fm)
	case s == "DIAL":
		index_topic(db, rec, ctx.fm)
	case s == "DLBR":
		index_branch(db, rec, ctx.fm)
	case s == "INFO":
		index_info(db, rec, ctx.topic_form_id, ctx.fm)
	case s == "SCEN":
		index_scene(db, rec, ctx.fm)
	case s == "RELA":
		index_relationship(db, rec, ctx.fm)
	case s == "ASTP":
		index_association(db, rec)
	case s == "CONT":
		index_base(db, rec, ctx.fm) // container mesh + name (CONT is a base type)
		index_container(db, rec, ctx.fm) // its CNTO baseline inventory
	case s == "FLST":
		index_form_list(db, rec, ctx.fm) // its LNAM ordered members
	case s == "LVLI", s == "LVSP", s == "LVLN":
		// One roll-table shape (LVLD/LVLF/LVLO) shared by leveled items, spells and actors.
		index_leveled_list(db, rec, ctx.fm)
	case s == "KYWD":
		index_keyword(db, rec) // a keyword's identity IS its editor id (no FULL)
	case s == "FACT":
		index_faction(db, rec, ctx.fm) // flags, relations, rank ladder, crime bounties
	case s == "SPEL":
		index_spell(db, rec, ctx.fm, scroll = false)
	case s == "SCRL":
		index_base(db, rec, ctx.fm) // a scroll is a carriable item (mesh + name + value/weight) …
		index_spell(db, rec, ctx.fm, scroll = true) // … AND a spell (same SPIT block)
	case s == "ALCH":
		index_base(db, rec, ctx.fm) // a potion is a carriable item …
		index_potion(db, rec, ctx.fm) // … with effects
	case s == "ENCH":
		index_enchantment(db, rec, ctx.fm)
	case s == "MGEF":
		index_magic_effect(db, rec, ctx.fm)
	case s == "LCTN":
		index_location(db, rec, ctx.fm)
	case s == "ECZN":
		index_encounter_zone(db, rec, ctx.fm)
	case s == "EQUP":
		index_equip_type(db, rec, ctx.fm)
	case s == "WTHR":
		index_weather(db, rec, ctx.fm)
	case s == "RACE":
		index_race(db, rec, ctx.fm)
	case s == "CLAS":
		index_class(db, rec)
	case s == "VTYP":
		index_voice_type(db, rec)
	case s == "OTFT":
		index_outfit(db, rec, ctx.fm)
	case s == "AVIF":
		index_actor_value(db, rec, ctx.fm) // identity + its perk-tree nodes
	case s == "GLOB":
		index_glob(db, rec) // its FLTV baseline value
	case s == "GMST":
		index_gmst(db, rec) // its typed DATA value, keyed by editor id
	case s == "MESG":
		index_message(db, rec, ctx.fm) // its title/body/button text
	case s == "PERK":
		index_perk(db, rec, ctx.fm) // its name/description/rank link (entries stay undecoded)
	case s == "COBJ":
		index_recipe(db, rec, ctx.fm) // its ingredients, result and workbench (conditions stay undecoded)
	case s == "LSCR":
		index_lscr(db, rec) // its DESC loading-tip text (we skip the NNAM 3D model)
	case s == "NPC_":
		index_npc(db, rec, ctx.fm) // actor base identity (stats, links, inventory, name)
	case s == "PACK":
		index_package(db, rec, ctx.fm)
	case s == "INGR":
		index_base(db, rec, ctx.fm)
		index_ingredient(db, rec, ctx.fm)
	case is_base_type(s):
		index_base(db, rec, ctx.fm)
	}
	return true
}

// index_edid names a quest, an NPC_, a package or a placed ref for the console.
@(private)
index_edid :: proc(db: ^DB, form: Form_ID, fl: []esm.Field) {
	edid := esm.editor_id(fl)
	if edid == "" {return}
	key := strings.to_lower(edid, context.temp_allocator)
	if _, seen := db.form_by_edid[key]; !seen {key = strings.clone(key, db.allocator)}
	db.form_by_edid[key] = form
}

// find_form is the form an editor id names, case-insensitive. An NPC_ base names its placed actor
// with the lowest form id, so the console can use the base's name, not the ref id.
find_form :: proc(db: ^DB, edid: string) -> (Form_ID, bool) {
	form, ok := db.form_by_edid[strings.to_lower(edid, context.temp_allocator)]
	if !ok || !is_actor(db, form) {return form, ok}
	placed := max(Form_ID)
	for _, refs in db.actor_refs {
		for r in refs {if r.base == form {placed = min(placed, r.form_id)}}
	}
	return form if placed == max(Form_ID) else placed, true
}

// form_from_file is Game.GetFormFromFile: a plugin-local form id in global space. ok=false when the
// plugin is not loaded. Whether the form exists is not checked.
form_from_file :: proc(db: ^DB, local: u32, file: string) -> (Form_ID, bool) {
	slot, ok := db.plugin_slots[strings.to_lower(file, context.temp_allocator)]
	if !ok {return 0, false}
	return Form_ID(slot) << 32 | Form_ID(local & 0x00FF_FFFF), true
}

// form_kind returns a form's Papyrus class kind (QUST/GLOB/FACT), or Unknown for object refs and
// anything not specially classified. Safe on a nil DB (→ Unknown). Drives script method-dispatch:
// which class chain a bare form-handle resolves methods up.
form_kind :: proc(db: ^DB, form: Form_ID) -> Form_Kind {
	if db == nil {
		return .Unknown
	}
	if quest, id, ok := formid.alias_key(form); ok {
		a, _ := quest_alias(db, quest, id)
		return .Location_Alias if a.location else .Ref_Alias
	}
	if formid.is_effect(form) {return .Active_Effect}
	return db.form_kinds[form] // absent → zero value == .Unknown
}

// index_quest decodes a QUST's script-relevant baseline: the DNAM "Start Game Enabled" flag, the
// defined stages (INDX index + the following QSDT "Complete Quest" flag), the alias slots its
// scripts address by id (see index_quest_aliases), and the journal DISPLAY text — each stage's log entry (CNAM) and each objective's display line (QOBJ index + NNAM) and targets (QSTA + its CTDA run). Field
// order matters: a QSDT/CNAM applies to the most recent INDX, an NNAM to the most recent QOBJ (xEdit's
// grouping) — so we walk the subrecords in order. CNAM/NNAM resolve through the plugin STRINGS table
// (or inline for a non-localized plugin), so the stored text is the real English the journal shows.
@(private)
index_quest :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	index_edid(db, rec.form_id, fl)

	if old, existed := db.quest_baseline[rec.form_id]; existed {
		free_quest_baseline(db, old) // override: free the previous clone
	}
	qb := Quest_Baseline {
		stages            = make(map[u16]Quest_Stage, 16, db.allocator),
		objectives        = make(map[u16]bool, 8, db.allocator),
		stage_log         = make(map[u16]string, 16, db.allocator),
		objective_text    = make(map[u16]string, 8, db.allocator),
		objective_targets = make(map[u16][]Objective_Target, 8, db.allocator),
	}
	cur_stage: u16
	have_stage := false
	items := make(map[u16][dynamic]Stage_Item, 16, context.temp_allocator)
	targets := make(map[u16][dynamic]Objective_Target, 8, context.temp_allocator)
	cur_obj: u16
	have_obj := false
	past_next := false
	for f, i in fl {
		switch f.type {
		case "DNAM":
			// DNAM flags u16: 0x01 Start Game Enabled, 0x100 Run Once; then the priority byte.
			if len(f.data) >= 2 {
				qb.start_game_enabled = f.data[0] & 0x01 != 0
				qb.run_once = f.data[1] & 0x01 != 0
			}
			if len(f.data) >= 3 {qb.priority = f.data[2]}
		case "ENAM":
			if len(f.data) >= 4 {copy(qb.event[:], f.data[:4])}
		case "CTDA":
			// The run before NEXT is the dialogue conditions; later runs are taken by the field they follow.
			if !past_next && !have_stage && qb.dialogue_conditions == nil {
				qb.dialogue_conditions = index_conditions(db, esm.condition_run(fl, i), fm)
			}
		case "NEXT":
			past_next = true
			qb.event_conditions = index_conditions(db, esm.condition_run(fl, i + 1), fm)
		case "INDX":
			// int16 journal index (bytes 0-1) + a flags byte. Presence marks the stage as defined.
			if len(f.data) >= 2 {
				cur_stage = u16(f.data[0]) | u16(f.data[1]) << 8
				have_stage = true
				st := qb.stages[cur_stage]
				if len(f.data) >= 3 {st.flags = f.data[2]}
				qb.stages[cur_stage] = st
				if cur_stage not_in items {items[cur_stage] = make([dynamic]Stage_Item, context.temp_allocator)}
			}
		case "QSDT":
			// Starts one stage item (log entry) of the current INDX; its CTDA run follows.
			if have_stage && len(f.data) >= 1 {
				conds := index_conditions(db, esm.condition_run(fl, i + 1), fm)
				append(&items[cur_stage], Stage_Item{flags = f.data[0], conditions = conds})
			}
		case "CNAM":
			// Journal log-entry text for the current stage. Long-text lstring → DLSTRINGS (or inline
			// for a non-localized plugin). A stage may have several QSDT/CNAM pairs (per-condition
			// variants) — last one wins as the representative.
			if have_stage {
				if txt := resolve_lstring(db, f, db.cur_dlstrings); txt != "" {
					if old, seen := qb.stage_log[cur_stage]; seen {
						delete(old, db.allocator)
					}
					qb.stage_log[cur_stage] = strings.clone(txt, db.allocator)
				}
			}
		case "QOBJ":
			// int16 objective index — a defined objective (Complete/FailAllObjectives target all of these).
			if len(f.data) >= 2 {
				cur_obj = u16(f.data[0]) | u16(f.data[1]) << 8
				have_obj = true
				qb.objectives[cur_obj] = true
			}
		case "QSTA":
			// Target alias (s32) + flags (u8); its CTDA run follows.
			if have_obj && len(f.data) >= 5 {
				if cur_obj not_in targets {targets[cur_obj] = make([dynamic]Objective_Target, context.temp_allocator)}
				append(&targets[cur_obj], Objective_Target {
					alias      = i32(u32(f.data[0]) | u32(f.data[1]) << 8 | u32(f.data[2]) << 16 | u32(f.data[3]) << 24),
					flags      = f.data[4],
					conditions = index_conditions(db, esm.condition_run(fl, i + 1), fm),
				})
			}
		case "NNAM":
			// Objective display text for the current QOBJ. Short-text lstring → STRINGS (or inline).
			if have_obj {
				if txt := resolve_lstring(db, f, db.cur_strings); txt != "" {
					if old, seen := qb.objective_text[cur_obj]; seen {
						delete(old, db.allocator)
					}
					qb.objective_text[cur_obj] = strings.clone(txt, db.allocator)
				}
			}
		}
	}
	for stage, its in items {
		st := &qb.stages[stage]
		st.items = make([]Stage_Item, len(its), db.allocator)
		copy(st.items, its[:])
	}
	for obj, ts in targets {
		qb.objective_targets[obj] = make([]Objective_Target, len(ts), db.allocator)
		copy(qb.objective_targets[obj], ts[:])
	}
	qb.aliases = index_quest_aliases(db, fl, fm)
	db.quest_baseline[rec.form_id] = qb
}

// resolve_lstring reads a localized-string subrecord: for a localized plugin its 4 bytes are a
// string id resolved in `table` (the caller picks .STRINGS vs .DLSTRINGS per subrecord kind);
// otherwise the field is an inline zstring and `table` is ignored. Returns "" when absent/
// unresolved. The returned string borrows (the caller clones before storing).
@(private)
resolve_lstring :: proc(db: ^DB, f: esm.Field, table: map[u32]string) -> string {
	if db.cur_localized {
		if sid, ok := esm.lstring_id(f); ok {
			return strtab.lookup(table, sid)
		}
		return ""
	}
	// Inline zstring — drop the trailing NUL if present.
	if len(f.data) == 0 {
		return ""
	}
	n := len(f.data)
	if f.data[n - 1] == 0 {
		n -= 1
	}
	return string(f.data[:n])
}

// quest_baseline_of returns a quest's parsed baseline (ok=false if the QUST wasn't indexed — a
// synthetic/empty DB, or a form that isn't a quest). Callers merge it under the worldstate overlay.
quest_baseline_of :: proc(db: ^DB, quest: Form_ID) -> (Quest_Baseline, bool) {
	if db == nil {
		return {}, false
	}
	qb, ok := db.quest_baseline[quest]
	return qb, ok
}

// quest_start_game_enabled reports whether an untouched quest is running from a new game (DNAM flag).
quest_start_game_enabled :: proc(db: ^DB, quest: Form_ID) -> bool {
	qb, ok := quest_baseline_of(db, quest)
	return ok && qb.start_game_enabled
}

// quest_stage_exists returns whether `stage` is a defined stage of `quest`, and whether the quest's
// baseline is even known (known=false → no QUST parsed, so the caller shouldn't validate against it).
quest_stage_exists :: proc(db: ^DB, quest: Form_ID, stage: u16) -> (exists: bool, known: bool) {
	qb, ok := quest_baseline_of(db, quest)
	if !ok {
		return false, false
	}
	_, exists = qb.stages[stage]
	return exists, true
}

// quest_stage returns one defined stage of a quest.
quest_stage :: proc(db: ^DB, quest: Form_ID, stage: u16) -> (Quest_Stage, bool) {
	qb, ok := quest_baseline_of(db, quest)
	if !ok {return {}, false}
	return qb.stages[stage]
}

// quest_stage_completes reports whether reaching `stage` completes the quest (QSDT "Complete Quest").
quest_stage_completes :: proc(db: ^DB, quest: Form_ID, stage: u16) -> bool {
	qb, ok := quest_baseline_of(db, quest)
	if !ok {return false}
	for it in qb.stages[stage].items {
		if it.flags & ITEM_COMPLETE_QUEST != 0 {return true}
	}
	return false
}

// quest_stage_log returns the journal log-entry text shown when `stage` is reached (CNAM, English-
// resolved). ok=false for a silent stage (script-only, no CNAM) or an unknown quest/stage. The
// string is owned by the DB — don't free it. Drives the pause→quest-journal menu.
quest_stage_log :: proc(db: ^DB, quest: Form_ID, stage: u16) -> (string, bool) {
	qb, ok := quest_baseline_of(db, quest)
	if !ok {
		return "", false
	}
	s, has := qb.stage_log[stage]
	return s, has
}

// quest_objective_text returns objective `obj`'s display line (NNAM, English-resolved). ok=false for
// an unknown quest/objective. The string is owned by the DB — don't free it.
quest_objective_text :: proc(db: ^DB, quest: Form_ID, obj: u16) -> (string, bool) {
	qb, ok := quest_baseline_of(db, quest)
	if !ok {
		return "", false
	}
	s, has := qb.objective_text[obj]
	return s, has
}

@(private)
index_world :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	edid := esm.editor_id(fl)
	if old, had := db.worlds[rec.form_id]; had {
		delete(old, db.allocator) // override: free the previous clone
	}
	db.worlds[rec.form_id] = strings.clone(edid, db.allocator)
	if edid != "" {
		key := strings.to_lower(edid, context.temp_allocator)
		if _, seen := db.world_by_edid[key]; !seen {
			db.world_by_edid[strings.clone(key, db.allocator)] = rec.form_id
		}
	}
	// Default water height — the level a child cell's XCLW sentinel resolves to. WRLD
	// precedes its CELL children in the walk, so it's recorded before any cell reads it.
	if wh, wok := esm.world_water_height(fl); wok && abs(wh) <= esm.WATER_MAX_PLAUSIBLE {
		db.world_water[rec.form_id] = wh
	}
	if l, lok := esm.subrecord_formid(fl, "XLCN"); lok {
		db.world_location[rec.form_id] = esm.remap_form(fm, l)
	}
}

@(private)
index_cell :: proc(db: ^DB, rec: esm.Record, ctx: esm.Walk_Context) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below (one-pass build)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	edid := esm.editor_id(fl)
	cell := Cell {
		form_id       = rec.form_id,
		editor_id     = strings.clone(edid, db.allocator),
		interior      = esm.cell_is_interior(fl),
		world_form_id = ctx.world_form_id,
		water_height  = esm.WATER_NONE,
	}
	// Resolve the cell's water height once, here: a real XCLW wins; the WATER_NONE
	// sentinel (FLT_MAX) falls back to the worldspace default (the ocean at sea level —
	// most exterior cells use this); no XCLW at all (interiors, border cells) = no water.
	if h, hok := esm.cell_water_height(fl); hok {
		if h == esm.WATER_NONE {
			if def, dok := db.world_water[ctx.world_form_id]; dok {
				cell.water_height = def
			}
		} else if abs(h) <= esm.WATER_MAX_PLAUSIBLE {
			cell.water_height = h
		}
		// else: a non-FLT_MAX "no water" marker (e.g. 0xCF000000) → leave WATER_NONE.
	}
	if wt, tok := esm.cell_water_type(fl); tok {
		cell.water_type = esm.remap_form(ctx.fm, wt) // XCWT references a WATR form
	}
	if l, lok := esm.subrecord_formid(fl, "XLCN"); lok {
		cell.location = esm.remap_form(ctx.fm, l)
	}
	if z, zok := esm.subrecord_formid(fl, "XEZN"); zok {
		cell.zone = esm.remap_form(ctx.fm, z)
	}
	index_owner(db, rec.form_id, fl, ctx.fm)
	if gx, gy, gok := esm.cell_grid(fl); gok {
		cell.gx, cell.gy, cell.has_grid = gx, gy, true
		if ctx.world_form_id != 0 {
			db.cell_at_grid[Grid_Key{ctx.world_form_id, gx, gy}] = rec.form_id
		}
	}
	old, existed := db.cells[rec.form_id]
	if existed {
		delete(old.editor_id, db.allocator) // override: free the previous clone
	}
	db.cells[rec.form_id] = cell
	// A named cell (interior shops/dungeons: "Riverwood Trader", "Bleak Falls Barrow") carries a
	// FULL — index it into db.names so a load door's destination prompt shows the real place name
	// instead of the editor id (door_dest_label prefers it). Wilderness exterior cells have none.
	index_name(db, rec.form_id, fl)
	if edid != "" {
		key := strings.to_lower(edid, context.temp_allocator)
		if _, seen := db.cell_by_edid[key]; !seen {
			db.cell_by_edid[strings.clone(key, db.allocator)] = rec.form_id
		}
	}
	// Group exterior cells under their worldspace so the world loader can gather them —
	// only on first sighting, so an override doesn't list the same cell twice.
	if ctx.world_form_id != 0 && !existed {
		cells, found := &db.world_cells[ctx.world_form_id]
		if !found {
			db.world_cells[ctx.world_form_id] = make([dynamic]Form_ID, 0, 64, db.allocator)
			cells = &db.world_cells[ctx.world_form_id]
		}
		append(cells, rec.form_id)
	}
}

// index_name decodes a record's FULL display name into db.names[form], branching on the
// current plugin's localized flag: localized → a u32 string id resolved in cur_strings;
// otherwise the inline zstring. Skips empty/unresolved names. `form` is already global —
// a base form's own name, or a REFR's FULL override. A later plugin (last write wins)
// replaces the previous clone.
@(private)
index_name :: proc(db: ^DB, form: Form_ID, fl: []esm.Field) {
	name: string
	if db.cur_localized {
		if sid, ok := esm.full_string_id(fl); ok {
			name = strtab.lookup(db.cur_strings, sid)
		}
	} else {
		name = esm.full_name(fl)
	}
	if name == "" {
		return
	}
	if old, ok := db.names[form]; ok {
		delete(old, db.allocator) // override: free the previous clone
	}
	db.names[form] = strings.clone(name, db.allocator)
}

@(private)
index_ref :: proc(db: ^DB, rec: esm.Record, ctx: esm.Walk_Context) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	cell_form_id := ctx.cell_form_id
	p := esm.decode_refr(fl)
	ref := Ref {
		form_id      = rec.form_id,
		cell_form_id = cell_form_id,
		base         = esm.remap_form(ctx.fm, p.base), // NAME references a base form
		pos          = p.pos,
		rot          = p.rot,
		scale        = p.scale,
		count        = p.count,
		// "Initially Disabled" OR a DELETED override (a plugin removing a master's ref):
		// either way the ref isn't placed. Treating delete as disable keeps the slot so the
		// override replaces in place rather than leaving a hole.
		disabled     = rec.flags & (REFR_INITIALLY_DISABLED | REFR_DELETED) != 0,
		deleted      = rec.flags & REFR_DELETED != 0,
		persistent   = !ctx.temporary,
		no_respawn   = rec.flags & REFR_NO_RESPAWN != 0,
	}
	if tp, has := esm.refr_teleport(fl); has {
		tp.door = esm.remap_form(ctx.fm, u32(tp.door)) // XTEL references the destination door
		ref.teleport = tp
		ref.has_tp = true
	}
	if ep, has := esm.refr_enable_parent(fl); has {
		ref.enable_parent = esm.remap_form(ctx.fm, ep.parent) // XESP references the parent ref
		ref.enable_opposite = ep.opposite
	}
	if pr, has := esm.refr_primitive(fl); has && (pr.kind == .Box || pr.kind == .Sphere) {
		db.triggers[rec.form_id] = pr
	} else {
		delete_key(&db.triggers, rec.form_id)
	}
	if lk, has := esm.decode_xloc(fl); has {
		lk.key = esm.remap_form(ctx.fm, u32(lk.key)) // XLOC key references a KEYM form
		db.locks[rec.form_id] = lk // presence = this ref starts locked (the activation-prompt signal)
	} else if _, was := db.ref_index[rec.form_id]; was {
		delete_key(&db.locks, rec.form_id) // override removed the lock — drop the stale baseline
	}

	// Override: a later plugin re-declaring this REFR formID replaces it in place (preserves
	// cell-array order). Otherwise append and remember where it landed. (A relocation to a
	// different cell — vanishingly rare in the official masters — replaces the old slot.)
	if loc, seen := db.ref_index[rec.form_id]; seen {
		db.cell_refs[loc.cell][loc.idx] = ref
	} else {
		refs, found := &db.cell_refs[cell_form_id]
		if !found {
			db.cell_refs[cell_form_id] = make([dynamic]Ref, 0, 64, db.allocator)
			refs = &db.cell_refs[cell_form_id]
		}
		append(refs, ref)
		db.ref_index[rec.form_id] = Ref_Loc{cell_form_id, len(refs) - 1}
	}
	db.ref_by_id[rec.form_id] = ref
	if ref.enable_parent != 0 {db.enable_parents[ref.enable_parent] = true}
	index_ref_levels(db, rec.form_id, fl, ctx.fm)
	index_ref_ties(db, rec.form_id, fl, ctx.fm)
	index_name(db, rec.form_id, fl) // a REFR may carry a FULL override (a uniquely-named placement)
	index_edid(db, rec.form_id, fl)
	index_linked_refs(db, rec.form_id, fl, ctx.fm) // XLKR links (GetLinkedRef's baseline)
}

// index_achr indexes an actor placement (ACHR) into actor_refs — the base is an NPC_, the transform
// decodes through the shared REFR path (identical NAME+DATA layout). Kept separate from cell_refs so
// the static-world render/cull path never sees actors (their base carries no mesh). Overrides dedup
// in place via actor_ref_index. Also registered in ref_by_id (a placed-form lookup spans both).
@(private)
index_achr :: proc(db: ^DB, rec: esm.Record, ctx: esm.Walk_Context) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	p := esm.decode_refr(fl)
	ref := Ref {
		form_id      = rec.form_id,
		cell_form_id = ctx.cell_form_id,
		base         = esm.remap_form(ctx.fm, p.base), // NAME references the actor's base NPC_
		pos          = p.pos,
		rot          = p.rot,
		scale        = p.scale,
		disabled     = rec.flags & (REFR_INITIALLY_DISABLED | REFR_DELETED) != 0,
		deleted      = rec.flags & REFR_DELETED != 0,
		persistent   = !ctx.temporary,
		no_respawn   = rec.flags & REFR_NO_RESPAWN != 0,
	}
	if ep, has := esm.refr_enable_parent(fl); has {
		ref.enable_parent = esm.remap_form(ctx.fm, ep.parent)
		ref.enable_opposite = ep.opposite
	}
	if loc, seen := db.actor_ref_index[rec.form_id]; seen {
		db.actor_refs[loc.cell][loc.idx] = ref // override in place
	} else {
		refs, found := &db.actor_refs[ctx.cell_form_id]
		if !found {
			db.actor_refs[ctx.cell_form_id] = make([dynamic]Ref, 0, 16, db.allocator)
			refs = &db.actor_refs[ctx.cell_form_id]
		}
		append(refs, ref)
		db.actor_ref_index[rec.form_id] = Ref_Loc{ctx.cell_form_id, len(refs) - 1}
	}
	db.ref_by_id[rec.form_id] = ref
	if ref.enable_parent != 0 {db.enable_parents[ref.enable_parent] = true}
	index_ref_levels(db, rec.form_id, fl, ctx.fm)
	index_ref_ties(db, rec.form_id, fl, ctx.fm)
	index_name(db, rec.form_id, fl) // a uniquely-named actor placement may carry a FULL override
	index_edid(db, rec.form_id, fl)
	index_linked_refs(db, rec.form_id, fl, ctx.fm) // XLKR: patrol routes, package targets, family links
}

// index_ref_levels records a placement's own encounter zone (XEZN) and leveled difficulty (XLCM); an
// override without them drops the earlier plugin's.
@(private)
index_ref_levels :: proc(db: ^DB, id: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	if z, ok := esm.subrecord_formid(fl, "XEZN"); ok {
		db.ref_zones[id] = esm.remap_form(fm, z)
	} else {
		delete_key(&db.ref_zones, id)
	}
	if m, ok := esm.subrecord_formid(fl, "XLCM"); ok {
		db.level_mods[id] = u8(m)
	} else {
		delete_key(&db.level_mods, id)
	}
}

@(private)
index_land :: proc(db: ^DB, rec: esm.Record, cell_form_id: Form_ID, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if h, hok := esm.land_heights(fl, db.allocator); hok {
		if old, exists := db.cell_heights[cell_form_id]; exists {
			delete(old, db.allocator) // override: free the previous heightmap
		}
		db.cell_heights[cell_form_id] = h
	}
	if raw := esm.land_base_textures(fl); raw != {} {
		bt: [4]Form_ID
		for q, i in raw {
			bt[i] = esm.remap_form(fm, q) // each quadrant base is an LTEX form
		}
		db.cell_base_tex[cell_form_id] = bt
	}

	// Build the per-vertex dominant-texture grid (esm.LAND_GRID²): start each quadrant at
	// its base texture, then let any ATXT layer with higher opacity at a vertex win. Drives
	// per-point grass type + presence (so grass follows the painted texture, not a coarse
	// per-quadrant base). Layers come base-first per quadrant.
	// The free must not hang off the len>0 guard: land_layers allocates its backing array up
	// front, so a LAND with no painted layers (5309 of them in Skyrim.esm) would leak it.
	if layers, lok := esm.land_layers(fl, context.allocator); lok {
		defer esm.free_land_layers(layers, context.allocator)
		if len(layers) == 0 {
			return
		}
		G :: esm.LAND_GRID
		Q :: G / 2 // 16: a quadrant is 17×17 sharing the centre line at index 16
		dom := make([]Form_ID, G * G, db.allocator)
		opac := make([]f32, G * G) // heap scratch; freed below (walk has no temp reset)
		defer delete(opac)
		for layer in layers {
			ltex := esm.remap_form(fm, layer.ltex) // the painted LTEX, in global space
			x0 := int(layer.quadrant & 1) * Q
			y0 := int((layer.quadrant >> 1) & 1) * Q
			if layer.base {
				for ly in 0 ..= Q {
					for lx in 0 ..= Q {
						gi := (y0 + ly) * G + (x0 + lx)
						if opac[gi] <= 0 {
							dom[gi] = ltex
							opac[gi] = 0.0001 // baseline so any painted layer wins
						}
					}
				}
			} else {
				for a in layer.alpha {
					lx, ly := int(a.point % (Q + 1)), int(a.point / (Q + 1))
					if lx > Q || ly > Q {
						continue
					}
					gi := (y0 + ly) * G + (x0 + lx)
					if a.opacity >= opac[gi] {
						opac[gi] = a.opacity
						dom[gi] = ltex
					}
				}
			}
		}
		if old, exists := db.cell_dominant[cell_form_id]; exists {
			delete(old, db.allocator) // override: free the previous dominant grid
		}
		db.cell_dominant[cell_form_id] = dom
	}
}

@(private)
index_ltex :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if txst, has := esm.landscape_txst(fl); has {
		db.ltex_txst[rec.form_id] = esm.remap_form(fm, txst) // TNAM references a TXST form
	}
	if gras, has := esm.landscape_grass(fl); has {
		db.ltex_grass[rec.form_id] = esm.remap_form(fm, gras) // GNAM references a GRAS form
	}
}

@(private)
index_gras :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	model := esm.model_path(fl)
	if model == "" {
		return
	}
	density, _ := esm.grass_density(fl)
	if old, had := db.grasses[rec.form_id]; had {
		delete(old.model, db.allocator) // override: free the previous model clone
	}
	db.grasses[rec.form_id] = Grass{model = strings.clone(model, db.allocator), density = density}
}

// index_container decodes a CONT's CNTO baseline inventory: each {item, count}, with the item
// formID remapped to global space. Stored as an owned Content_Entry slice keyed by the container
// form. A later plugin overriding the same CONT replaces the list (free the old one first).
@(private)
index_container :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if esm.container_respawns(fl) {
		db.respawning_containers[rec.form_id] = true
	} else {
		delete_key(&db.respawning_containers, rec.form_id)
	}
	raw := esm.container_contents(fl, context.allocator) // walk has no temp reset — explicit free
	if raw == nil {
		return
	}
	defer delete(raw, context.allocator)
	entries := make([]Content_Entry, len(raw), db.allocator)
	for c, i in raw {
		entries[i] = Content_Entry{item = esm.remap_form(fm, c.item), count = c.count}
	}
	if old, exists := db.containers[rec.form_id]; exists {
		delete(old, db.allocator) // override: free the previous inventory
	}
	db.containers[rec.form_id] = entries
}

// index_form_list decodes an FLST's LNAM ordered members, each remapped to global space. Stored as
// an owned Form_ID slice keyed by the list form. A later plugin overriding the same FLST replaces
// the list wholesale (free the old one first) — vanilla FLST overrides re-declare all members.
@(private)
index_form_list :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	raw := esm.form_list_members(fl, context.allocator) // walk has no temp reset — explicit free
	if raw == nil {
		return
	}
	defer delete(raw, context.allocator)
	members := make([]Form_ID, len(raw), db.allocator)
	for m, i in raw {
		members[i] = esm.remap_form(fm, m)
	}
	if old, exists := db.form_lists[rec.form_id]; exists {
		delete(old, db.allocator) // override: free the previous member list
	}
	db.form_lists[rec.form_id] = members
}

// index_leveled_list decodes a LVLI's roll table — chance-none, flags, and each {level, form, count}
// entry with the form remapped to global space. Stored owned, keyed by the list form. A later plugin
// overriding the same LVLI replaces the table wholesale (free the old entries first). Decode only:
// no rolling happens here (see leveled_list_of).
@(private)
index_leveled_list :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	chance, flags, raw, global := esm.leveled_list(fl, context.allocator) // walk has no temp reset — explicit free
	defer if raw != nil {delete(raw, context.allocator)}
	entries: []Leveled_Entry
	if raw != nil {
		entries = make([]Leveled_Entry, len(raw), db.allocator)
		for e, i in raw {
			entries[i] = Leveled_Entry {
				level = e.level,
				form  = esm.remap_form(fm, e.item),
				count = e.count,
			}
		}
	}
	if old, exists := db.leveled_lists[rec.form_id]; exists {
		delete(old.entries, db.allocator) // override: free the previous table
	}
	db.leveled_lists[rec.form_id] = Leveled_List{chance, esm.remap_form(fm, global) if global != 0 else 0, flags, entries}
}

// index_glob decodes a GLOB's FLTV baseline value into global_values. This is the STATIC default; at
// runtime worldstate.globals overrides it (a scripted SetValue). A later plugin overriding the same
// GLOB replaces the baseline (last write wins). Non-FLTV globals (malformed) are skipped.
@(private)
index_glob :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if v, _, vok := esm.global_value(fl); vok {
		db.global_values[rec.form_id] = v
	}
	if edid := esm.editor_id(fl); edid != "" {
		lower := strings.to_lower(edid, db.allocator)
		if _, seen := db.global_by_edid[lower]; seen {delete(lower, db.allocator)}
		db.global_by_edid[lower] = rec.form_id
	}
}

// global_by_editor_id resolves a GLOB's editor id, any case.
global_by_editor_id :: proc(db: ^DB, edid: string) -> (Form_ID, bool) {
	return db.global_by_edid[strings.to_lower(edid, context.temp_allocator)]
}

// Game_Setting is a GMST's resolved value. The record's editor-id prefix picks the variant, so a
// consumer that knows the setting knows its variant ("fJumpHeightMin" is always the f32).
Game_Setting :: union {
	f32,
	i32,
	bool,
	string, // owned by the DB
}

// index_gmst decodes a GMST into settings, keyed by its LOWER-CASED editor id. The name is the only
// access path a consumer has (Game.GetGameSettingFloat("fJumpHeightMin")), and it is also what a
// later plugin overriding the setting collides on — GMSTs override by name, so keying by name gets
// load-order precedence for free (last write wins). A String setting's DATA resolves through the
// PLAIN STRINGS table: verified against Skyrim.esm, 920 of its 929 string settings resolve there
// and 0 in DLSTRINGS; the remaining 9 carry id 0 and are deliberately empty.
@(private)
index_gmst :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	name, kind, data, gok := esm.game_setting(fl)
	if !gok {
		return
	}

	value: Game_Setting
	switch kind {
	case 'f':
		f, _ := esm.setting_number(data)
		value = f
	case 'i':
		_, i := esm.setting_number(data)
		value = i
	case 'b':
		_, i := esm.setting_number(data)
		value = i != 0
	case 's':
		value = strings.clone(resolve_lstring(db, data, db.cur_strings), db.allocator)
	case:
		return // an unrecognized prefix declares no type — nothing to store
	}

	key := strings.to_lower(name, context.temp_allocator)
	if old, existed := db.settings[key]; existed {
		if text, is_text := old.(string); is_text {
			delete(text, db.allocator) // the override replaces the previous plugin's string
		}
		db.settings[key] = value
		return
	}
	db.settings[strings.clone(key, db.allocator)] = value
}

// Message is a MESG record — the text a `Message.Show` call puts on screen. Skyrim uses one record
// type for two surfaces: with `message_box` set it is a modal with buttons, and without it a
// corner notification. Verified against Skyrim.esm: 571 records, 384 message boxes and 186
// notifications (1 record sets neither bit).
Message :: struct {
	title:        string,   // FULL, owned. "" when absent — 354 of the 571 carry one.
	body:         string,   // DESC, owned. The message text itself.
	buttons:      []string, // ITXT in record order, owned. Empty = the menu supplies one default button.
	quest:        Form_ID,  // QNAM owning quest, remapped. 0 when absent (46 of 571 name one).
	display_time: u32,      // TNAM seconds a notification stays up. 0 = absent, so the menu decides.
	message_box:  bool,     // DNAM bit 0 — modal with buttons, rather than a corner notification.
	auto_display: bool,     // DNAM bit 1 — the menu opens it without a script asking.
}

// free_message releases a Message's owned strings. Shared by destroy + the override path.
@(private)
free_message :: proc(db: ^DB, m: Message) {
	delete(m.title, db.allocator)
	delete(m.body, db.allocator)
	for b in m.buttons {
		delete(b, db.allocator)
	}
	delete(m.buttons, db.allocator)
}

// index_message decodes a MESG into messages. The two text fields sit in DIFFERENT string tables,
// which is the whole reason this walks the subrecords itself: DESC is long text and resolves
// through DLSTRINGS, while FULL and the ITXT button labels are short and resolve through plain
// STRINGS. Verified against Skyrim.esm — 479 of 571 DESC ids resolve in DLSTRINGS and 0 in
// STRINGS (91 carry id 0), while all 354 FULL and all 121 ITXT ids resolve in STRINGS and 0 in
// DLSTRINGS. Validated on PlayerWerewolfCureAreYouSure (0x000F6092): title "Werewolf Cure", body
// "Cast the witch's head into the flames to cure your lycanthropy forever?", buttons Yes / No.
//
// Buttons keep record order, because that order IS the return value of `Message.Show`. The 7 CTDA
// conditions in the base game gate individual buttons; we keep every button and leave that
// filtering to the menu, which is the layer that knows the game state.
// INAM is skipped: it is an icon slot Skyrim never uses (571 of 571 are 0).
@(private)
index_message :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if old, existed := db.messages[rec.form_id]; existed {
		free_message(db, old) // override: free the previous plugin's clone
	}

	msg: Message
	buttons := make([dynamic]string, 0, 4, db.allocator)
	for f in fl {
		switch f.type {
		case "FULL":
			msg.title = strings.clone(resolve_lstring(db, f, db.cur_strings), db.allocator)
		case "DESC":
			msg.body = strings.clone(resolve_lstring(db, f, db.cur_dlstrings), db.allocator)
		case "ITXT":
			append(&buttons, strings.clone(resolve_lstring(db, f, db.cur_strings), db.allocator))
		case "DNAM":
			if len(f.data) >= 1 {
				msg.message_box = f.data[0] & 0x01 != 0
				msg.auto_display = f.data[0] & 0x02 != 0
			}
		case "TNAM":
			if len(f.data) >= 4 {
				msg.display_time = u32(f.data[0]) | u32(f.data[1]) << 8 | u32(f.data[2]) << 16 | u32(f.data[3]) << 24
			}
		case "QNAM":
			if len(f.data) >= 4 {
				local := u32(f.data[0]) | u32(f.data[1]) << 8 | u32(f.data[2]) << 16 | u32(f.data[3]) << 24
				msg.quest = esm.remap_form(fm, local)
			}
		}
	}
	msg.buttons = buttons[:]
	db.messages[rec.form_id] = msg
}

// message_of returns a MESG's decoded text. Borrowed — the DB owns the strings. ok=false when the
// form is not an indexed message.
message_of :: proc(db: ^DB, form: Form_ID) -> (Message, bool) {
	if db == nil {
		return {}, false
	}
	m, ok := db.messages[form]
	return m, ok
}

// setting_of looks a game setting up by name. Names are case-insensitive — a script spells a
// setting however it likes, and the store is keyed lower-cased. Shared by the typed readers below.
@(private)
setting_of :: proc(db: ^DB, name: string) -> (Game_Setting, bool) {
	if db == nil {
		return nil, false
	}
	v, ok := db.settings[strings.to_lower(name, context.temp_allocator)]
	return v, ok
}

// setting_float returns a game setting's value as an f32, coercing an Int or Bool setting the way
// the engine does. `def` comes back for an unknown name or a String setting.
setting_float :: proc(db: ^DB, name: string, def: f32 = 0) -> f32 {
	v, ok := setting_of(db, name)
	if !ok {
		return def
	}
	switch t in v {
	case f32:
		return t
	case i32:
		return f32(t)
	case bool:
		return t ? 1 : 0
	case string:
		return def
	}
	return def
}

// setting_int returns a game setting's value as an i32. A Float setting truncates, as the engine
// does. `def` comes back for an unknown name or a String setting.
setting_int :: proc(db: ^DB, name: string, def: i32 = 0) -> i32 {
	v, ok := setting_of(db, name)
	if !ok {
		return def
	}
	switch t in v {
	case i32:
		return t
	case f32:
		return i32(t)
	case bool:
		return t ? 1 : 0
	case string:
		return def
	}
	return def
}

// setting_bool returns a game setting's value as a bool — non-zero is true for the numeric kinds.
// `def` comes back for an unknown name or a String setting.
setting_bool :: proc(db: ^DB, name: string, def: bool = false) -> bool {
	v, ok := setting_of(db, name)
	if !ok {
		return def
	}
	switch t in v {
	case bool:
		return t
	case i32:
		return t != 0
	case f32:
		return t != 0
	case string:
		return def
	}
	return def
}

// setting_string returns a String game setting's text, already resolved through STRINGS. Borrowed
// — the DB owns it. `def` comes back for an unknown name or a non-String setting.
setting_string :: proc(db: ^DB, name: string, def: string = "") -> string {
	v, ok := setting_of(db, name)
	if !ok {
		return def
	}
	if text, is_text := v.(string); is_text {
		return text
	}
	return def
}

// index_lscr decodes a LoadScreen's DESC — the loading-tip text the load screen shows. LSCR DESC lives
// in the PLAIN STRINGS table (verified against Skyrim.esm: 298/298 DESC ids resolve in STRINGS, 0 in
// DLSTRINGS — unlike a quest journal's CNAM/DESC which ARE in DLSTRINGS), or inline for a non-localized
// plugin. The NNAM 3D model + camera are deliberately skipped (we don't render the spinning model). Tips
// accumulate across plugins (a mod's extra LSCRs add more); no dedup — it's a flat rotation pool.
@(private)
index_lscr :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	f, fok := esm.find_field(fl, "DESC")
	if !fok {
		return
	}
	if txt := resolve_lstring(db, f, db.cur_strings); txt != "" {
		append(&db.load_tips, strings.clone(txt, db.allocator))
	}
	// TIP-SCOPE: lightweight context-weighting (planned). Skyrim gates each LSCR by CTDA conditions +
	// LNAM location links, so entering a place shows that place's tips. To scope tips here: also decode
	// this record's LNAM (location forms) and the worldspace-gating CTDA conditions into a per-tip scope
	// tag (generic vs a set of worldspace/location forms), stored alongside the DESC. Then load_tips_for
	// (below) filters by the load destination. Today the pool is flat (every tip is "generic").
}

// load_tips returns the decoded LSCR loading-tip pool (empty until the DB is built). Borrowed — the
// load screen reads it directly; the DB owns the strings.
//
// TIP-SCOPE: the context-weighted picker goes here — a future load_tips_for(db, world_fid, location_fid)
// that returns the tips scoped to that destination (from the per-tip scope tags decoded in index_lscr)
// concatenated with the generic pool as a fallback. loadui_ready would call it with the load target.
load_tips :: proc(db: ^DB) -> []string {
	if db == nil {
		return {}
	}
	return db.load_tips[:]
}

// free_actor_base releases an Actor_Base's owned slices. Shared by destroy + the override path.
@(private)
free_actor_base :: proc(db: ^DB, a: Actor_Base) {
	delete(a.spells, db.allocator)
	delete(a.perks, db.allocator)
	delete(a.packages, db.allocator)
	delete(a.inventory, db.allocator)
	delete(a.factions, db.allocator)
}

// index_npc decodes an NPC_ into an Actor_Base: its display name (FULL — NPC_ isn't in is_base_type,
// so it's indexed here), ACBS/DNAM stats, the linked race/class/voice/outfit + spell/package forms
// (remapped to global space), and its CNTO starting inventory (reusing the container shape). This is
// the base-identity DATA layer; the player (0x00000007) falls out as the first actor. A later plugin
// overriding the same NPC_ replaces the record (free the old owned slices first).
@(private)
index_npc :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl) // FULL display name (NPC_ carries its own name)
	index_edid(db, rec.form_id, fl)
	index_keywords(db, rec.form_id, fl, fm) // KWDA tag set (ActorTypeNPC, …)

	a: Actor_Base
	if cfg, cok := esm.actor_config(fl); cok {
		a.flags = cfg.flags
		a.level = cfg.level
		a.calc_min = cfg.calc_min
		a.calc_max = cfg.calc_max
		a.speed_mult = cfg.speed_mult
		a.magicka_off = cfg.magicka_off
		a.stamina_off = cfg.stamina_off
		a.health_off = cfg.health_off
		a.template_flags = cfg.template_flags
	}
	if ai, aok := esm.actor_ai(fl); aok {a.ai = ai}
	if ag, aok := esm.actor_aggro(fl); aok {a.aggro = ag}
	if attr, aok := esm.actor_attributes(fl); aok {
		a.skills = attr.skills
		a.skill_offsets = attr.skill_offsets
		a.base_health = attr.health
		a.base_magicka = attr.magicka
		a.base_stamina = attr.stamina
	}
	if r, rok := esm.subrecord_formid(fl, "RNAM"); rok {a.race = esm.remap_form(fm, r)}
	if b, bok := esm.object_box(fl); bok && b != {} {
		a.bounds = b
	}
	if c, cok := esm.subrecord_formid(fl, "CNAM"); cok {a.class = esm.remap_form(fm, c)}
	if v, vok := esm.subrecord_formid(fl, "VTCK"); vok {a.voice = esm.remap_form(fm, v)}
	if o, ook := esm.subrecord_formid(fl, "DOFT"); ook {a.outfit = esm.remap_form(fm, o)}
	if g, gok := esm.subrecord_formid(fl, "GNAM"); gok {a.gift_filter = esm.remap_form(fm, g)}
	if t, tok := esm.subrecord_formid(fl, "TPLT"); tok {a.template = esm.remap_form(fm, t)}
	if d, dok := esm.subrecord_formid(fl, "DPLT"); dok {a.default_packages = esm.remap_form(fm, d)}

	// SPLO spells + PKID packages: repeated single-formID subrecords, remapped in order.
	a.spells = remap_formid_list(db, esm.formid_list(fl, "SPLO", context.allocator), fm)
	a.perks = remap_formid_list(db, esm.formid_list(fl, "PRKR", context.allocator), fm)
	a.packages = remap_formid_list(db, esm.formid_list(fl, "PKID", context.allocator), fm)

	// CNTO starting inventory — same shape as a container's (base item + count), remapped.
	if raw := esm.container_contents(fl, context.allocator); raw != nil {
		defer delete(raw, context.allocator)
		inv := make([]Content_Entry, len(raw), db.allocator)
		for c, i in raw {
			inv[i] = Content_Entry{item = esm.remap_form(fm, c.item), count = c.count}
		}
		a.inventory = inv
	}

	// SNAM baseline faction memberships — what IsInFaction answers before any script joins/leaves.
	if raw := esm.faction_memberships(fl, context.allocator); raw != nil {
		defer delete(raw, context.allocator)
		mem := make([]Faction_Membership, len(raw), db.allocator)
		for m, i in raw {
			mem[i] = Faction_Membership{faction = esm.remap_form(fm, m.faction), rank = m.rank}
		}
		a.factions = mem
	}

	if old, existed := db.actors[rec.form_id]; existed {
		free_actor_base(db, old) // override: free the previous owned slices
	}
	db.actors[rec.form_id] = a
}

// remap_formid_list remaps a raw/local formID slice (from esm.formid_list) into a DB-owned Form_ID
// slice, freeing the input. nil in → nil out (no allocation).
@(private)
remap_formid_list :: proc(db: ^DB, raw: []u32, fm: ^esm.Form_Map) -> []Form_ID {
	if raw == nil {
		return nil
	}
	defer delete(raw, context.allocator)
	out := make([]Form_ID, len(raw), db.allocator)
	for r, i in raw {
		out[i] = esm.remap_form(fm, r)
	}
	return out
}

@(private)
index_txst :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	if path := esm.texture_set_diffuse(fl); path != "" {
		if old, had := db.txst_diffuse[rec.form_id]; had {
			delete(old, db.allocator) // override: free the previous path clone
		}
		db.txst_diffuse[rec.form_id] = strings.clone(path, db.allocator)
	}
}

@(private)
index_base :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	model := esm.armor_ground_model(fl) if rec.type == "ARMO" else esm.model_path(fl)
	if model != "" {
		if old, had := db.base_models[rec.form_id]; had {
			delete(old, db.allocator) // override: free the previous clone
		}
		db.base_models[rec.form_id] = strings.clone(model, db.allocator)
	}
	index_name(db, rec.form_id, fl) // FULL display name (localized id or inline)
	index_keywords(db, rec.form_id, fl, fm) // KWDA tag set (VendorItem*, ArmorHeavy, …)
	// Prebaked distant-LOD meshes (STAT MNAM): clone the populated slots so the LOD rings load
	// Skyrim's own low-poly meshes instead of decimating at runtime.
	if lods, n := esm.lod_model_paths(fl); n > 0 {
		if old, had := db.base_lod[rec.form_id]; had {
			for s in old {
				if s != "" {
					delete(s, db.allocator) // override: free the previous LOD clones
				}
			}
		}
		arr: [esm.LOD_MODELS]string
		for i in 0 ..< esm.LOD_MODELS {
			if lods[i] != "" {
				arr[i] = strings.clone(lods[i], db.allocator)
			}
		}
		db.base_lod[rec.form_id] = arr
	}
	if box, bok := esm.object_box(fl); bok {
		db.base_box[rec.form_id] = box
	}
	// Carriable items (WEAP/ARMO/ALCH/…) carry a gold value + weight; static-world types don't.
	if value, weight, vok := esm.item_value_weight(rec.type, fl); vok {
		db.base_value[rec.form_id] = value
		db.base_weight[rec.form_id] = weight
	}
	if rec.type == "DOOR" {
		db.doors[rec.form_id] = true // door-panel base (open-interiors portal cull)
	}
	if rec.type == "TREE" {
		db.trees[rec.form_id] = true // tree base → distant billboard (the _lod_flat.nif beside the mesh)
	}
	if rec.type == "BOOK" {
		if flags, teaches, ok := esm.book_teaches(fl); ok && flags & esm.BOOK_TEACHES_SKILL != 0 {
			db.books[rec.form_id] = Book{skill = i32(teaches)}
		} else if ok && flags & esm.BOOK_TEACHES_SPELL != 0 {
			db.books[rec.form_id] = Book{skill = -1, spell = esm.remap_form(fm, teaches)}
		}
	}
	if rec.type == "FLOR" || rec.type == "TREE" {
		if p, ok := esm.subrecord_formid(fl, "PFIG"); ok && p != 0 {db.produce[rec.form_id] = esm.remap_form(fm, p)}
	}
}

// Book is what reading a book teaches: a skill (an actor value index), or a spell when skill < 0.
Book :: struct {
	skill: i32,
	spell: Form_ID,
}

// is_tree reports whether a base formID is a TREE record. TREEs carry no MNAM, so the distant-LOD
// path falls back to Skyrim's prebaked billboard (the _lod_flat.nif beside the full mesh) — see
// world.tree_billboard_for.
is_tree :: proc(db: ^DB, base_form_id: Form_ID) -> bool {
	return base_form_id in db.trees
}

// is_door reports whether a base formID is a DOOR record — the reliable door-panel signal
// (record type), independent of whether the placement is a teleport/load door. Used by the
// open-interiors portal cull to hide the door panel filling the doorway opening.
is_door :: proc(db: ^DB, base: Form_ID) -> bool {
	return base in db.doors
}

// is_container reports whether a base formID is a CONT record (an openable container).
is_container :: proc(db: ^DB, base: Form_ID) -> bool {
	return base in db.containers
}

// is_actor reports whether a base formID is an NPC_ record (a talkable/lootable actor).
is_actor :: proc(db: ^DB, base: Form_ID) -> bool {
	return base in db.actors
}

// is_item reports whether a base formID is a carriable, valued item (WEAP/ARMO/ALCH/… — anything
// with a gold value). The takeable-clutter signal.
is_item :: proc(db: ^DB, base: Form_ID) -> bool {
	return base in db.base_value
}

// lock_of returns a placed REFR's baseline lock (its XLOC), if it has one. Presence (ok=true)
// means the reference starts LOCKED; `Lock_Data.level` is the pick difficulty and `.key` the KEYM
// that opens it. The runtime lock state (after picking/scripts) is the worldstate overlay's — see
// the app's effective-lock check, which layers the overlay over this baseline.
lock_of :: proc(db: ^DB, ref_form: Form_ID) -> (esm.Lock_Data, bool) {
	lk, ok := db.locks[ref_form]
	return lk, ok
}
