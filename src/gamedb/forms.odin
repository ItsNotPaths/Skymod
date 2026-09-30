package gamedb

// Form-metadata indexing: the record layer beneath the script runtime's baseline queries —
// keywords (Form.HasKeyword), linked references (GetLinkedRef), faction identity + membership,
// the magic records (SPEL/SCRL/ENCH/MGEF), and quest alias definitions. Decoders live in
// src/formats/esm (records_forms.odin); this file owns the DB-side storage, the local→global
// FormID remap, and the queries. Every proc here follows the file's house rules: a later plugin
// overriding a record replaces it wholesale (free the previous owned data first), and the walk
// has no temp-allocator reset, so scratch slices are freed explicitly.

import "base:runtime"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../formid"

// --- keywords ---------------------------------------------------------------------------

// index_keywords stores a form's KWDA keyword set, remapped to global space. Called from every
// index proc whose record type can carry keywords (base forms, actors, magic records) — a form
// with no KWDA stores nothing, so absence and "empty set" are the same lookup.
@(private)
index_keywords :: proc(db: ^DB, form: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	raw := esm.keywords(fl, context.allocator) // walk has no temp reset — remap_formid_list frees it
	if raw == nil {
		return
	}
	if old, existed := db.keywords[form]; existed {
		delete(old, db.allocator) // override: free the previous set
	}
	db.keywords[form] = remap_formid_list(db, raw, fm)
}

// index_keyword records a KYWD's identity. A keyword carries no FULL — its editor id IS its
// name, and it's how content addresses one by hand ("VendorItemFood"), so both directions are
// stored. The reverse key is lowercased for case-insensitive lookup, matching cell_by_edid.
@(private)
index_keyword :: proc(db: ^DB, rec: esm.Record) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	index_edid(db, rec.form_id, fl)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	edid := esm.editor_id(fl)
	if edid == "" {
		return
	}
	if old, existed := db.keyword_edid[rec.form_id]; existed {
		delete(old, db.allocator) // override: free the previous clone
	}
	db.keyword_edid[rec.form_id] = strings.clone(edid, db.allocator)
	lower := strings.to_lower(edid, db.allocator)
	if _, seen := db.keyword_by_edid[lower]; seen {
		delete(lower, db.allocator) // key already present — the value just gets overwritten
	}
	db.keyword_by_edid[lower] = rec.form_id
}

// keywords_of returns a form's keyword set (empty when the form has none / isn't indexed). The
// slice is owned by the DB — don't mutate or free it.
keywords_of :: proc(db: ^DB, form: Form_ID) -> []Form_ID {
	if db == nil {
		return nil
	}
	return db.keywords[form]
}

// has_keyword reports whether a form carries `keyword` — the baseline behind Form.HasKeyword.
// Sets are small (vanilla forms carry ≤ ~8), so a linear scan beats a per-form set.
has_keyword :: proc(db: ^DB, form: Form_ID, keyword: Form_ID) -> bool {
	for k in keywords_of(db, form) {
		if k == keyword {
			return true
		}
	}
	return false
}

// keyword_id resolves a keyword's editor id (case-insensitive) to its form — how hand-written
// content names a keyword without hardcoding a formID. ok=false when no such keyword is indexed.
keyword_id :: proc(db: ^DB, editor_id: string) -> (Form_ID, bool) {
	if db == nil {
		return 0, false
	}
	lower := strings.to_lower(editor_id, context.temp_allocator)
	f, ok := db.keyword_by_edid[lower]
	return f, ok
}

// keyword_editor_id returns a keyword form's editor id ("" when it isn't an indexed KYWD). Owned
// by the DB.
keyword_editor_id :: proc(db: ^DB, keyword: Form_ID) -> string {
	if db == nil {
		return ""
	}
	return db.keyword_edid[keyword]
}

// --- linked references ------------------------------------------------------------------

// index_linked_refs stores a placed ref's XLKR links, remapped. Called from index_ref; most refs
// link nothing, so nothing is stored for them.
@(private)
index_linked_refs :: proc(db: ^DB, form: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	raw := esm.linked_refs(fl, context.allocator) // walk has no temp reset — explicit free
	if raw == nil {
		if old, existed := db.linked_refs[form]; existed {
			delete(old, db.allocator) // override dropped the links
			delete_key(&db.linked_refs, form)
		}
		return
	}
	defer delete(raw, context.allocator)
	links := make([]Linked_Ref, len(raw), db.allocator)
	for l, i in raw {
		links[i] = Linked_Ref {
			keyword = esm.remap_form(fm, l.keyword),
			ref     = esm.remap_form(fm, l.ref),
		}
	}
	if old, existed := db.linked_refs[form]; existed {
		delete(old, db.allocator) // override: free the previous links
	}
	db.linked_refs[form] = links
}

