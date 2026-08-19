package gamedb

// Actor-identity indexing: the records an NPC_ links out to (RACE, CLAS, VTYP, OTFT) plus AVIF,
// the actor-value definitions. Before this, Actor_Base's race/class/voice/outfit were remapped
// FormIDs pointing at records nobody indexed — stored, but dead. Decoders live in
// src/formats/esm/records_actors.odin; this file owns the storage, the remap and the queries.
//
// AVIF also supplies the bridge the rest of the DB needs: MGEF and RACE store actor values as
// ENGINE INDICES, while worldstate.actor_values is keyed by lower-case NAME. actor_value_key
// joins the two.

import "core:strings"
import "../formats/esm"

// Race is a RACE's identity + stat layer: what it's called, the skill bonuses it grants at
// creation, and its body scale. Appearance (tint layers, head parts, body data — 20k+
// subrecords across the 99 vanilla races) is deliberately not decoded; add it with a character
// /appearance phase, not here.
Race :: struct {
	info:        esm.Race_Info,
	description: string, // DESC (owned; "" when absent)
}

// Class is a CLAS's level-up weighting: which skills an NPC of this class favours and how
// its health/magicka/stamina split. `training_skill` is an actor-value index — resolve it with
// actor_value_key / actor_value_display.
Class :: struct {
	info:        esm.Class_Info,
	description: string, // DESC (owned; "" when absent)
}

// Actor_Value_Info is one AVIF record: an actor value's identity. `index` is its engine
// ActorValue index when the form is a base-game AVIF (see esm.ACTOR_VALUE_BLOCKS); has_index is
// false for a mod-added AVIF, which is a form but not a new enum slot. `key` is the canonical
// lower-case lookup name (editor id minus its "AV" prefix) — the same key worldstate's
// actor-value store uses.
Actor_Value_Info :: struct {
	index:       i32,
	has_index:   bool,
	key:         string, // owned, lower-case
	editor_id:   string, // owned, as authored
	description: string, // DESC (owned; "" when absent)
}

// --- indexing ---------------------------------------------------------------------------

// index_race decodes a RACE's identity + stat layer (name, description, DATA bonuses/scale) and
// its keywords. See Race for what's deliberately skipped.
@(private)
index_race :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl)
	index_keywords(db, rec.form_id, fl, fm)

	r: Race
	r.info, _ = esm.race_info(fl)
	r.description = index_description(db, fl)

	if old, existed := db.races[rec.form_id]; existed {
		delete(old.description, db.allocator) // override: free the previous clone
	}
	db.races[rec.form_id] = r
}

// index_class decodes a CLAS's DATA level-up weighting plus its name/description.
@(private)
index_class :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl)

	c: Class
	c.info, _ = esm.class_info(fl)
	c.description = index_description(db, fl)

	if old, existed := db.classes[rec.form_id]; existed {
		delete(old.description, db.allocator)
	}
	db.classes[rec.form_id] = c
}

// index_voice_type records a VTYP's DNAM flags. A voice type has no other data — the dialogue
// system keys off the form itself, and its editor id is its name (indexed like a keyword's).
@(private)
index_voice_type :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	flags, _ := esm.voice_type_flags(fl)
	db.voice_types[rec.form_id] = flags
}

// index_outfit decodes an OTFT's INAM item list, remapped — the gear an NPC wearing it spawns
// with. This is what Actor_Base.outfit finally resolves to.
@(private)
index_outfit :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	raw := esm.outfit_items(fl, context.allocator) // remap_formid_list frees it
	if raw == nil {
		return
	}
	if old, existed := db.outfits[rec.form_id]; existed {
		delete(old, db.allocator) // override: free the previous item list
	}
	db.outfits[rec.form_id] = remap_formid_list(db, raw, fm)
}

