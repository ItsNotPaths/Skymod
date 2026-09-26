package esm

// Typed decoders for the record subset Iteration 1 (Milestone C) needs: CELL
// metadata, REFR placement + door teleport, and base-form model paths. These read
// fields already split by fields(); strings are returned as views into the field
// bytes (the caller clones what it keeps). Field layouts: UESP "Skyrim Mod:Mod File
// Format". Validated against the real Skyrim.esm (tools/esmdump).

import "core:encoding/endian"
import "core:math"

// CELL DATA flags (first byte). 0x01 = interior cell.
CELL_INTERIOR :: 0x01

// Placement is a REFR's base reference + world transform. rot is XYZ euler radians;
// scale defaults to 1 when no XSCL field is present, count (an item stack) to 1 without XCNT.
Placement :: struct {
	base:  u32,
	pos:   [3]f32,
	rot:   [3]f32,
	scale: f32,
	count: i32,
}

// Teleport is a door REFR's XTEL: the destination door (in some cell) and the marker
// transform the player is placed at on the far side.
Teleport :: struct {
	door: Form_ID, // raw (local) until gamedb remaps it into global space
	pos:  [3]f32,
	rot:  [3]f32,
}

// editor_id returns the record's EDID (editor id), or "" if absent.
editor_id :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "EDID"); ok {
		return cstr(f.data)
	}
	return ""
}

// model_path returns the record's MODL mesh path (e.g. "Furniture\\...\\.nif"), or
// "" if absent. The path is archive-internal (under meshes\), backslash-separated.
model_path :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "MODL"); ok {
		return cstr(f.data)
	}
	return ""
}

// armor_ground_model is an ARMO's world (ground) model: MOD2 (male), else MOD4 (female). Its MODL
// fields are ARMA form IDs, not paths. "" for body-only armor (150 vanilla ARMO have neither).
armor_ground_model :: proc(fields: []Field) -> string {
	for tag in ([]string{"MOD2", "MOD4"}) {
		if f, ok := find_field(fields, tag); ok {return cstr(f.data)}
	}
	return ""
}

// full_name returns a record's FULL as INLINE text — the non-localized path (mod ESPs
// without the localized flag, and any plugin whose FULL is stored as a zstring). "" if
// absent. For a LOCALIZED plugin the FULL bytes are a string id instead — use full_string_id.
full_name :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "FULL"); ok {
		return cstr(f.data)
	}
	return ""
}

// global_value decodes a GLOB record's baseline value. FLTV holds the value as an f32 regardless of
// the FNAM type char ('s' short / 'l' long / 'f' float) — the engine truncates on read for the int
// types, so we keep the raw float and let the consumer round per the declared kind. `kind` is the
// FNAM type char (0 if absent). ok=false when the record carries no FLTV.
global_value :: proc(fields: []Field) -> (value: f32, kind: u8, ok: bool) {
	if f, fok := find_field(fields, "FNAM"); fok && len(f.data) >= 1 {
		kind = f.data[0]
	}
	if f, fok := find_field(fields, "FLTV"); fok && len(f.data) >= 4 {
		return rf32(f.data, 0), kind, true
	}
	return 0, kind, false
}

// game_setting decodes a GMST's name and declared type, and hands back its DATA field undecoded.
// A game setting declares its own type through the first character of its editor id: 'f' float,
// 'i' int, 'b' bool, 's' string. VERIFIED against Skyrim.esm — 1,584 GMSTs, every DATA exactly 4
// bytes (558 'f', 96 'i', 929 's', 1 'b'). A bool is stored as an int. A string's DATA is a
// STRINGS id in a localized plugin ("sOr" -> id 75392 -> "or") and an inline zstring otherwise, so
// the caller resolves that one against its own string table — which is why DATA comes back raw.
// ok=false when the record has no EDID or no DATA, or a numeric setting's DATA is short.
game_setting :: proc(fields: []Field) -> (name: string, kind: u8, data: Field, ok: bool) {
	name = editor_id(fields)
	if name == "" {
		return "", 0, {}, false
	}
	f, fok := find_field(fields, "DATA")
	if !fok {
		return "", 0, {}, false
	}
	kind = name[0]
	if kind != 's' && len(f.data) < 4 {
		return "", 0, {}, false
	}
	return name, kind, f, true
}

// setting_number reads a numeric GMST's DATA as both an f32 and an i32 — the same 4 bytes under
// the two readings its kind selects between ('f' takes the float, 'i' and 'b' the int).
setting_number :: proc(data: Field) -> (value: f32, integer: i32) {
	if len(data.data) < 4 {
		return 0, 0
	}
	return rf32(data.data, 0), i32(rd32(data.data, 0))
}

// lstring_id reads a localized-string subrecord's STRINGS id — its first 4 bytes as a u32. ok=false
// when the field is too short. For any lstring-typed subrecord in a LOCALIZED plugin (CNAM journal
// text, NNAM objective text, DESC, …); a non-localized plugin carries the text inline instead.
lstring_id :: proc(f: Field) -> (u32, bool) {
	if len(f.data) < 4 {
		return 0, false
	}
	return rd32(f.data, 0), true
}