// linked_refs_of returns a placed ref's XLKR links (empty when it links nothing). Owned by the DB.
linked_refs_of :: proc(db: ^DB, ref: Form_ID) -> []Linked_Ref {
	if db == nil {
		return nil
	}
	return db.linked_refs[ref]
}

// linked_ref resolves one link channel: the reference `ref` points at through `keyword`. Pass
// keyword 0 for the DEFAULT link — what a bare GetLinkedRef() returns. ok=false when the ref has
// no link on that channel.
linked_ref :: proc(db: ^DB, ref: Form_ID, keyword: Form_ID = 0) -> (Form_ID, bool) {
	for l in linked_refs_of(db, ref) {
		if l.keyword == keyword {
			return l.ref, true
		}
	}
	return 0, false
}

// --- FACT -------------------------------------------------------------------------------

// index_faction decodes a FACT baseline: DATA flags, XNAM relations, the CRVA crime table, and
// the rank ladder. Ranks need an ORDERED walk — an RNAM declares a rank index and the MNAM /
// FNAM that follow are its male / female titles (the same tags mean other things elsewhere in
// the record), so this mirrors index_quest's INDX/QSDT pattern rather than using find_field.
@(private)
index_faction :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	index_edid(db, rec.form_id, fl)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl) // FULL — the faction's display name ("Companions")

	f: Faction
	f.flags, _ = esm.faction_flags(fl)
	if chest, has := esm.subrecord_formid(fl, "VENC"); has {
		db.vendor_chests[esm.remap_form(fm, chest)] = true
	}
	f.crime, f.has_crime = esm.faction_crime(fl)
	refs := [?]struct {tag: string, to: ^Form_ID} {
		{"JAIL", &f.jail},
		{"WAIT", &f.follower_wait},
		{"STOL", &f.stolen_chest},
		{"PLCN", &f.player_chest},
		{"CRGR", &f.crime_group},
		{"JOUT", &f.jail_outfit},
	}
	for r in refs {
		if id, has := esm.subrecord_formid(fl, r.tag); has {r.to^ = esm.remap_form(fm, id)}
	}
	for field, i in fl {
		switch field.type {
		case "VENV":
			if len(field.data) >= 4 {
				f.vendor.start = u16(field.data[0]) | u16(field.data[1]) << 8
				f.vendor.end = u16(field.data[2]) | u16(field.data[3]) << 8
			}
		case "CTDA":
			if f.vendor.conditions == nil {f.vendor.conditions = index_conditions(db, esm.condition_run(fl, i), fm)}
		}
	}

	if raw := esm.faction_relations(fl, context.allocator); raw != nil {
		defer delete(raw, context.allocator)
		rels := make([]Faction_Relation, len(raw), db.allocator)
		for r, i in raw {
			rels[i] = Faction_Relation {
				faction  = esm.remap_form(fm, r.faction),
				modifier = r.modifier,
				combat   = r.combat,
			}
		}
		f.relations = rels
	}

	ranks := make([dynamic]Faction_Rank, 0, 8, db.allocator)
	for field in fl {
		switch field.type {
		case "RNAM":
			if idx, has := esm.field_u32(field); has {
				append(&ranks, Faction_Rank{index = idx})
			}
		case "MNAM", "FNAM":
			// Titles for the rank the preceding RNAM opened. Short-text lstrings → STRINGS
			// (or inline for a non-localized plugin).
			if len(ranks) == 0 {
				continue
			}
			txt := resolve_lstring(db, field, db.cur_strings)
			if txt == "" {
				continue
			}
			cur := &ranks[len(ranks) - 1]
			if field.type == "MNAM" {
				cur.male_title = strings.clone(txt, db.allocator)
			} else {
				cur.female_title = strings.clone(txt, db.allocator)
			}
		}
	}
	if len(ranks) > 0 {
		f.ranks = ranks[:]
	} else {
		delete(ranks)
	}

	if old, existed := db.factions[rec.form_id]; existed {
		free_faction(db, old) // override: free the previous owned data
	}
	db.factions[rec.form_id] = f
}

// faction_of returns a faction's decoded baseline (ok=false when the form isn't an indexed FACT).
// The struct's slices are owned by the DB — don't mutate or free them.
faction_of :: proc(db: ^DB, faction: Form_ID) -> (Faction, bool) {
	if db == nil {
		return {}, false
	}
	f, ok := db.factions[faction]
	return f, ok
}

// faction_rank_title returns the title shown for `rank` in `faction`, picking the female title
// when `female` and one is authored (most vanilla factions title only the male column, so that's
// the fallback). ok=false when the faction / rank isn't indexed or carries no title.
faction_rank_title :: proc(db: ^DB, faction: Form_ID, rank: u32, female := false) -> (string, bool) {
	f, ok := faction_of(db, faction)
	if !ok {
		return "", false
	}
	for r in f.ranks {
		if r.index != rank {
			continue
		}
		if female && r.female_title != "" {
			return r.female_title, true
		}
		if r.male_title != "" {
			return r.male_title, true
		}
		return "", false
	}
	return "", false
}

