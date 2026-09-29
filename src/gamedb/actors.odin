package gamedb

// Actor-identity indexing: the records an NPC_ links out to (RACE, CLAS, VTYP, OTFT) plus AVIF,
// the actor-value definitions. Before this, Actor_Base's race/class/voice/outfit were remapped
// FormIDs pointing at records nobody indexed — stored, but dead. Decoders live in
// src/formats/esm/records_actors.odin; this file owns the storage, the remap and the queries.
//
// AVIF gives an actor value's description and perk tree; its name and index come from AV_NAMES.

import "core:strings"
import "../formats/esm"

// Race is a RACE's identity + stat layer: what it's called, the skill bonuses it grants at
// creation, and its body scale. Appearance (tint layers, head parts, body data — 20k+
// subrecords across the 99 vanilla races) is deliberately not decoded; add it with a character
// /appearance phase, not here.
Race :: struct {
	info:        esm.Race_Info,
	description: string, // DESC (owned; "" when absent)
	spells:      []Form_ID, // SPLO (owned)
	skeletons:   [2]string, // ANAM after the male and female markers: skeleton .nif paths (owned)
	walk, run:   Form_ID, // WKMV, RNMV movement types; 0 on the playable races, which use the defaults
	voices:      [2]Form_ID, // VTCK: the male and female default voice types
}

// Class is a CLAS's level-up weighting: which skills an NPC of this class favours and how
// its health/magicka/stamina split. `training_skill` is an actor-value index (AV_NAMES).
Class :: struct {
	info:        esm.Class_Info,
	description: string, // DESC (owned; "" when absent)
}

// Actor_Value_Info is one AVIF record: an actor value's identity. `index` is its engine
// ActorValue index when the form is a base-game AVIF (see esm.ACTOR_VALUE_BLOCKS); has_index is
// false for a mod-added AVIF, which is a form but not a new enum slot.
Actor_Value_Info :: struct {
	index:       i32,
	has_index:   bool,
	editor_id:   string, // owned, as authored
	description: string, // DESC (owned; "" when absent)
	skill:       esm.Skill_XP, // AVSK, the 18 skills only
	has_skill:   bool,
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
	index_edid(db, rec.form_id, fl)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl)
	index_keywords(db, rec.form_id, fl, fm)

	r: Race
	r.info, _ = esm.race_info(fl)
	r.description = index_description(db, fl)
	r.spells = remap_formid_list(db, esm.formid_list(fl, "SPLO", context.allocator), fm)
	if f, has := esm.find_field(fl, "WKMV"); has {r.walk = esm.remap_form(fm, esm.field_u32(f) or_else 0)}
	if f, has := esm.find_field(fl, "RNMV"); has {r.run = esm.remap_form(fm, esm.field_u32(f) or_else 0)}
	if f, has := esm.find_field(fl, "VTCK"); has && len(f.data) >= 8 {
		for i in 0 ..< 2 {r.voices[i] = esm.remap_form(fm, u32((^u32le)(&f.data[i * 4])^))}
	}
	n := 0
	for f in fl {
		if f.type != "ANAM" || n >= 2 {continue}
		r.skeletons[n] = strings.clone(strings.trim_right_null(string(f.data)), db.allocator)
		n += 1
	}

	if old, existed := db.races[rec.form_id]; existed {
		delete(old.description, db.allocator) // override: free the previous clone
		delete(old.spells, db.allocator)
		for s in old.skeletons {delete(s, db.allocator)}
	}
	db.races[rec.form_id] = r
}

// index_movement keeps a MOVT's forward walk and run speeds (SPED floats 4 and 5, units/s).
@(private)
index_movement :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	sped, has := esm.find_field(fl, "SPED")
	if !has || len(sped.data) < 24 {return}
	db.movement[rec.form_id] = {f32((^f32le)(&sped.data[16])^), f32((^f32le)(&sped.data[20])^)}
}

// gait_speeds is how fast a race walks and runs forward: its movement types, else the defaults.
gait_speeds :: proc(db: ^DB, race: Form_ID) -> (walk, run: f32, ok: bool) {
	r, _ := db.races[race]
	walk_type := r.walk if r.walk != 0 else default_object(db, "DMWL")
	run_type := r.run if r.run != 0 else default_object(db, "DMRN")
	w, wok := db.movement[walk_type]
	rn, rok := db.movement[run_type]
	return w[0], rn[1], wok && rok
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
	index_voice_edid(db, rec.form_id, fl)
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
	av.skill, av.has_skill = esm.skill_xp(fl)
	if rec.form_id >> 32 == 0 {
		av.index, av.has_index = esm.actor_value_index(u32(rec.form_id))
	}

	if old, existed := db.actor_value_info[rec.form_id]; existed {
		free_actor_value_info(db, old)
	}
	db.actor_value_info[rec.form_id] = av
	if av.has_index {
		db.actor_value_by_index[av.index] = rec.form_id
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

// Spell_Source is one part of an actor's records' spell list and the form that owns it.
Spell_Source :: struct {
	owner:  Form_ID, // the RACE, or the actor's own NPC_
	spells: []Form_ID,
}

// spell_sources is the spell list an actor's records give it: its race's, then its NPC_'s, each
// through its template (`pick` standing in for a leveled one). Leveled lists stay unrolled.
spell_sources :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> [2]Spell_Source {
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	npc, ok := db.actors[base]
	if !ok {return {}}
	race_id := template_part(db, base, esm.ACBS_TEMPLATE_TRAITS, pick).race
	race, _ := race_of(db, race_id)
	return {{race_id, race.spells}, {base, template_part(db, base, esm.ACBS_TEMPLATE_SPELLS, pick).spells}}
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
// Each entry's `skill` is an actor-value index (AV_NAMES). `count` is how
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

// actor_value_display returns an actor value's player-facing name: its AVIF FULL when the record
// has one (24 of the 149 do), else its AV_NAMES name. ok=false for an index outside the table.
actor_value_display :: proc(db: ^DB, index: i32) -> (string, bool) {
	if index < 0 || index >= esm.ACTOR_VALUE_COUNT {
		return "", false
	}
	if form, ok := actor_value_by_index(db, index); ok {
		if full := name_of(db, form); full != "" {
			return full, true
		}
	}
	return AV_NAMES[index], true
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

// --- teardown ---------------------------------------------------------------------------

@(private)
free_actor_value_info :: proc(db: ^DB, av: Actor_Value_Info) {
	delete(av.editor_id, db.allocator)
	delete(av.description, db.allocator)
}

// free_actor_indexes releases everything this file's maps own. Called from destroy.
@(private)
free_actor_indexes :: proc(db: ^DB) {
	for _, r in db.races {
		delete(r.description, db.allocator)
		delete(r.spells, db.allocator)
		for s in r.skeletons {delete(s, db.allocator)}
	}
	delete(db.races)
	for _, c in db.classes {
		delete(c.description, db.allocator)
	}
	delete(db.classes)
	delete(db.voice_types)
	for _, e in db.voice_edids {delete(e, db.allocator)}
	delete(db.voice_edids)
	for _, o in db.outfits {
		delete(o, db.allocator)
	}
	delete(db.outfits)
	for _, av in db.actor_value_info {
		free_actor_value_info(db, av)
	}
	delete(db.actor_value_info)
	delete(db.actor_value_by_index)
}