// full_string_id returns a record's FULL as a localized string id (the u32 to resolve in
// the plugin's STRINGS table). ok=false if absent/short. Only meaningful when the plugin's
// TES4 localized flag is set (see esm.Header.localized); otherwise use full_name.
full_string_id :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "FULL"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// Enable_Parent is a REFR's XESP: the parent form whose enabled state gates this ref, and
// whether this ref's effective state is the OPPOSITE of the parent's (flags bit0). A ref
// with an enable parent is only placed when the parent is enabled (XOR opposite) — the hook
// the quest system flips live, and the STATIC default the world cull honors to drop
// quest/alternate debris. door/parent is raw (local) until gamedb remaps it.
Enable_Parent :: struct {
	parent:   u32,
	opposite: bool,
}

// XESP flags bit0: "Set Enable State to Opposite of Parent."
XESP_OPPOSITE :: 0x0000_0001

// refr_enable_parent reads a REFR's XESP enable-parent link, if present. XESP = parent
// formID (u32) + flags (u32). ok=false when the ref has no enable parent (the common case).
refr_enable_parent :: proc(fields: []Field) -> (Enable_Parent, bool) {
	f, ok := find_field(fields, "XESP")
	if !ok || len(f.data) < 8 {
		return {}, false
	}
	return Enable_Parent{parent = rd32(f.data, 0), opposite = rd32(f.data, 4) & XESP_OPPOSITE != 0}, true
}

// LOD_MODELS is how many distant-LOD model slots a STAT's MNAM holds.
LOD_MODELS :: 4

// lod_model_paths reads a STAT's MNAM "Distant LOD" — 4 × char[260] nul-terminated model paths
// (junk after each nul), index 0 = HighDetail (LOD4, nearest) … 3 = LowDetail (LOD32, farthest),
// filled from the front (first empty ⇒ the rest are empty). Paths are MODL-relative (Meshes\…).
// Returns the slots (empties as "") and how many are populated. Strings alias the field data.
lod_model_paths :: proc(fields: []Field) -> (models: [LOD_MODELS]string, count: int) {
	f, ok := find_field(fields, "MNAM")
	if !ok || len(f.data) < LOD_MODELS * 260 {
		return
	}
	for i in 0 ..< LOD_MODELS {
		s := cstr(f.data[i * 260:i * 260 + 260])
		if s == "" {
			break // first empty slot ends the chain
		}
		models[i] = s
		count = i + 1
	}
	return
}

// object_box reads a base form's OBND (object bounds): 6 i16 = min(x,y,z) + max(x,y,z).
// ok=false if absent/short.
object_box :: proc(fields: []Field) -> (box: [2][3]f32, ok: bool) {
	f, fok := find_field(fields, "OBND")
	if !fok || len(f.data) < 12 {
		return {}, false
	}
	for i in 0 ..< 6 {
		box[i / 3][i % 3] = f32(cast(i16)rd16(f.data, 2 * i))
	}
	return box, true
}

// BOOK DATA flags (UESP; build/out/wsP/perks/books.py: 90 skill books, 94 spell tomes in Skyrim.esm).
BOOK_TEACHES_SKILL :: 0x01
BOOK_TEACHES_SPELL :: 0x04

// book_teaches reads a BOOK's DATA flags and the u32 they point at: a skill's actor value index
// or a spell (raw form).
book_teaches :: proc(fields: []Field) -> (flags: u8, teaches: u32, ok: bool) {
	f := find_field(fields, "DATA") or_return
	if len(f.data) < 8 {return}
	return f.data[0], rd32(f.data, 4), true
}

// item_value_weight decodes a base item's gold value + weight. The byte layout is per record
// type (each offset validated against the real Skyrim.esm): the common carriable items store an
// {value:u32, weight:f32} pair at DATA[0..8] (SCRL included — validated vs MGR21ScrollMagicka,
// 50 gold / 0.5 wt); BOOK puts value/weight at DATA[8..16] (after its flags/type/teaches header);
// AMMO keeps value at DATA[12] and has NO weight (arrows are weightless); ALCH (potions/food)
// stores weight alone in DATA and its value in ENIT[0]. ok=false when the type isn't a valued
// item, or the field is missing/too short.
item_value_weight :: proc(rec_type: string, fields: []Field) -> (value: i32, weight: f32, ok: bool) {
	switch rec_type {
	case "WEAP", "ARMO", "INGR", "KEYM", "SLGM", "MISC", "SCRL":
		if f, fok := find_field(fields, "DATA"); fok && len(f.data) >= 8 {
			return i32(rd32(f.data, 0)), rf32(f.data, 4), true
		}
	case "BOOK":
		if f, fok := find_field(fields, "DATA"); fok && len(f.data) >= 16 {
			return i32(rd32(f.data, 8)), rf32(f.data, 12), true
		}
	case "AMMO":
		if f, fok := find_field(fields, "DATA"); fok && len(f.data) >= 16 {
			return i32(rd32(f.data, 12)), 0, true // ammo is weightless in Skyrim
		}
	case "ALCH":
		// weight is a lone f32 in DATA; value lives in ENIT (first u32). Need both fields.
		f, fok := find_field(fields, "DATA")
		e, eok := find_field(fields, "ENIT")
		if fok && len(f.data) >= 4 && eok && len(e.data) >= 4 {
			return i32(rd32(e.data, 0)), rf32(f.data, 0), true
		}
	}
	return 0, 0, false
}

// Content_Item is one CNTO entry: a base item form (RAW/local formID — the caller remaps via the
// plugin Form_Map) and how many of it. Used for CONT container inventories (and, later, NPC_/LVLI).
Content_Item :: struct {
	item:  u32,
	count: i32,
}