// faction_reaction returns how `faction` regards `other` — the XNAM combat reaction plus its
// disposition modifier. ok=false when no relation is authored between them (the neutral default).
faction_reaction :: proc(
	db: ^DB,
	faction, other: Form_ID,
) -> (
	reaction: esm.Combat_Reaction,
	modifier: i32,
	ok: bool,
) {
	f, found := faction_of(db, faction)
	if !found {
		return .Neutral, 0, false
	}
	for r in f.relations {
		if r.faction == other {
			return r.combat, r.modifier, true
		}
	}
	return .Neutral, 0, false
}

// actor_factions is an NPC_'s authored SNAM factions, through its factions template; `pick`
// stands in for a leveled one. A placed actor reads its base's.
actor_factions :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> []Faction_Membership {
	if db == nil {return nil}
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	return template_part(db, base, esm.ACBS_TEMPLATE_FACTIONS, pick).factions
}

// actor_crime_faction is an NPC_'s CRIF, through its factions template. A placed actor reads its base's.
actor_crime_faction :: proc(db: ^DB, form: Form_ID, pick: Form_ID = 0) -> Form_ID {
	if db == nil {return 0}
	base := form
	if r, ok := db.ref_by_id[form]; ok {base = r.base}
	return template_part(db, base, esm.ACBS_TEMPLATE_FACTIONS, pick).crime_faction
}

// actor_faction_rank returns an NPC_'s BASELINE rank in `faction`; ok=false when it has no row.
actor_faction_rank :: proc(db: ^DB, base: Form_ID, faction: Form_ID, pick: Form_ID = 0) -> (i8, bool) {
	for m in actor_factions(db, base, pick) {
		if m.faction == faction {return m.rank, true}
	}
	return 0, false
}

// --- magic: SPEL / SCRL / ENCH / MGEF ----------------------------------------------------

// index_spell decodes a SPEL or SCRL into its cast parameters + effect list. Both carry the same
// SPIT block; `scroll` records which record type it came from (a scroll dispatches as its own
// Papyrus class and is also a carriable item — see the SCRL case in visit).
@(private)
index_spell :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map, scroll: bool) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	index_edid(db, rec.form_id, fl)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	// SPEL isn't a base type, so its name/keywords land here. A SCRL redoes both (index_base
	// already ran) — 74 records, not worth a branch.
	index_name(db, rec.form_id, fl)
	index_keywords(db, rec.form_id, fl, fm)

	sp := Spell{scroll = scroll}
	sp.info, _ = esm.spell_info(fl)
	sp.half_cost_perk = esm.remap_form(fm, sp.info.half_cost_perk)
	sp.effects = index_effects(db, fl, fm)

	if old, existed := db.spells[rec.form_id]; existed {
		free_effects(db, old.effects) // override: free the previous effect list
	}
	db.spells[rec.form_id] = sp
}

// index_enchantment decodes an ENCH into its ENIT parameters + the effects it grants.
@(private)
index_enchantment :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl)
	index_keywords(db, rec.form_id, fl, fm)

	e: Enchantment
	e.info, _ = esm.enchant_info(fl)
	e.base_enchantment = esm.remap_form(fm, e.info.base_enchantment)
	e.worn_restrictions = esm.remap_form(fm, e.info.worn_restrictions)
	e.effects = index_effects(db, fl, fm)

	if old, existed := db.enchantments[rec.form_id]; existed {
		free_effects(db, old.effects) // override: free the previous effect list
	}
	db.enchantments[rec.form_id] = e
}

// index_potion records an ALCH's effects (potions, poisons and food).
@(private)
index_potion :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	p := Potion{effects = index_effects(db, fl, fm), poison = esm.potion_is_poison(fl)}
	if old, existed := db.potions[rec.form_id]; existed {
		free_effects(db, old.effects) // override: free the previous effect list
	}
	db.potions[rec.form_id] = p
}

// potion_of returns an ALCH's baseline (ok=false when the form isn't an indexed potion).
potion_of :: proc(db: ^DB, potion: Form_ID) -> (Potion, bool) {
	if db == nil {
		return {}, false
	}
	p, ok := db.potions[potion]
	return p, ok
}