// index_actor_value decodes an AVIF: its canonical key, editor id, description, and — for a
// base-game record — its engine ActorValue index. The index comes from the formID blocks, not
// file order (see esm.ACTOR_VALUE_BLOCKS). Only a plugin in load-order slot 0 (the base game)
// can define an indexed actor value; a mod's AVIF is a form with no enum slot.
@(private)
index_actor_value :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	edid := esm.editor_id(fl)
	if edid == "" {
		return
	}
	index_name(db, rec.form_id, fl) // 24 of the 149 carry a FULL display name

	av: Actor_Value_Info
	av.editor_id = strings.clone(edid, db.allocator)
	av.description = index_description(db, fl)
	if rec.form_id >> 32 == 0 {
		av.index, av.has_index = esm.actor_value_index(u32(rec.form_id))
	}

	// The canonical key: the editor id minus its "AV" prefix, lower-cased — "AVHealth" →
	// "health", which is exactly how worldstate keys its actor-value store.
	name := edid
	if len(name) > 2 && name[:2] == "AV" {
		name = name[2:]
	}
	av.key = strings.to_lower(name, db.allocator)
	if av.has_index && av.index == esm.AV_ILLUSION {
		delete(av.key, db.allocator)
		av.key = strings.clone("illusion", db.allocator) // its record is still named AVMysticism
	}

	if old, existed := db.actor_value_info[rec.form_id]; existed {
		free_actor_value_info(db, old)
	}
	db.actor_value_info[rec.form_id] = av
	if av.has_index {
		db.actor_value_by_index[av.index] = rec.form_id
	}
	if _, seen := db.actor_value_by_key[av.key]; !seen {
		db.actor_value_by_key[strings.clone(av.key, db.allocator)] = rec.form_id
	}

	// The perk-tree nodes trail the identity in the same record. Only the 18 skills carry any, and
	// the split lives in perks.odin — this hands over the fields it already parsed.
	index_perk_tree(db, rec, fl, fm)
}

// index_description clones a record's DESC text, English-resolved. DESC is long-form text, so it
// resolves through DLSTRINGS (or inline for a non-localized plugin). "" when absent.
@(private)
index_description :: proc(db: ^DB, fl: []esm.Field) -> string {
	f, has := esm.find_field(fl, "DESC")
	if !has {
		return ""
	}
	txt := resolve_lstring(db, f, db.cur_dlstrings)
	if txt == "" {
		return ""
	}
	return strings.clone(txt, db.allocator)
}

// --- queries ----------------------------------------------------------------------------

// race_of returns a race's identity + stat layer (ok=false when the form isn't an indexed RACE).
race_of :: proc(db: ^DB, race: Form_ID) -> (Race, bool) {
	if db == nil {
		return {}, false
	}
	r, ok := db.races[race]
	return r, ok
}

// class_of returns a class's level-up weighting (ok=false when the form isn't an indexed CLAS).
class_of :: proc(db: ^DB, class: Form_ID) -> (Class, bool) {
	if db == nil {
		return {}, false
	}
	c, ok := db.classes[class]
	return c, ok
}

// voice_type_flags returns a VTYP's flags (esm.VTYP_* bits). ok=false when the form isn't an
// indexed voice type.
voice_type_flags :: proc(db: ^DB, voice: Form_ID) -> (u8, bool) {
	if db == nil {
		return 0, false
	}
	f, ok := db.voice_types[voice]
	return f, ok
}

// outfit_items returns the gear an outfit grants (empty when the form isn't an indexed OTFT or
// the outfit is empty). Owned by the DB.
outfit_items :: proc(db: ^DB, outfit: Form_ID) -> []Form_ID {
	if db == nil {
		return nil
	}
	return db.outfits[outfit]
}

// actor_race_bonuses returns an actor base's racial skill bonuses, resolved through its RACE.
// Each entry's `skill` is an actor-value index — name it with actor_value_key. `count` is how
// many of the returned slots are populated; it's 0 when the actor or its race isn't indexed, or
// the race grants none. Returned BY VALUE (not as a slice) because the array lives inside a
// map value — a slice of it would dangle the moment the map rehashed.
actor_race_bonuses :: proc(
	db: ^DB,
	actor: Form_ID,
) -> (
	bonuses: [esm.RACE_SKILL_BONUSES]esm.Race_Skill_Bonus,
	count: int,
) {
	a, ok := actor_base(db, actor)
	if !ok {
		return
	}
	r, rok := race_of(db, a.race)
	if !rok {
		return
	}
	return r.info.bonuses, r.info.bonus_count
}