// container_contents collects a record's CNTO item entries — the base items a CONT holds. Each
// CNTO is 8 bytes: item formID (u32) + count (i32). Returns a freshly-allocated slice the caller
// owns (nil when the record carries none). FormIDs are raw/local; remap them before use. COCT (a
// convenience item-count) is ignored — the CNTO count is authoritative.
container_contents :: proc(fields: []Field, allocator := context.allocator) -> []Content_Item {
	n := 0
	for f in fields {
		if f.type == "CNTO" && len(f.data) >= 8 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]Content_Item, n, allocator)
	i := 0
	for f in fields {
		if f.type == "CNTO" && len(f.data) >= 8 {
			out[i] = Content_Item{item = rd32(f.data, 0), count = cast(i32)rd32(f.data, 4)}
			i += 1
		}
	}
	return out
}

// formid_list collects every `tag` subrecord's leading u32 formID, in declaration order — the shape
// shared by repeated single-formID subrecords (FLST LNAM, NPC_ SPLO spells / PKID packages, …).
// Returns a freshly-allocated slice the caller owns (nil when none). FormIDs are raw/local; remap
// them before use. Order is preserved (some consumers index into it).
formid_list :: proc(fields: []Field, tag: string, allocator := context.allocator) -> []u32 {
	n := 0
	for f in fields {
		if f.type == tag && len(f.data) >= 4 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]u32, n, allocator)
	i := 0
	for f in fields {
		if f.type == tag && len(f.data) >= 4 {
			out[i] = rd32(f.data, 0)
			i += 1
		}
	}
	return out
}

// form_list_members collects an FLST record's ordered member forms (its repeated LNAM formIDs).
// Thin alias over formid_list — order is significant (script GetAt / random-item selection).
form_list_members :: proc(fields: []Field, allocator := context.allocator) -> []u32 {
	return formid_list(fields, "LNAM", allocator)
}

// --- CTDA (conditions) ------------------------------------------------------------------
//
// One 32-byte block asking a question about the game state. Records use it to gate almost
// everything: which recipe appears, which perk can be taken, which dialogue line is offered.
// VERIFIED against Skyrim.esm — 83,759 conditions, every one exactly 32 bytes.
// The full census and the plan for evaluating these live in docs/conditions.md.

// Condition_Op is the comparison a condition applies, from the top 3 bits of byte 0. Equality is
// 84% of every condition in the base game.
Condition_Op :: enum u8 {
	Equal              = 0,
	NotEqual           = 1,
	Greater            = 2,
	GreaterOrEqual     = 3,
	Less               = 4,
	LessOrEqual        = 5,
}

// Condition_Run_On names WHICH object the function is asked about. Subject is 92% of the base game.
Condition_Run_On :: enum u32 {
	Subject      = 0,
	Target       = 1,
	Reference    = 2, // the condition's reference form (offset 24)
	CombatTarget = 3,
	LinkedRef    = 4,
	QuestAlias   = 5, // the alias in param3
	PackageData  = 6,
	EventData    = 7, // the story event member in param3 (R1, L1, V1...)
}

// Condition_Flag is the low 5 bits of byte 0.
Condition_Flag :: enum u8 {
	Or,            // joins this condition to the NEXT one as an OR; a list is otherwise an AND
	Use_Aliases,   // a Ref parameter is an alias ID
	Use_Global,    // the comparison value is a GLOB form ID
	Use_Pack_Data, // a Ref parameter is a package data index
	Swap,          // swap subject and target
}

Condition_Flags :: bit_set[Condition_Flag;u8]

// Condition_Param is the kind of a function's parameter, from xEdit's table.
Condition_Param :: enum u8 {
	None,
	Number, // an integer, an enum, an actor value index, an alias ID...
	Form,
	Ref,    // a reference form, unless Use_Aliases or Use_Pack_Data says otherwise
	String, // the CIS1 or CIS2 that follows the CTDA
}

Condition_Function :: struct {
	name:   string,
	params: [2]Condition_Param,
}

// Condition is one decoded CTDA. param1/param2 and global are RAW (plugin-local) unless the caller
// remaps them; condition_param_is_form says which parameters are forms.
Condition :: struct {
	function:  u16,
	op:        Condition_Op,
	flags:     Condition_Flags,
	value:     f32, // 0 when Use_Global
	global:    u32, // the GLOB the comparison reads, when Use_Global
	param1:    u32,
	param2:    u32,
	run_on:    Condition_Run_On,
	reference: u32, // set only when run_on == .Reference
	param3:    i32, // the alias (QuestAlias) or event member (EventData); -1 otherwise
	text:      string, // a String parameter, borrowed from the record's CIS1/CIS2
}

// condition_function is a function's name and parameter kinds; an unknown index has no name.
condition_function :: proc(function: u16) -> Condition_Function {
	return CONDITION_FUNCTIONS[function] if int(function) < CONDITION_FUNCTION_COUNT else {}
}

// condition_param_is_form reports whether parameter `i` (0 or 1) of `c` holds a form ID.
condition_param_is_form :: proc(c: Condition, i: int) -> bool {
	switch condition_function(c.function).params[i] {
	case .Form:
		return true
	case .Ref:
		return c.flags & {.Use_Aliases, .Use_Pack_Data} == {}
	case .None, .Number, .String:
	}
	return false
}