// index_magic_effect decodes an MGEF: what the effect does (archetype + actor values), its cost,
// and its player-facing description. The DNAM description resolves in the PLAIN STRINGS table,
// not DLSTRINGS — verified against Skyrim - Interface.bsa (0x000126B1 = "Stamina regenerates
// <mag>% slower." in STRINGS, absent from DLSTRINGS/ILSTRINGS). Same as LSCR DESC: it's a short
// display line, and only genuinely long text (quest journal CNAM, book DESC) lives in DLSTRINGS.
@(private)
index_magic_effect :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	index_edid(db, rec.form_id, fl)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl) // FULL — the effect name shown in the magic menu
	index_keywords(db, rec.form_id, fl, fm)

	me: Magic_Effect
	me.info, _ = esm.magic_effect_info(fl)
	me.projectile = esm.remap_form(fm, me.info.projectile)
	// (hole hazards :tags (magic world unclaimed) :sev gap) hazards come only from PlaceAtMe, placed PHZD refs and Spawn Hazard effects: no impact data set places one where a spell lands (the walls; 240 MGEFs), no explosion does (4 EXPL), and no Lobber projectile sits as a rune (an rt.zone with no `every`). Their art is effect-fx.
	me.explosion = esm.remap_form(fm, me.info.explosion)
	me.related = esm.remap_form(fm, me.info.related)
	for raw, slot in me.info.art {me.art[slot] = esm.remap_form(fm, raw)}
	if f, has := esm.find_field(fl, "SNDD"); has {
		for i := 0; i + 8 <= len(f.data); i += 8 {
			if kind := u32((^u32le)(&f.data[i])^); kind <= u32(max(Effect_Sound)) {
				me.sounds[Effect_Sound(kind)] = esm.remap_form(fm, u32((^u32le)(&f.data[i + 4])^))
			}
		}
	}
	if f, has := esm.find_field(fl, "DNAM"); has {
		if txt := resolve_lstring(db, f, db.cur_strings); txt != "" {
			me.description = strings.clone(txt, db.allocator)
		}
	}

	me.conditions = index_conditions(db, fl, fm)

	if old, existed := db.magic_effects[rec.form_id]; existed {
		delete(old.description, db.allocator) // override: free the previous clone
		free_conditions(db, old.conditions)
	}
	db.magic_effects[rec.form_id] = me
}

// index_effects decodes a record's EFID/EFIT effect list into DB-owned, remapped entries, each with
// the CTDAs up to the next EFID. Shared by every magic record (spell, scroll, enchantment). nil
// when the record applies none.
@(private)
index_effects :: proc(db: ^DB, fl: []esm.Field, fm: ^esm.Form_Map) -> []Magic_Effect_Ref {
	raw := esm.effect_items(fl, context.allocator) // walk has no temp reset — explicit free
	if raw == nil {
		return nil
	}
	defer delete(raw, context.allocator)
	starts := make([dynamic]int, 0, len(raw) + 1, context.temp_allocator)
	for f, k in fl {
		if f.type == "EFID" && len(f.data) >= 4 {append(&starts, k)}
	}
	append(&starts, len(fl))
	out := make([]Magic_Effect_Ref, len(raw), db.allocator)
	for e, i in raw {
		out[i] = Magic_Effect_Ref {
			effect     = esm.remap_form(fm, e.effect),
			magnitude  = e.magnitude,
			area       = e.area,
			duration   = f32(e.duration),
			conditions = index_conditions(db, fl[starts[i]:starts[i + 1]], fm),
		}
	}
	return out
}

@(private)
free_effects :: proc(db: ^DB, effects: []Magic_Effect_Ref) {
	for e in effects {free_conditions(db, e.conditions)}
	delete(effects, db.allocator)
}

// spell_of returns a SPEL/SCRL's baseline (ok=false when the form isn't an indexed spell). Its
// effect slice is owned by the DB.
spell_of :: proc(db: ^DB, spell: Form_ID) -> (Spell, bool) {
	if db == nil {
		return {}, false
	}
	s, ok := db.spells[spell]
	return s, ok
}

// enchantment_of returns an ENCH's baseline (ok=false when the form isn't an indexed enchantment).
enchantment_of :: proc(db: ^DB, ench: Form_ID) -> (Enchantment, bool) {
	if db == nil {
		return {}, false
	}
	e, ok := db.enchantments[ench]
	return e, ok
}

// effect_items_of is the effect list of a spell, scroll, enchantment or potion (nil for any other form).
effect_items_of :: proc(db: ^DB, source: Form_ID) -> []Magic_Effect_Ref {
	if sp, ok := spell_of(db, source); ok {return sp.effects}
	if e, ok := enchantment_of(db, source); ok {return e.effects}
	if p, ok := potion_of(db, source); ok {return p.effects}
	return nil
}

// magic_effect_of returns an MGEF's baseline (ok=false when the form isn't an indexed effect).
magic_effect_of :: proc(db: ^DB, effect: Form_ID) -> (Magic_Effect, bool) {
	if db == nil {
		return {}, false
	}
	m, ok := db.magic_effects[effect]
	return m, ok
}