// actor_outfit_items returns the gear an actor base spawns wearing (its DOFT outfit's contents).
// Empty when the actor has no outfit or it isn't indexed.
actor_outfit_items :: proc(db: ^DB, actor: Form_ID) -> []Form_ID {
	a, ok := actor_base(db, actor)
	if !ok {
		return nil
	}
	return outfit_items(db, a.outfit)
}

// actor_value_info returns an AVIF's decoded identity (ok=false when the form isn't one).
actor_value_info :: proc(db: ^DB, form: Form_ID) -> (Actor_Value_Info, bool) {
	if db == nil {
		return {}, false
	}
	av, ok := db.actor_value_info[form]
	return av, ok
}

// actor_value_key maps an engine ActorValue INDEX — what MGEF, RACE and CLAS store — to its
// canonical lower-case name, the key worldstate's actor-value store uses. This is the join
// between the record layer and the runtime overlay. ok=false for an index with no AVIF record
// (an engine-only slot such as 37 Voice Points).
actor_value_key :: proc(db: ^DB, index: i32) -> (string, bool) {
	form, ok := actor_value_by_index(db, index)
	if !ok {
		return "", false
	}
	av, has := actor_value_info(db, form)
	if !has {
		return "", false
	}
	return av.key, true
}

// actor_value_display returns an actor value's player-facing name for `index` — its FULL when
// the record carries one (24 of the 149 do), else its canonical key. ok=false when the index has
// no AVIF record.
actor_value_display :: proc(db: ^DB, index: i32) -> (string, bool) {
	form, ok := actor_value_by_index(db, index)
	if !ok {
		return "", false
	}
	if full := name_of(db, form); full != "" {
		return full, true
	}
	av, has := actor_value_info(db, form)
	if !has {
		return "", false
	}
	return av.key, true
}

// actor_value_by_index returns the AVIF form defining ActorValue `index`. ok=false when no
// record defines it.
actor_value_by_index :: proc(db: ^DB, index: i32) -> (Form_ID, bool) {
	if db == nil {
		return 0, false
	}
	f, ok := db.actor_value_by_index[index]
	return f, ok
}

// actor_value_id resolves an actor value's name (case-insensitive, with or without the "AV"
// prefix) to its AVIF form — how a script or hand-written content names one. ok=false when no
// such actor value is indexed.
actor_value_id :: proc(db: ^DB, name: string) -> (Form_ID, bool) {
	if db == nil {
		return 0, false
	}
	key := strings.to_lower(name, context.temp_allocator)
	if len(key) > 2 && key[:2] == "av" {
		if f, ok := db.actor_value_by_key[key[2:]]; ok {
			return f, true
		}
	}
	f, ok := db.actor_value_by_key[key]
	return f, ok
}

// actor_value_index_of resolves an actor value's name to its engine index — the inverse of
// actor_value_key, for a script that names an AV as a string. ok=false when unknown or the form
// carries no index (a mod-added AVIF).
actor_value_index_of :: proc(db: ^DB, name: string) -> (i32, bool) {
	form, ok := actor_value_id(db, name)
	if !ok {
		return 0, false
	}
	av, has := actor_value_info(db, form)
	if !has || !av.has_index {
		return 0, false
	}
	return av.index, true
}

// --- teardown ---------------------------------------------------------------------------

@(private)
free_actor_value_info :: proc(db: ^DB, av: Actor_Value_Info) {
	delete(av.key, db.allocator)
	delete(av.editor_id, db.allocator)
	delete(av.description, db.allocator)
}

// free_actor_indexes releases everything this file's maps own. Called from destroy.
@(private)
free_actor_indexes :: proc(db: ^DB) {
	for _, r in db.races {
		delete(r.description, db.allocator)
	}
	delete(db.races)
	for _, c in db.classes {
		delete(c.description, db.allocator)
	}
	delete(db.classes)
	delete(db.voice_types)
	for _, o in db.outfits {
		delete(o, db.allocator)
	}
	delete(db.outfits)
	for _, av in db.actor_value_info {
		free_actor_value_info(db, av)
	}
	delete(db.actor_value_info)
	delete(db.actor_value_by_index)
	for k, _ in db.actor_value_by_key {
		delete(k, db.allocator)
	}
	delete(db.actor_value_by_key)
}