// conditions collects a record's CTDA blocks in order, each with the CIS1/CIS2 string after it.
// Order matters: the OR runs are positional. `stop_at`, when given, ends the scan at the first field
// with that tag — PERK needs it, because the conditions before its first PRKE gate whether the perk
// can be TAKEN while the ones after gate whether an entry's effect APPLIES. A record with several
// condition lists (QUST) passes each list's slice of fields. Returns a freshly allocated slice the
// caller frees; nil when the record carries none.
conditions :: proc(fields: []Field, allocator := context.allocator, stop_at := "") -> []Condition {
	n := 0
	for f in fields {
		if stop_at != "" && f.type == stop_at {
			break
		}
		if f.type == "CTDA" && len(f.data) >= 32 {
			n += 1
		}
	}
	if n == 0 {
		return nil
	}
	out := make([]Condition, n, allocator)
	i := 0
	for f in fields {
		if stop_at != "" && f.type == stop_at {
			break
		}
		if (f.type == "CIS1" || f.type == "CIS2") && i > 0 {
			out[i - 1].text = cstr(f.data)
			continue
		}
		if f.type != "CTDA" || len(f.data) < 32 {
			continue
		}
		b := f.data
		c := Condition {
			op       = Condition_Op(b[0] >> 5),
			flags    = transmute(Condition_Flags)(b[0] & 0x1F),
			value    = rf32(b, 4),
			function = rd16(b, 8),
			param1   = rd32(b, 12),
			param2   = rd32(b, 16),
			run_on   = Condition_Run_On(rd32(b, 20)),
			param3   = i32(rd32(b, 28)),
		}
		if .Use_Global in c.flags {
			c.global, c.value = rd32(b, 4), 0
		}
		if c.run_on == .Reference {
			c.reference = rd32(b, 24)
		}
		out[i] = c
		i += 1
	}
	return out
}

// condition_run is the CTDA/CIS1/CIS2 fields from index `from` up to the first other field: one list
// of a record that holds several (QUST: its dialogue conditions, then after NEXT the story manager's).
condition_run :: proc(fields: []Field, from: int) -> []Field {
	end := from
	for end < len(fields) {
		t := fields[end].type
		if t != "CTDA" && t != "CIS1" && t != "CIS2" {break}
		end += 1
	}
	return fields[from:end]
}

// condition_holds applies a condition's operator to a value the function returned.
condition_holds :: proc(c: Condition, got: f32) -> bool {
	switch c.op {
	case .Equal:
		return got == c.value
	case .NotEqual:
		return got != c.value
	case .Greater:
		return got > c.value
	case .GreaterOrEqual:
		return got >= c.value
	case .Less:
		return got < c.value
	case .LessOrEqual:
		return got <= c.value
	}
	return true // an operator the format does not define — do not hide content over it
}

// field_f32 reads a subrecord's leading f32. Companion to field_u32 (records_forms.odin), for the
// fixed-width subrecords a record repeats in order — an AVIF perk node's HNAM/VNAM, for instance.
field_f32 :: proc(f: Field) -> (f32, bool) {
	if len(f.data) < 4 {
		return 0, false
	}
	return rf32(f.data, 0), true
}