// spell_costliest_effect returns the index into a spell's effect list of its most expensive
// effect — the one Skyrim names the spell's "primary" (GetCostliestEffectIndex). Cost is the
// effect's MGEF base cost scaled by the magnitude/duration this spell applies it at; ties keep
// the earlier entry. ok=false for an unindexed spell or one with no effects.
spell_costliest_effect :: proc(db: ^DB, spell: Form_ID) -> (int, bool) {
	sp, found := spell_of(db, spell)
	if !found || len(sp.effects) == 0 {
		return 0, false
	}
	best, best_cost := 0, f32(-1)
	for e, i in sp.effects {
		me, has := magic_effect_of(db, e.effect)
		if !has {
			continue
		}
		// Skyrim's cost curve: base × magnitude^1.1 × (duration/10)^1.1, with the exponent
		// dropped here — relative ORDER is what the index needs, and it's monotonic either way.
		cost := me.info.base_cost * max(e.magnitude, 1) * max(f32(e.duration) / 10, 1)
		if cost > best_cost {
			best, best_cost = i, cost
		}
	}
	if best_cost < 0 {
		return 0, false
	}
	return best, true
}

// --- QUST aliases -------------------------------------------------------------------------

// index_quest_aliases decodes a quest's alias slots, remapping each fill's form operand. Called
// from index_quest with the fields it already parsed.
@(private)
index_quest_aliases :: proc(db: ^DB, fl: []esm.Field, fm: ^esm.Form_Map) -> []Quest_Alias {
	raw := esm.quest_aliases(fl, context.allocator) // walk has no temp reset — explicit free
	if raw == nil {
		return nil
	}
	defer delete(raw, context.allocator)
	out := make([]Quest_Alias, len(raw), db.allocator)
	for a, i in raw {
		display_name, _ := esm.subrecord_formid(a.body, "ALDN")
		out[i] = Quest_Alias {
			id           = a.id,
			location     = a.location,
			flags        = a.flags,
			fill         = a.fill,
			target       = esm.remap_form(fm, a.target),
			alias        = a.alias,
			force_into   = a.force_into,
			event_member = i32(a.event_member),
			create_in    = a.create_in,
			create_level = a.create_level,
			conditions   = index_conditions(db, a.match, fm),
			factions     = remap_formid_list(db, esm.formid_list(a.body, "ALFC"), fm),
			keywords     = remap_formid_list(db, esm.keywords(a.body), fm),
			packages     = remap_formid_list(db, esm.formid_list(a.body, "ALPC"), fm),
			overrides    = override_packages(a.body, fm),
			spells       = remap_formid_list(db, esm.formid_list(a.body, "ALSP"), fm),
			items        = remap_contents(db, esm.container_contents(a.body), fm),
			display_name = esm.remap_form(fm, display_name),
			name         = strings.clone(a.name, db.allocator),
		}
	}
	return out
}

// quest_aliases_of returns a quest's alias slots in declaration order (empty for an unindexed
// quest or one with no aliases). Owned by the DB.
quest_aliases_of :: proc(db: ^DB, quest: Form_ID) -> []Quest_Alias {
	qb, ok := quest_baseline_of(db, quest)
	if !ok {
		return nil
	}
	return qb.aliases
}

// quest_alias returns one alias slot by the id its scripts address it with (Quest.GetAlias).
// ok=false when the quest defines no such alias.
quest_alias :: proc(db: ^DB, quest: Form_ID, id: u32) -> (Quest_Alias, bool) {
	for a in quest_aliases_of(db, quest) {
		if a.id == id {
			return a, true
		}
	}
	return {}, false
}

// quest_alias_forced_ref returns the reference an alias is PINNED to at authoring time (a Specific
// fill). ok=false for every other fill kind — those are filled by the quest engine when the
// quest starts, so the runtime alias store owns them and this baseline has nothing to offer.
quest_alias_forced_ref :: proc(db: ^DB, quest: Form_ID, id: u32) -> (Form_ID, bool) {
	a, ok := quest_alias(db, quest, id)
	if !ok || a.fill != .Specific || a.target == 0 {
		return 0, false
	}
	return a.target, true
}

// unique_actor_ref returns the placed actor of a unique NPC_, what a Unique_Actor alias fill holds.
unique_actor_ref :: proc(db: ^DB, base: Form_ID) -> (Form_ID, bool) {
	r, ok := db.unique_refs[base]
	return r, ok
}