// subrecord_formid reads a single-formID subrecord's leading u32 (RNAM race, CNAM class, VTCK voice,
// DOFT outfit, …). ok=false when the tag is absent or short. Raw/local; remap before use.
subrecord_formid :: proc(fields: []Field, tag: string) -> (u32, bool) {
	if f, ok := find_field(fields, tag); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// ACBS (Actor Base Configuration) flag bits — the actor's base disposition/behaviour. Only the
// commonly-queried ones are named; the raw u32 is preserved so unlisted bits survive round-trip.
ACBS_FEMALE :: 0x0000_0001
ACBS_ESSENTIAL :: 0x0000_0002
ACBS_RESPAWN :: 0x0000_0008
ACBS_AUTO_CALC_STATS :: 0x0000_0010
ACBS_UNIQUE :: 0x0000_0020
ACBS_PC_LEVEL_MULT :: 0x0000_0080 // `level` field is a ×1000 multiplier of the player's level, not absolute
ACBS_PROTECTED :: 0x0000_0800
ACBS_SUMMONABLE :: 0x0000_4000
ACBS_GHOST :: 0x2000_0000
ACBS_INVULNERABLE :: 0x8000_0000

// ACBS template flags: which parts of an NPC_ come from its TPLT.
ACBS_TEMPLATE_TRAITS :: 0x0001 // race and more
ACBS_TEMPLATE_STATS :: 0x0002 // level, auto-calc, skills, offsets, speed, class
ACBS_TEMPLATE_FACTIONS :: 0x0004
ACBS_TEMPLATE_SPELLS :: 0x0008 // spell list (UESP Mod File Format/NPC_)
ACBS_TEMPLATE_AI_DATA :: 0x0010
ACBS_TEMPLATE_BASE_DATA :: 0x0080 // name, short name, flags
ACBS_TEMPLATE_INVENTORY :: 0x0100

// Actor_Config is an NPC_'s ACBS block (24 bytes): base disposition flags + level band + the
// magicka/stamina/health OFFSETS added on top of the DNAM base attributes. `level` is absolute
// unless ACBS_PC_LEVEL_MULT is set (then it's a ×1000 player-level multiplier). Disposition @16 is
// skipped.
Actor_Config :: struct {
	flags:       u32,
	magicka_off: i16,
	stamina_off: i16,
	level:       u16,
	calc_min:    u16,
	calc_max:    u16,
	speed_mult:  u16,
	template_flags: u16, // which parts come from the TPLT (ACBS_TEMPLATE_*)
	health_off:  i16,
}

// actor_config decodes an NPC_'s ACBS block. ok=false when the record has no (or a truncated) ACBS.
// Offsets validated against the Player (0x7): flags 0x30 = AUTO_CALC|UNIQUE, level 1, calc 0..100,
// speed 100, magicka/stamina/health offsets 50/50/50.
actor_config :: proc(fields: []Field) -> (cfg: Actor_Config, ok: bool) {
	f, fok := find_field(fields, "ACBS")
	if !fok || len(f.data) < 24 {
		return {}, false
	}
	return Actor_Config {
			flags       = rd32(f.data, 0),
			magicka_off = i16(rd16(f.data, 4)),
			stamina_off = i16(rd16(f.data, 6)),
			level       = rd16(f.data, 8),
			calc_min    = rd16(f.data, 10),
			calc_max    = rd16(f.data, 12),
			speed_mult  = rd16(f.data, 14),
			template_flags = rd16(f.data, 18),
			health_off  = i16(rd16(f.data, 20)),
		},
		true
}

// NPC_SKILLS is the count of skill entries in a DNAM block (18 Skyrim skills).
NPC_SKILLS :: 18

// Actor_Attributes is an NPC_'s DNAM block (52 bytes): the 18 base skill values + 18 skill offsets,
// then the base health/magicka/stamina (the ACBS offsets stack on top). The tail (@42+: far-model
// distance, geared-up flags) is skipped.
Actor_Attributes :: struct {
	skills:        [NPC_SKILLS]u8,
	skill_offsets: [NPC_SKILLS]u8,
	health:        u16,
	magicka:       u16,
	stamina:       u16,
}

// actor_attributes decodes an NPC_'s DNAM block. ok=false when absent/truncated. Offsets validated
// against the Player (0x7): skills 15–25, base health/magicka/stamina 100/100/100 (@36/@38/@40).
actor_attributes :: proc(fields: []Field) -> (attr: Actor_Attributes, ok: bool) {
	f, fok := find_field(fields, "DNAM")
	if !fok || len(f.data) < 42 {
		return {}, false
	}
	copy(attr.skills[:], f.data[0:NPC_SKILLS])
	copy(attr.skill_offsets[:], f.data[NPC_SKILLS:NPC_SKILLS * 2])
	attr.health = rd16(f.data, 36)
	attr.magicka = rd16(f.data, 38)
	attr.stamina = rd16(f.data, 40)
	return attr, true
}

// actor_ai reads an NPC_'s AIDT: Aggression, Confidence, Energy, Morality, Mood, Assistance @0..5
// (UESP Mod File Format/NPC_), in actor value order 0..5.
actor_ai :: proc(fields: []Field) -> (ai: [6]u8, ok: bool) {
	f, fok := find_field(fields, "AIDT")
	if !fok || len(f.data) < 6 {
		return {}, false
	}
	copy(ai[:], f.data[:6])
	return ai, true
}

// LVLI (leveled-list) LVLF flag bits. CALC_FROM_ALL_LEVELS = "calculate from all levels ≤ the
// player's" (else only entries at the highest level ≤ it qualify); CALC_FOR_EACH = roll the list
// independently for each unit of the requested count (else roll once and multiply); USE_ALL = every
// entry, overriding both.
LVLI_CALC_FROM_ALL_LEVELS :: 0x01
LVLI_CALC_FOR_EACH :: 0x02
LVLI_USE_ALL :: 0x04
LVLI_SPECIAL_LOOT :: 0x08

// Leveled_Entry is one LVLO row of a leveled list: at player-level ≥ `level`, this `item` (RAW/local
// formID — the caller remaps) is a candidate, contributing `count` copies. The item may itself be
// another LVLI (nested lists), resolved at roll time. On-disk LVLO is 12 bytes: level u16@0, pad@2,
// formID u32@4, count u16@8, pad@10 (stride validated against LItemBlacksmithWeapon75).
Leveled_Entry :: struct {
	level: u16,
	item:  u32,
	count: u16,
}

// leveled_list decodes a LVLI record's roll parameters + entries. `chance_none` (LVLD) is the
// percent chance the roll yields nothing; `flags` is LVLF (see LVLI_* bits). `entries` is a freshly
// allocated slice the caller owns (nil when the list is empty). `chance_global` (LVLG, raw formID)
// is a GLOB whose value replaces LVLD when set. LLCT (entry count) is ignored: the LVLO count is
// authoritative.
leveled_list :: proc(
	fields: []Field,
	allocator := context.allocator,
) -> (chance_none: u8, flags: u8, entries: []Leveled_Entry, chance_global: u32) {
	if f, ok := find_field(fields, "LVLD"); ok && len(f.data) >= 1 {
		chance_none = f.data[0]
	}
	chance_global, _ = subrecord_formid(fields, "LVLG")
	if f, ok := find_field(fields, "LVLF"); ok && len(f.data) >= 1 {
		flags = f.data[0]
	}
	n := 0
	for f in fields {
		if f.type == "LVLO" && len(f.data) >= 12 {
			n += 1
		}
	}
	if n == 0 {
		return
	}
	entries = make([]Leveled_Entry, n, allocator)
	i := 0
	for f in fields {
		if f.type == "LVLO" && len(f.data) >= 12 {
			entries[i] = Leveled_Entry {
				level = rd16(f.data, 0),
				item  = rd32(f.data, 4),
				count = rd16(f.data, 8),
			}
			i += 1
		}
	}
	return
}

// cell_is_interior reports whether a CELL's DATA flags mark it interior.
cell_is_interior :: proc(fields: []Field) -> bool {
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 1 {
		return f.data[0] & CELL_INTERIOR != 0
	}
	return false
}

// cell_grid reads an exterior CELL's XCLC grid coordinates (X i32, Y i32 — each cell
// is 4096 units square in the worldspace). ok=false for interior cells (no XCLC).
cell_grid :: proc(fields: []Field) -> (x: i32, y: i32, ok: bool) {
	if f, fok := find_field(fields, "XCLC"); fok && len(f.data) >= 8 {
		return i32(rd32(f.data, 0)), i32(rd32(f.data, 4)), true
	}
	return 0, 0, false
}

// WATER_NONE is the XCLW "no override" sentinel (FLT_MAX): the cell defers to its
// worldspace's default water height. Bit pattern 0x7F7FFFFF == max(f32).
WATER_NONE :: max(f32)

// WATER_MAX_PLAUSIBLE bounds a real water height. Besides WATER_NONE, Skyrim cells carry
// other "no water" markers in XCLW (observed 0xCF000000 = −2³¹, and a positive ~4.3e9),
// which are NOT sea levels — they'd float a plane in the sky. Any |XCLW| above this bound
// is treated as "no water". Real Skyrim heights sit well under ±100k, so 1e6 is safe.
WATER_MAX_PLAUSIBLE :: f32(1e6)

// cell_water_height reads a CELL's XCLW (water height, f32). The returned value may be
// the WATER_NONE sentinel (FLT_MAX) — meaning "use the worldspace default"; the caller
// resolves that. ok=false when the cell has no XCLW at all (no water).
cell_water_height :: proc(fields: []Field) -> (f32, bool) {
	if f, ok := find_field(fields, "XCLW"); ok && len(f.data) >= 4 {
		return rf32(f.data, 0), true
	}
	return 0, false
}

// cell_water_type reads a CELL's XCWT — the formID of the WATR water type painted in
// this cell (river/ocean/marsh; governs the eventual water appearance). ok=false if
// absent (the cell either has no water or falls back to the worldspace default type).
cell_water_type :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "XCWT"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// world_water_height reads a WRLD's default water height — the level a cell's XCLW
// sentinel (WATER_NONE) resolves to (e.g. Tamriel's −14000 sea level). Prefers NAM4
// (LOD water height, the authoritative sea level), else DNAM's second f32
// ({defaultLandHeight, defaultWaterHeight}). ok=false if neither is present.
world_water_height :: proc(fields: []Field) -> (f32, bool) {
	if f, ok := find_field(fields, "NAM4"); ok && len(f.data) >= 4 {
		return rf32(f.data, 0), true
	}
	if f, ok := find_field(fields, "DNAM"); ok && len(f.data) >= 8 {
		return rf32(f.data, 4), true
	}
	return 0, false
}

// decode_refr reads a REFR's NAME (base), DATA (pos+rot) and optional XSCL (scale) and XCNT (count).
decode_refr :: proc(fields: []Field) -> Placement {
	p := Placement{scale = 1, count = 1}
	if f, ok := find_field(fields, "NAME"); ok && len(f.data) >= 4 {
		p.base = rd32(f.data, 0)
	}
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 24 {
		p.pos = {rf32(f.data, 0), rf32(f.data, 4), rf32(f.data, 8)}
		p.rot = {rf32(f.data, 12), rf32(f.data, 16), rf32(f.data, 20)}
	}
	if f, ok := find_field(fields, "XSCL"); ok && len(f.data) >= 4 {
		p.scale = rf32(f.data, 0)
	}
	if f, ok := find_field(fields, "XCNT"); ok && len(f.data) >= 4 {
		p.count = max(i32(rd32(f.data, 0)), 1)
	}
	return p
}

// Primitive is a REFR's XPRM shape: a trigger volume, a room bound or an occlusion plane. `half`
// is the box half extents, or the sphere radius in x (xEdit shows the stored values doubled).
Primitive :: struct {
	half: [3]f32,
	kind: Primitive_Kind,
}

Primitive_Kind :: enum u32 {
	None,
	Box,
	Sphere,
	Portal_Box,
	Line,
}

// refr_primitive reads XPRM: bounds (3 f32), colour (4 f32), type (u32).
refr_primitive :: proc(fields: []Field) -> (Primitive, bool) {
	f, ok := find_field(fields, "XPRM")
	if !ok || len(f.data) < 32 {return {}, false}
	return {{rf32(f.data, 0), rf32(f.data, 4), rf32(f.data, 8)}, Primitive_Kind(rd32(f.data, 28))}, true
}

// LAND_GRID is the side length of a cell's heightmap vertex grid (33×33 = 1089
// vertices → 32×32 quads spanning the 4096-unit cell).
LAND_GRID :: 33

// land_heights decodes a LAND record's VHGT heightmap into a row-major LAND_GRID²
// grid of CUMULATIVE height values (the gradient sum, NOT yet world-scaled — the
// caller multiplies by its height scale). VHGT = base offset f32 + LAND_GRID²
// signed-byte gradients (row-major) + 3 pad bytes. Each gradient is a delta: the
// first column of each row is relative to the previous row's first column, and
// every other cell is relative to the previous cell in its row. ok=false if there's
// no VHGT or it's truncated. Ref: UESP "Skyrim Mod:Mod File Format/LAND".
land_heights :: proc(fields: []Field, allocator := context.allocator) -> ([]f32, bool) {
	f, ok := find_field(fields, "VHGT")
	if !ok || len(f.data) < 4 + LAND_GRID * LAND_GRID {
		return nil, false
	}
	offset := rf32(f.data, 0)
	grad := f.data[4:]
	out := make([]f32, LAND_GRID * LAND_GRID, allocator)
	col0 := offset
	for y in 0 ..< LAND_GRID {
		col0 += f32(cast(i8)grad[y * LAND_GRID]) // first column: delta from previous row
		h := col0
		out[y * LAND_GRID] = h
		for x in 1 ..< LAND_GRID {
			h += f32(cast(i8)grad[y * LAND_GRID + x]) // delta from previous cell in row
			out[y * LAND_GRID + x] = h
		}
	}
	return out, true
}

// land_base_textures reads a LAND record's BTXT base-texture references — the bottom
// landscape layer of each of the cell's 4 quadrants (0=SW, 1=SE, 2=NW, 3=NE). Each
// BTXT is 8 bytes: LTEX formID (u32) + quadrant (u8) + unused (u8) + layer (i16).
// Returns the LTEX formID per quadrant; 0 where a quadrant has no base. (Additional
// ATXT/VTXT alpha layers are deferred to the blending step.)
land_base_textures :: proc(fields: []Field) -> [4]u32 {
	out: [4]u32
	for f in fields {
		if f.type == "BTXT" && len(f.data) >= 8 {
			q := f.data[4]
			if q < 4 {
				out[q] = rd32(f.data, 0)
			}
		}
	}
	return out
}

// Land_Alpha is one painted opacity sample of an ATXT layer: which point in the 17×17
// quadrant grid (0-288, row-major y·17+x) and how opaque the layer is there.
Land_Alpha :: struct {
	point:   u16,
	opacity: f32,
}

// Land_Layer is one landscape texture layer of a LAND quadrant: the LTEX form and, for
// additional (ATXT) layers, the per-point alpha that paints it over the layers below.
// Base (BTXT) layers cover their whole quadrant (alpha empty). quadrant is 0=SW,1=SE,
// 2=NW,3=NE.
Land_Layer :: struct {
	ltex:     u32,
	quadrant: u8,
	base:     bool,
	alpha:    []Land_Alpha, // owned; empty for base layers
}

// land_layers decodes a LAND record's texture layers in file order: each BTXT (base,
// 8 bytes: LTEX + quadrant + pad + layer) and each ATXT (additional layer, same 8 bytes)
// paired with its following VTXT (the alpha array: per entry point u16 + pad u16 +
// opacity f32). Layers are returned base-first per quadrant (BTXT precede ATXT). Free
// with free_land_layers.
land_layers :: proc(fields: []Field, allocator := context.allocator) -> ([]Land_Layer, bool) {
	layers := make([dynamic]Land_Layer, 0, 16, allocator)
	for f, i in fields {
		switch f.type {
		case "BTXT":
			if len(f.data) >= 8 && f.data[4] < 4 {
				append(&layers, Land_Layer{ltex = rd32(f.data, 0), quadrant = f.data[4], base = true})
			}
		case "ATXT":
			if len(f.data) < 8 || f.data[4] >= 4 {
				continue
			}
			layer := Land_Layer{ltex = rd32(f.data, 0), quadrant = f.data[4]}
			// The alpha for this layer is the VTXT field that immediately follows.
			if i + 1 < len(fields) && fields[i + 1].type == "VTXT" {
				v := fields[i + 1].data
				n := len(v) / 8
				alpha := make([]Land_Alpha, n, allocator)
				for k in 0 ..< n {
					alpha[k] = {point = rd16(v, k * 8), opacity = rf32(v, k * 8 + 4)}
				}
				layer.alpha = alpha
			}
			append(&layers, layer)
		}
	}
	return layers[:], true
}

free_land_layers :: proc(layers: []Land_Layer, allocator := context.allocator) {
	for l in layers {
		delete(l.alpha, allocator)
	}
	delete(layers, allocator)
}

// landscape_grass reads an LTEX record's GNAM — the formID of the GRAS grass type the
// engine scatters over terrain painted with this texture. ok=false if absent (the
// texture grows no grass).
landscape_grass :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "GNAM"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// grass_density reads a GRAS record's DATA density — the first byte (clusters scattered
// per unit area; the rest of DATA is slope/water/wave fields, deferred). ok=false if no
// DATA. Pair with model_path (GRAS carries a MODL grass-cluster mesh).
grass_density :: proc(fields: []Field) -> (u8, bool) {
	if f, ok := find_field(fields, "DATA"); ok && len(f.data) >= 1 {
		return f.data[0], true
	}
	return 0, false
}

// landscape_txst reads an LTEX (Landscape Texture) record's TNAM — the formID of the
// TXST texture set it draws its diffuse from. ok=false if absent.
landscape_txst :: proc(fields: []Field) -> (u32, bool) {
	if f, ok := find_field(fields, "TNAM"); ok && len(f.data) >= 4 {
		return rd32(f.data, 0), true
	}
	return 0, false
}

// texture_set_diffuse reads a TXST (Texture Set) record's TX00 — the diffuse texture
// path (e.g. "Landscape\\Dirt01.dds"), or "" if absent.
texture_set_diffuse :: proc(fields: []Field) -> string {
	if f, ok := find_field(fields, "TX00"); ok {
		return cstr(f.data)
	}
	return ""
}

// refr_teleport reads a REFR's XTEL door teleport, if present. XTEL = destination
// door formID (4) + position (12) + rotation (12); a trailing flags word (Skyrim) is
// ignored.
refr_teleport :: proc(fields: []Field) -> (Teleport, bool) {
	f, ok := find_field(fields, "XTEL")
	if !ok || len(f.data) < 28 {
		return {}, false
	}
	return Teleport {
			door = Form_ID(rd32(f.data, 0)),
			pos = {rf32(f.data, 4), rf32(f.data, 8), rf32(f.data, 12)},
			rot = {rf32(f.data, 16), rf32(f.data, 20), rf32(f.data, 24)},
		},
		true
}

// Lock_Data is a REFR's XLOC lock: its difficulty and (optionally) the key that opens it.
// `key` is raw (local) until gamedb remaps it, like Teleport.door. The mere presence of an
// XLOC subrecord means the reference starts LOCKED (unlocked-but-lockable refs carry no XLOC);
// `level` is only the pick difficulty. See decode_xloc.
Lock_Data :: struct {
	level: u8,      // 0 Novice/Very Easy · 25 Apprentice · 50 Adept · 75 Expert · 100 Master · 255 requires key
	key:   Form_ID, // KEYM that opens it (0 = none); raw until remapped
}

// decode_xloc reads a REFR's XLOC lock data. XLOC (20 bytes in Skyrim, validated vs the real
// Skyrim.esm): lock level (u8) + 3 unused + key formID (u32 @ 4) + 12 reserved/unused. ok=false
// when there's no XLOC — i.e. the ref is not locked (Skyrim omits XLOC on unlocked refs). Only the
// level + key are trusted; the trailing bytes are left unread (their meaning is unverified).
decode_xloc :: proc(fields: []Field) -> (Lock_Data, bool) {
	f, ok := find_field(fields, "XLOC")
	if !ok || len(f.data) < 8 {
		return {}, false
	}
	return Lock_Data{level = f.data[0], key = Form_ID(rd32(f.data, 4))}, true
}

// Imagespace (IMGS) tone/color parameters (Skyrim layout — validated vs real Skyrim.esm via
// esmdump --imgs). Skyrim splits these across three subrecords, NOT one DNAM:
//   HNAM (HDR, 36B/9 floats): eye-adapt speed, bloom blur, bloom threshold, bloom scale, receive
//     bloom, WHITE point, SUNLIGHT scale, SKY scale, eye-adapt strength.
//   CNAM (Cinematic, 12B): SATURATION, BRIGHTNESS, CONTRAST.
//   TNAM (Tint, 16B): TINT AMOUNT, tint color RGB.
//   (DNAM, 16B, is depth-of-field — not needed.)
// These are Bethesda's authored per-look grade, fed to CE's hardcoded HDR shader. We read them
// from the USER's OWN ESM at install time to derive a data-faithful lighting profile LOCALLY —
// NEVER baked into the shipped binary (they're Bethesda content; see lighting-system-design).
Imagespace :: struct {
	eye_adapt_speed:      f32,
	bloom_blur:           f32,
	bloom_threshold:      f32,
	bloom_scale:          f32,
	recv_bloom_threshold: f32,
	hdr_white:            f32,
	sunlight_scale:       f32,
	sky_scale:            f32,
	eye_adapt_strength:   f32,
	saturation:           f32,
	brightness:           f32,
	contrast:             f32,
	tint_amount:          f32,
	tint_color:           [3]f32,
}

// decode_imagespace reads an IMGS record's HNAM/CNAM/TNAM. ok=false if the HDR block (HNAM) is
// absent/short; CNAM/TNAM default to neutral if missing.
decode_imagespace :: proc(fields: []Field) -> (im: Imagespace, ok: bool) {
	h, hok := find_field(fields, "HNAM")
	if !hok || len(h.data) < 36 {
		return {}, false
	}
	im = Imagespace {
		eye_adapt_speed      = rf32(h.data, 0),
		bloom_blur           = rf32(h.data, 4),
		bloom_threshold      = rf32(h.data, 8),
		bloom_scale          = rf32(h.data, 12),
		recv_bloom_threshold = rf32(h.data, 16),
		hdr_white            = rf32(h.data, 20),
		sunlight_scale       = rf32(h.data, 24),
		sky_scale            = rf32(h.data, 28),
		eye_adapt_strength   = rf32(h.data, 32),
		saturation           = 1,
		brightness           = 1,
		contrast             = 1,
		tint_color           = {1, 1, 1},
	}
	if c, cok := find_field(fields, "CNAM"); cok && len(c.data) >= 12 {
		im.saturation = rf32(c.data, 0)
		im.brightness = rf32(c.data, 4)
		im.contrast = rf32(c.data, 8)
	}
	if t, tok := find_field(fields, "TNAM"); tok && len(t.data) >= 16 {
		im.tint_amount = rf32(t.data, 0)
		im.tint_color = {rf32(t.data, 4), rf32(t.data, 8), rf32(t.data, 12)}
	}
	return im, true
}

@(private)
rf32 :: proc(b: []u8, off: int) -> f32 {
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return transmute(f32)v
}