// index_alias_targets indexes what alias fills search: each unique NPC_'s placed actor, the
// persistent refs, the default-link children, and every ref a Specific or Unique_Actor fill names.
// Runs once every plugin is walked.
@(private)
index_alias_targets :: proc(db: ^DB) {
	db.unique_refs = make(map[Form_ID]Form_ID, 1024, db.allocator)
	db.alias_targets = make(map[Form_ID]bool, 4096, db.allocator)
	for _, refs in db.actor_refs {
		for r in refs {
			a, ok := db.actors[r.base]
			if !ok || a.flags & esm.ACBS_UNIQUE == 0 || r.deleted {continue}
			if prev, seen := db.unique_refs[r.base]; seen && prev < r.form_id {continue}
			db.unique_refs[r.base] = r.form_id
		}
	}
	persistent := make([dynamic]Form_ID, db.allocator)
	for id, r in db.ref_by_id {
		if r.persistent && !r.deleted && id != formid.START_CHARACTER {append(&persistent, id)}
	}
	slice.sort(persistent[:])
	db.persistent_refs = persistent[:]
	db.ref_types = make(map[Form_ID][dynamic]Form_ID, 4096, db.allocator)
	for _, l in db.locations {
		for s in l.special_refs {
			if s.ref not_in db.ref_types {db.ref_types[s.ref] = make([dynamic]Form_ID, db.allocator)}
			append(&db.ref_types[s.ref], s.ref_type)
		}
	}
	index_search(db)
	db.linked_children = make(map[Form_ID][dynamic]Form_ID, 1024, db.allocator)
	for ref, links in db.linked_refs {
		for l in links {
			if l.keyword != 0 {continue}
			if l.ref not_in db.linked_children {db.linked_children[l.ref] = make([dynamic]Form_ID, db.allocator)}
			append(&db.linked_children[l.ref], ref)
		}
	}
	for _, qb in db.quest_baseline {
		for a in qb.aliases {
			#partial switch a.fill {
			case .Specific:
				if !a.location {db.alias_targets[a.target] = true}
			case .Unique_Actor:
				if r, ok := db.unique_refs[a.target]; ok {db.alias_targets[r] = true}
			}
		}
	}
}

// --- LCTN / WTHR ---------------------------------------------------------------------------

// index_location decodes an LCTN: its display name, the location that contains it (PNAM), its
// keywords, and its map-marker tint. The parent link is the tree Location.IsChild walks; the
// special refs (LCSR/ACSR/RCSR). The persistent and unique-NPC lists and LCEC cells stay undecoded.
@(private)
index_location :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	index_edid(db, rec.form_id, fl)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl)
	index_keywords(db, rec.form_id, fl, fm)

	loc: Location
	if p, has := esm.location_parent(fl); has {
		loc.parent = esm.remap_form(fm, p)
	}
	loc.marker_color, loc.has_marker_color = esm.location_marker_color(fl)
	if c, has := esm.subrecord_formid(fl, "FNAM"); has {loc.crime_faction = esm.remap_form(fm, c)}
	master, added, removed := esm.location_special_refs(fl)
	defer {delete(master);delete(added);delete(removed)}
	old, existed := db.locations[rec.form_id]
	if existed {delete(old.special_refs, db.allocator)}
	if len(master) > 0 || !existed {
		if existed {delete(old.master_refs, db.allocator)}
		loc.master_refs = remap_special_refs(fm, master, db.allocator)
	} else {
		loc.master_refs = old.master_refs // an override keeps the master's list
	}
	refs := make([dynamic]Special_Ref, 0, len(loc.master_refs) + len(added), db.allocator)
	master_loop: for s in loc.master_refs {
		for r in removed {
			if esm.remap_form(fm, r) == s.ref {continue master_loop}
		}
		append(&refs, s)
	}
	for r in added {append(&refs, Special_Ref{esm.remap_form(fm, r.ref_type), esm.remap_form(fm, r.ref)})}
	loc.special_refs = refs[:]
	db.locations[rec.form_id] = loc
}

// index_weather decodes a WTHR: its DATA classification + sky scalars, FNAM fog, the NAM0 colour
// table (variable row count — see esm.weather_colors), and the per-time-of-day imagespaces. This
// is the authored half of the sky/lighting look; nothing consumes it yet (the lighting pass
// does), but it costs one pass over 84 records to have it ready.
@(private)
index_weather :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	index_name(db, rec.form_id, fl)

	w: Weather
	w.info, _ = esm.weather_info(fl)
	w.fog, w.has_fog = esm.weather_fog(fl)
	w.color_rows = esm.weather_colors(fl, &w.colors)
	if imsp, has := esm.weather_imagespaces(fl); has {
		for im, i in imsp {
			w.imagespaces[i] = esm.remap_form(fm, im)
		}
	}
	db.weathers[rec.form_id] = w
}

// location_of returns a location's decoded baseline (ok=false when the form isn't an indexed
// LCTN). Its keywords live in the shared keyword index — use keywords_of / has_keyword.
location_of :: proc(db: ^DB, location: Form_ID) -> (Location, bool) {
	if db == nil {
		return {}, false
	}
	l, ok := db.locations[location]
	return l, ok
}

// location_within reports whether `loc` is `area` or sits under it.
location_within :: proc(db: ^DB, loc, area: Form_ID) -> bool {
	return loc == area || location_is_child(db, loc, area)
}

// cell_location is a cell's XLCN location, else its worldspace's; 0 when it has neither.
cell_location :: proc(db: ^DB, cell_id: Form_ID) -> Form_ID {
	cell, ok := cell_by_formid(db, cell_id)
	if !ok {return 0}
	if cell.location != 0 {return cell.location}
	return db.world_location[cell.world_form_id]
}

@(private = "file")
remap_special_refs :: proc(fm: ^esm.Form_Map, raw: []esm.Special_Ref, allocator: runtime.Allocator) -> []Special_Ref {
	out := make([]Special_Ref, len(raw), allocator)
	for r, i in raw {out[i] = {esm.remap_form(fm, r.ref_type), esm.remap_form(fm, r.ref)}}
	return out
}

// location_special_refs is a location's refs of a location ref type (LCRT); 0 for any type.
location_special_refs :: proc(db: ^DB, location, ref_type: Form_ID) -> []Form_ID {
	l, ok := db.locations[location]
	if !ok {return nil}
	out := make([dynamic]Form_ID, context.temp_allocator)
	for s in l.special_refs {
		if ref_type == 0 || s.ref_type == ref_type {append(&out, s.ref)}
	}
	return out[:]
}

// location_with_keyword is the location itself or its nearest parent with the keyword; no keyword
// is the location itself. 0 when none has it.
location_with_keyword :: proc(db: ^DB, location, keyword: Form_ID) -> Form_ID {
	loc := location
	for _ in 0 ..< LOCATION_TREE_MAX_DEPTH {
		if loc == 0 || keyword == 0 || has_keyword(db, loc, keyword) {return loc}
		loc = db.locations[loc].parent
	}
	return 0
}

// editor_location is the location a placed ref was put in: its cell's, at its placed position.
editor_location :: proc(db: ^DB, ref: Form_ID) -> Form_ID {
	r, ok := db.ref_by_id[ref]
	if !ok {return 0}
	return cell_location(db, grid_cell(db, r.cell_form_id, r.pos))
}

// index_search indexes the refs a world alias search tests (the persistent refs, and each unique
// actor placed elsewhere) by location ref type and by base; refs of a leveled base go apart.
index_search :: proc(db: ^DB) {
	db.search_by_type = make(map[Form_ID][dynamic]Form_ID, 1024, db.allocator)
	db.search_by_base = make(map[Form_ID][dynamic]Form_ID, 8192, db.allocator)
	db.search_leveled = make([dynamic]Form_ID, db.allocator)
	add :: proc(db: ^DB, m: ^map[Form_ID][dynamic]Form_ID, key, ref: Form_ID) {
		if key not_in m {m[key] = make([dynamic]Form_ID, db.allocator)}
		append(&m[key], ref)
	}
	search :: proc(db: ^DB, ref: Form_ID) {
		r, _ := ref_by_formid(db, ref)
		if leveled_template(db, r.base) != 0 {
			append(&db.search_leveled, ref)
		} else {
			add(db, &db.search_by_base, r.base, ref)
		}
		if types, ok := db.ref_types[ref]; ok {
			for t in types {add(db, &db.search_by_type, t, ref)}
		}
	}
	for ref in db.persistent_refs {search(db, ref)}
	for _, ref in db.unique_refs {
		if r, _ := ref_by_formid(db, ref); !r.persistent {search(db, ref)}
	}
}

search_index_destroy :: proc(db: ^DB) {
	for _, refs in db.search_by_type {delete(refs)}
	delete(db.search_by_type)
	for _, refs in db.search_by_base {delete(refs)}
	delete(db.search_by_base)
	delete(db.search_leveled)
}

// has_ref_type: the ref is a special ref of that location ref type in some location.
// special_ref_locations are the locations that name `ref` as their special ref of `ref_type`.
special_ref_locations :: proc(db: ^DB, ref, ref_type: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for id, l in db.locations {
		for s in l.special_refs {
			if s.ref == ref && s.ref_type == ref_type {append(&out, id)}
		}
	}
	return out[:]
}

has_ref_type :: proc(db: ^DB, ref, ref_type: Form_ID) -> bool {
	types, ok := db.ref_types[ref]
	return ok && slice.contains(types[:], ref_type)
}

// location_is_child reports whether `child` sits under `ancestor` in the location tree — the
// baseline behind Location.IsChild. Walks parents to the root, with a depth cap so a malformed
// plugin's parent cycle can't hang the query. A location is not its own child.
location_is_child :: proc(db: ^DB, child, ancestor: Form_ID) -> bool {
	cur := child
	for _ in 0 ..< LOCATION_TREE_MAX_DEPTH {
		l, ok := location_of(db, cur)
		if !ok || l.parent == 0 {
			return false
		}
		if l.parent == ancestor {
			return true
		}
		cur = l.parent
	}
	return false
}

// weather_of returns a weather's decoded baseline (ok=false when the form isn't an indexed WTHR).
weather_of :: proc(db: ^DB, weather: Form_ID) -> (Weather, bool) {
	if db == nil {
		return {}, false
	}
	w, ok := db.weathers[weather]
	return w, ok
}

// weather_classification returns a weather's kind — the low four DATA flag bits, which is what
// Weather.GetClassification reports. Weather_Class.None when the form isn't indexed or the
// weather declares no class.
weather_classification :: proc(db: ^DB, weather: Form_ID) -> Weather_Class {
	w, ok := weather_of(db, weather)
	if !ok {
		return .None
	}
	switch {
	case w.info.flags & esm.WTHR_PLEASANT != 0:
		return .Pleasant
	case w.info.flags & esm.WTHR_CLOUDY != 0:
		return .Cloudy
	case w.info.flags & esm.WTHR_RAINY != 0:
		return .Rainy
	case w.info.flags & esm.WTHR_SNOW != 0:
		return .Snow
	}
	return .None
}

// weather_color returns one row of a weather's NAM0 table at one time of day (RGBA), e.g.
// weather_color(db, w, esm.WTHR_COLOR_SUNLIGHT, 1) for its noon sun colour. ok=false when the
// weather isn't indexed or authors fewer rows than `row` (the table is variable length).
weather_color :: proc(db: ^DB, weather: Form_ID, row, time: int) -> ([4]u8, bool) {
	w, ok := weather_of(db, weather)
	if !ok || row < 0 || row >= w.color_rows || time < 0 || time >= esm.WTHR_TIMES {
		return {}, false
	}
	return w.colors[row][time], true
}

// --- teardown ------------------------------------------------------------------------------

// free_faction releases a Faction's owned slices + rank titles. Shared by destroy + the override
// path.
@(private)
free_faction :: proc(db: ^DB, f: Faction) {
	delete(f.relations, db.allocator)
	free_conditions(db, f.vendor.conditions)
	for r in f.ranks {
		delete(r.male_title, db.allocator)
		delete(r.female_title, db.allocator)
	}
	delete(f.ranks, db.allocator)
}

// free_form_indexes releases everything this file's maps own. Called from destroy.
@(private)
free_form_indexes :: proc(db: ^DB) {
	for _, k in db.keywords {
		delete(k, db.allocator)
	}
	delete(db.keywords)
	for _, e in db.keyword_edid {
		delete(e, db.allocator)
	}
	delete(db.keyword_edid)
	for k, _ in db.keyword_by_edid {
		delete(k, db.allocator)
	}
	delete(db.keyword_by_edid)
	for _, l in db.linked_refs {
		delete(l, db.allocator)
	}
	delete(db.linked_refs)
	for _, f in db.factions {
		free_faction(db, f)
	}
	delete(db.factions)
	for _, s in db.spells {
		free_effects(db, s.effects)
	}
	delete(db.spells)
	for _, e in db.enchantments {
		free_effects(db, e.effects)
	}
	delete(db.enchantments)
	for _, p in db.potions {
		free_effects(db, p.effects)
	}
	delete(db.potions)
	for _, m in db.magic_effects {
		delete(m.description, db.allocator)
		free_conditions(db, m.conditions)
	}
	delete(db.magic_effects)
	for _, l in db.locations {
		delete(l.special_refs, db.allocator)
		delete(l.master_refs, db.allocator)
	}
	delete(db.locations) // names live in db.names
	delete(db.weathers)
}

// index_encounter_zone records a zone's levels, flags and the location it names.
@(private)
index_encounter_zone :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	z, has := esm.encounter_zone(fl)
	if !has {
		delete_key(&db.zones, rec.form_id)
		return
	}
	db.zones[rec.form_id] = {esm.remap_form(fm, z.location), i32(z.min_level), i32(z.max_level), z.flags}
}

// cell_never_resets reports whether a cell keeps its state forever: its zone never resets, or its
// location sits within one a Never Resets zone names.
cell_never_resets :: proc(db: ^DB, cell: Form_ID) -> bool {
	never :: proc(z: Zone) -> bool {return z.flags & esm.ECZN_NEVER_RESETS != 0}
	if z, ok := db.zones[db.cells[cell].zone]; ok && never(z) {return true}
	loc := cell_location(db, cell)
	if loc == 0 {return false}
	for _, z in db.zones {
		if never(z) && location_within(db, loc, z.location) {return true}
	}
	return false
}

// zone_of is the encounter zone a ref's levels come from: its own XEZN, else its cell's.
zone_of :: proc(db: ^DB, ref: Form_ID) -> Form_ID {
	if z, ok := db.ref_zones[ref]; ok {return z}
	r, ok := db.ref_by_id[ref]
	if !ok {return 0}
	return db.cells[grid_cell(db, r.cell_form_id, r.pos)].zone
}

// ref_respawns reports whether a cell reset resets this placement. An actor resets when its base
// is flagged Respawn; a leveled base respawns.
ref_respawns :: proc(db: ^DB, r: Ref) -> bool {
	if r.no_respawn {return false}
	a, is_npc := db.actors[r.base]
	return !is_npc || a.flags & esm.ACBS_RESPAWN != 0
}
