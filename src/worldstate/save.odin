package worldstate

// `.skysave` serialization (ROADMAP Phase 3d — docs/saves.md §4.2). The save FILE is just the
// overlay (§4.1) on disk: load = deserialize → populate overlay; save = re-pack overlay. We use
// CBOR (core:encoding/cbor) — tagged/self-describing, so adding/removing/reordering fields is
// forward/backward-compatible for free (the §3.3 "single biggest upgrade" over Bethesda's
// positional bit-packing). The body's exotic types (the FormID→delta map, bit_sets, the Mat4) are
// flattened to a plain `Saved_Delta` array for a clean tagged schema; by_cell is derived, rebuilt
// on load. A readable Manifest is framed separately + CRC'd so the load menu reads it WITHOUT the
// body (§4.3 partial load). Container:
//
//   "SKYSAVE\0"            8  magic
//   u32 format_version
//   u32 manifest_len ; manifest_cbor ; u32 manifest_crc
//   u32 body_len     ; body_cbor     ; u32 body_crc
//
// zstd whole-section compression (§3.3) is deferred — Odin core ships no zstd; CBOR is stored raw
// for now (the framing is compression-ready: just wrap each section's bytes before the CRC).

// (hole save-compression :tags save :sev gap) CBOR is stored raw — Odin core ships no zstd, so a save is several times larger than it needs to be. The framing is already compression-ready.

import "core:encoding/cbor"
import "core:hash"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strings"
import "../formid"
import "../gamedb"

MAGIC :: "SKYSAVE\x00"
FORMAT_VERSION :: u32(3) // v3: stable identity slots + embedded form-table bridge (§4.4); v2 dropped


// Form_Bridge decouples the save from the mods/form-table package (which owns identity): the app
// supplies these hooks over its Form_Table so the save can (identify) name the stable slots it
// references and (resolve) map a saved identity back to THIS install's slot on load — the cross-
// install portability remap (docs/saves.md §4.4/§4.4.1). nil ⇒ no bridge (same-install identity).
Form_Bridge :: struct {
	user:     rawptr,
	identify: proc(user: rawptr, slot: u32) -> (uuid: string, filename: string, ok: bool),
	resolve:  proc(user: rawptr, uuid: string, filename: string) -> (slot: u32, ok: bool),
}

// Ref_Field (10 values) backs bit_set onto a u16; the save lowers `live` through it into a u32. If a
// 17th field ever widens the backing integer this assert fires (a loud, correct compile error).
#assert(size_of(bit_set[Ref_Field]) == 2)

// Save_Manifest is the small, body-free header the load menu reads (§4.2). Numbers only — no owned
// strings — so reading it allocates nothing and can't leak; the location NAME is resolved from
// game_cell at display time (gamedb), not stored.
Save_Manifest :: struct {
	schema_version: u32,
	save_number:    u32,
	created_unix:   i64, // wall-clock nanoseconds at save (display/sort only)
	game_cell:      Form_ID, // cell under the player: an interior or an exterior grid cell (0 = none)
	delta_count:    u32, // number of ref deltas in the body (load-menu summary)
}

// Saved_Delta is one Ref_Delta flattened to CBOR-friendly plain types (the in-RAM map value carries
// a bit_set + Mat4 that we lower to a u32 + [16]f32 here). by_cell is NOT stored — it's rebuilt from
// `cell` on load.
Saved_Delta :: struct {
	form_id:  Form_ID,
	cell:     Form_ID,
	live:     u32,     // bit_set[Ref_Field] lowered to its bits
	world:    [16]f32, // Mat4, row-major (i*4+j)
	pos:      [3]f32,
	scale:    f32,
	disabled: bool,
	open:     bool,
	locked:   bool,
	dead:     bool,
}

// Saved_Created is one Created_Ref flattened for CBOR (the runtime-spawned 0xFF refs). next_created
// is stored alongside so the allocator resumes without re-issuing live FormIDs.
Saved_Created :: struct {
	form_id: Form_ID,
	base:    Form_ID,
	cell:    Form_ID,
	pos:     [3]f32,
	rot:     [3]f32,
	scale:   f32,
	count:   i32,
}

// Saved_Update is one form's OnUpdate registrations, or its OnUpdateGameTime ones when `game`.
Saved_Update :: struct {
	form:   Form_ID,
	timers: Update_Timers,
	game:   bool,
}

Saved_Filter :: struct {
	container, filter: Form_ID,
}

Saved_Alias :: struct {
	alias, form: Form_ID,
}

Saved_List_Add :: struct {
	list, form: Form_ID,
}

Saved_Keyword_Data :: struct {
	key:   Keyword_Key,
	value: f32,
}

Saved_Cell :: struct {
	cell:  Form_ID,
	state: Cell_State,
}

Saved_Restock :: struct {
	chest: Form_ID,
	hour:  f64,
}

Saved_Quest_Event :: struct {
	quest: Form_ID,
	event: Story_Event,
}

Saved_Move :: struct {
	ref:  Form_ID,
	move: Pending_Move,
}

Saved_Anim_Reg :: struct {
	sender, form: Form_ID,
	event:        string,
}

Saved_Effect :: struct {
	handle: Form_ID,
	effect: Active_Effect,
}

Saved_Script :: struct {
	form: Form_ID,
	vars: []Script_Var,
}

// Saved_Global is one coarse world fact (id→value).
Saved_Global :: struct {
	id:    Form_ID,
	value: f32,
}

// Saved_Slot is one entry of the save's embedded form-table bridge (§4.4): the stable `slot` this
// save used, tagged with the portable identity (uuid + plugin filename) that names it. On load the
// bridge resolves each to THIS install's slot; a slot with no resolvable identity is missing (its
// deltas drop). Only slots the save's Form_IDs actually reference are emitted (created slot excluded).
Saved_Slot :: struct {
	slot:     u32,
	uuid:     string,
	filename: string,
}

// Saved_Objective / Saved_Quest flatten the quest store for CBOR: the nested done-set and objective
// map become plain arrays (done stage ids; (objective id, flag byte) pairs), the four run-state bools
// pack into one byte. Rebuilt into the map[u16]... form on load.
Saved_Objective :: struct {
	id:    u16,
	flags: u8, // Objective_State lowered to its bits
}
Saved_Quest :: struct {
	form_id:    Form_ID,
	stage:      u16,
	flags:      u8, // bit0 running, bit1 started, bit2 active, bit3 completed
	done:       []u16,
	objectives: []Saved_Objective,
}

// quest run-state bit positions in Saved_Quest.flags.
QF_RUNNING :: u8(1 << 0)
QF_STARTED :: u8(1 << 1)
QF_ACTIVE :: u8(1 << 2)
QF_COMPLETED :: u8(1 << 3)
QF_RUNNING_SET :: u8(1 << 4)

// The three Wave-1 stores flatten their nested maps to plain triples for CBOR (rebuilt into the
// map-of-maps form on load). Relationships store each directed (a→b) entry as-is (rel_set mirrors, so
// both directions are already present).
Saved_Inv :: struct {
	owner: Form_ID,
	item:  Form_ID,
	count: i32,
}
Saved_Level :: struct {
	zone:  Form_ID,
	level: i32,
}
// Saved_Equip is one worn item with the slots it fills, by name.
Saved_Equip :: struct {
	actor, item: Form_ID,
	slots:       []string,
	kept:        bool,
	outfit:      bool,
}
Saved_Level_State :: struct {
	actor: Form_ID,
	state: Level_State,
}
Saved_Range :: struct {
	zone:     Form_ID,
	min, max: i32,
}
Saved_AV :: struct {
	actor:     Form_ID,
	name:      string,
	has_base:  bool,
	has_cap:   bool,
	cap:       f32,
	base:      f32,
	permanent: f32,
	damage:    f32,
}
Saved_Faction :: struct {
	actor:   Form_ID,
	faction: Form_ID,
	rank:    i32,
}
Saved_Rel :: struct {
	a:    Form_ID,
	b:    Form_ID,
	rank: i32,
}

// Save_Body is the overlay's serialised sections (§4.2). New sections become new fields here; CBOR's
// tagged encoding loads old saves into the extended struct unharmed (a save without a field decodes it
// as zero — handled in load_from_file).
Save_Body :: struct {
	deltas:       []Saved_Delta,
	created:      []Saved_Created,
	next_created:  Form_ID,
	globals:       []Saved_Global,
	quests:        []Saved_Quest,
	inventory:     []Saved_Inv,
	spells:        []Saved_Inv,   // actor -> spell, GIVEN / REMOVED
	rolled:        []Saved_Inv,   // owner -> item, count: rolled starting contents
	zone_levels:   []Saved_Level,
	actor_picks:   []Saved_Alias, // alias = the leveled actor ref, form = its pick
	outfits:       []Saved_Alias, // alias = the actor or NPC_, form = its OTFT
	carried:       []Saved_Alias, // alias = the item ref, form = the container holding it
	zone_ranges:   []Saved_Range,
	zone_listeners: []Form_ID,
	equipment:     []Saved_Equip,
	levels:        []Saved_Level_State,
	level_listeners: []Form_ID,
	actor_values:  []Saved_AV,
	factions:      []Saved_Faction,
	relationships: []Saved_Rel,
	perks:         []Saved_Inv,   // actor -> perk, GIVEN / REMOVED
	updates:       []Saved_Update,
	item_filters:  []Saved_Filter,
	aliases:       []Saved_Alias,
	scripts:       []Saved_Script,
	list_adds:     []Saved_List_Add,
	keyword_data:  []Saved_Keyword_Data,
	cells:         []Saved_Cell,
	cleared:       []Form_ID,
	books_read:    []Form_ID,
	words:         []Saved_Inv,   // actor -> word, WORD_* bits
	beast_form:    bool,
	vampires:      []Form_ID,
	werewolves:    []Form_ID,
	restocks:      []Saved_Restock,
	quest_events:  []Saved_Quest_Event,
	story_starts:  []Saved_Restock, // chest = the quest
	story_ran:     []Saved_Alias,   // alias = the quest node, form = the quest
	alias_rounds:  []Saved_Alias,
	pending_moves: []Saved_Move,
	anim_regs:     []Saved_Anim_Reg,
	effects:       []Saved_Effect,
	next_effect:   u32,
	clock:         Game_Clock,
	form_table:    []Saved_Slot, // the identity bridge for the slots these Form_IDs reference (§4.4)
}

// save_to_file writes the overlay + manifest to `path` as a `.skysave`. The manifest's delta_count
// is filled from the overlay (the caller need only set save_number/created_unix/game_cell). Returns
// false on a marshal or write failure.
save_to_file :: proc(ws: ^World_State, path: string, m: Save_Manifest, bridge: ^Form_Bridge = nil) -> bool {
	man := m
	man.schema_version = FORMAT_VERSION
	man.delta_count = u32(len(ws.ref_deltas))

	deltas := make([]Saved_Delta, len(ws.ref_deltas), context.temp_allocator)
	i := 0
	for fid, d in ws.ref_deltas {
		deltas[i] = Saved_Delta {
			form_id  = fid,
			cell     = d.cell,
			live     = u32(transmute(u16)d.live),
			world    = mat_to_array(d.world),
			pos      = d.pos,
			scale    = d.scale,
			disabled = d.disabled,
			open     = d.open,
			locked   = d.locked,
			dead     = d.dead,
		}
		i += 1
	}

	created := make([]Saved_Created, len(ws.created), context.temp_allocator)
	j := 0
	for fid, c in ws.created {
		created[j] = Saved_Created {
			form_id = fid,
			base    = c.base,
			cell    = c.cell,
			pos     = c.pos,
			rot     = c.rot,
			scale   = c.scale,
			count   = c.count,
		}
		j += 1
	}
	globals := make([]Saved_Global, len(ws.globals), context.temp_allocator)
	k := 0
	for id, value in ws.globals {
		globals[k] = Saved_Global{id = id, value = value}
		k += 1
	}
	quests := make([]Saved_Quest, len(ws.quests), context.temp_allocator)
	qi := 0
	for fid, q in ws.quests {
		flags: u8
		if q.running {flags |= QF_RUNNING}
		if q.started {flags |= QF_STARTED}
		if q.active {flags |= QF_ACTIVE}
		if q.completed {flags |= QF_COMPLETED}
		if q.running_set {flags |= QF_RUNNING_SET}
		done := make([]u16, len(q.done), context.temp_allocator)
		di := 0
		for stage in q.done {
			done[di] = stage
			di += 1
		}
		objs := make([]Saved_Objective, len(q.objectives), context.temp_allocator)
		oi := 0
		for id, s in q.objectives {
			objs[oi] = Saved_Objective{id = id, flags = transmute(u8)s}
			oi += 1
		}
		quests[qi] = Saved_Quest{form_id = fid, stage = q.stage, flags = flags, done = done, objectives = objs}
		qi += 1
	}
	// The Wave-1 stores: flatten each map-of-maps to a triple array (size = sum of inner sizes).
	avs := make([dynamic]Saved_AV, 0, len(ws.actor_values), context.temp_allocator)
	for actor, vals in ws.actor_values {
		for av, p in vals {
			base, has_base := p.base.?
			cap, has_cap := p.cap.?
			append(&avs, Saved_AV{actor = actor, name = av, has_base = has_base, base = base, has_cap = has_cap, cap = cap, permanent = p.permanent, damage = p.damage})
		}
	}
	facs := make([dynamic]Saved_Faction, 0, len(ws.factions), context.temp_allocator)
	for actor, ranks in ws.factions {
		for faction, rank in ranks {
			append(&facs, Saved_Faction{actor = actor, faction = faction, rank = rank})
		}
	}
	rels := make([dynamic]Saved_Rel, 0, len(ws.relationships), context.temp_allocator)
	for a, others in ws.relationships {
		for b, rank in others {
			append(&rels, Saved_Rel{a = a, b = b, rank = rank})
		}
	}
	updates := make([dynamic]Saved_Update, 0, len(ws.updates) + len(ws.game_updates), context.temp_allocator)
	for form, u in ws.updates {append(&updates, Saved_Update{form, u, false})}
	for form, u in ws.game_updates {append(&updates, Saved_Update{form, u, true})}
	aliases := make([dynamic]Saved_Alias, 0, len(ws.aliases), context.temp_allocator)
	for alias, form in ws.aliases {
		append(&aliases, Saved_Alias{alias, form})
	}
	scripts := make([dynamic]Saved_Script, 0, len(ws.script_state), context.temp_allocator)
	for form, vars in ws.script_state {
		append(&scripts, Saved_Script{form, vars[:]})
	}
	filters := make([dynamic]Saved_Filter, 0, len(ws.item_filters), context.temp_allocator)
	for container, list in ws.item_filters {
		for f in list {append(&filters, Saved_Filter{container, f})}
	}
	list_adds := make([dynamic]Saved_List_Add, 0, len(ws.list_adds), context.temp_allocator)
	for list, forms in ws.list_adds {
		for f in forms {append(&list_adds, Saved_List_Add{list, f})}
	}
	keyword_data := make([dynamic]Saved_Keyword_Data, 0, len(ws.keyword_data), context.temp_allocator)
	for key, value in ws.keyword_data {append(&keyword_data, Saved_Keyword_Data{key, value})}
	cells := make([dynamic]Saved_Cell, 0, len(ws.cells), context.temp_allocator)
	for cell, s in ws.cells {append(&cells, Saved_Cell{cell, s})}
	rolled := make([dynamic]Saved_Inv, 0, len(ws.rolled), context.temp_allocator)
	for owner, list in ws.rolled {
		for e in list {append(&rolled, Saved_Inv{owner, e.item, e.count})}
	}
	zone_levels := make([dynamic]Saved_Level, 0, len(ws.zone_levels), context.temp_allocator)
	for zone, level in ws.zone_levels {append(&zone_levels, Saved_Level{zone, level})}
	picks := make([dynamic]Saved_Alias, 0, len(ws.actor_picks), context.temp_allocator)
	for ref, npc in ws.actor_picks {append(&picks, Saved_Alias{ref, npc})}
	outfits := make([dynamic]Saved_Alias, 0, len(ws.outfits), context.temp_allocator)
	for actor, outfit in ws.outfits {append(&outfits, Saved_Alias{actor, outfit})}
	carried := make([dynamic]Saved_Alias, 0, len(ws.carried), context.temp_allocator)
	for ref, holder in ws.carried {append(&carried, Saved_Alias{ref, holder})}
	ranges := make([dynamic]Saved_Range, 0, len(ws.zone_ranges), context.temp_allocator)
	for zone, r in ws.zone_ranges {append(&ranges, Saved_Range{zone, r[0], r[1]})}
	listeners := make([dynamic]Form_ID, 0, len(ws.zone_listeners), context.temp_allocator)
	for form in ws.zone_listeners {append(&listeners, form)}
	equips := make([dynamic]Saved_Equip, 0, len(ws.equipment), context.temp_allocator)
	for actor, eq in ws.equipment {
		for w in eq.worn {
			names := make([dynamic]string, context.temp_allocator)
			for s in w.slots {append(&names, reflect.enum_string(s))}
			append(&equips, Saved_Equip{actor, w.item, names[:], w.kept, w.outfit})
		}
	}
	levels := make([dynamic]Saved_Level_State, 0, len(ws.levels), context.temp_allocator)
	for actor, s in ws.levels {append(&levels, Saved_Level_State{actor, s})}
	level_listeners := make([dynamic]Form_ID, 0, len(ws.level_listeners), context.temp_allocator)
	for form in ws.level_listeners {append(&level_listeners, form)}
	restocks := make([dynamic]Saved_Restock, 0, len(ws.restocks), context.temp_allocator)
	for chest, hour in ws.restocks {append(&restocks, Saved_Restock{chest, hour})}
	quest_events := make([dynamic]Saved_Quest_Event, 0, len(ws.quest_events), context.temp_allocator)
	for quest, e in ws.quest_events {append(&quest_events, Saved_Quest_Event{quest, e})}
	story_starts := make([dynamic]Saved_Restock, 0, len(ws.story_starts), context.temp_allocator)
	for quest, hour in ws.story_starts {append(&story_starts, Saved_Restock{quest, hour})}
	story_ran := make([dynamic]Saved_Alias, 0, len(ws.story_ran), context.temp_allocator)
	for k in ws.story_ran {append(&story_ran, Saved_Alias{k[0], k[1]})}
	alias_rounds := make([dynamic]Saved_Alias, 0, len(ws.alias_rounds), context.temp_allocator)
	for k in ws.alias_rounds {append(&alias_rounds, Saved_Alias{k[0], k[1]})}
	moves := make([dynamic]Saved_Move, 0, len(ws.pending_moves), context.temp_allocator)
	for ref, move in ws.pending_moves {append(&moves, Saved_Move{ref, move})}
	effects := make([dynamic]Saved_Effect, 0, len(ws.effects), context.temp_allocator)
	for h, e in ws.effects {append(&effects, Saved_Effect{h, e})}
	anim_regs := make([dynamic]Saved_Anim_Reg, context.temp_allocator)
	for sender, list in ws.anim_regs {
		for r in list {append(&anim_regs, Saved_Anim_Reg{sender, r.form, r.event})}
	}
	body := Save_Body {
		deltas       = deltas,
		created      = created,
		next_created  = ws.next_created,
		globals       = globals,
		quests        = quests,
		inventory     = save_deltas(ws.inventories),
		spells        = save_deltas(ws.spells),
		rolled        = rolled[:],
		zone_levels   = zone_levels[:],
		actor_picks   = picks[:],
		outfits       = outfits[:],
		carried       = carried[:],
		zone_ranges   = ranges[:],
		zone_listeners = listeners[:],
		equipment     = equips[:],
		levels        = levels[:],
		level_listeners = level_listeners[:],
		actor_values  = avs[:],
		factions      = facs[:],
		relationships = rels[:],
		perks         = save_deltas(ws.perks),
		updates       = updates[:],
		item_filters  = filters[:],
		aliases       = aliases[:],
		scripts       = scripts[:],
		list_adds     = list_adds[:],
		keyword_data  = keyword_data[:],
		cells         = cells[:],
		cleared       = save_set(ws.cleared),
		books_read    = save_set(ws.books_read),
		words         = save_deltas(ws.words),
		beast_form    = ws.beast_form,
		vampires      = save_set(ws.vampires),
		werewolves    = save_set(ws.werewolves),
		restocks      = restocks[:],
		quest_events  = quest_events[:],
		story_starts  = story_starts[:],
		story_ran     = story_ran[:],
		alias_rounds  = alias_rounds[:],
		pending_moves = moves[:],
		anim_regs     = anim_regs[:],
		effects       = effects[:],
		next_effect   = ws.next_effect,
		clock         = ws.clock,
	}
	// Embed the identity bridge for every stable slot these Form_IDs reference, so the save can be
	// remapped on load (reorder / cross-install). No bridge ⇒ same-install identity (empty table).
	if bridge != nil {
		body.form_table = build_bridge(&body, bridge)
	}

	man_bytes, merr := cbor.marshal(man, allocator = context.temp_allocator)
	if merr != nil {return false}
	body_bytes, berr := cbor.marshal(body, allocator = context.temp_allocator)
	if berr != nil {return false}

	buf := make([dynamic]u8, 0, len(man_bytes) + len(body_bytes) + 64, context.temp_allocator)
	append(&buf, MAGIC) // append_elem_string: writes the 8 magic bytes
	put_u32(&buf, FORMAT_VERSION)
	put_section(&buf, man_bytes)
	put_section(&buf, body_bytes)
	return os.write_entire_file(path, buf[:]) == nil
}

// read_manifest reads ONLY the header + manifest section of a `.skysave` (load menu / partial load
// §4.3) — it never touches the body. ok=false on a missing/short/corrupt (bad magic or CRC) file.
read_manifest :: proc(path: string, allocator := context.allocator) -> (m: Save_Manifest, ok: bool) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {return {}, false}
	r := Reader{data = data}
	if !check_header(&r) {return {}, false}
	man_bytes, mok := get_section(&r)
	if !mok {return {}, false}
	if cbor.unmarshal(man_bytes, &m, allocator = allocator) != nil {return {}, false}
	return m, true
}

// load_from_file replaces the overlay's contents with a `.skysave`'s body (and returns its
// manifest). The existing overlay is cleared first — load is "become this save", not a merge.
// ok=false on a missing/corrupt file (the overlay is left untouched in that case).
load_from_file :: proc(ws: ^World_State, path: string, bridge: ^Form_Bridge = nil) -> (m: Save_Manifest, ok: bool) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {return {}, false}
	r := Reader{data = data}
	if !check_header(&r) {return {}, false}
	man_bytes, mok := get_section(&r)
	if !mok {return {}, false}
	body_bytes, bok := get_section(&r)
	if !bok {return {}, false}
	if cbor.unmarshal(man_bytes, &m, allocator = context.temp_allocator) != nil {return {}, false}
	body: Save_Body
	if cbor.unmarshal(body_bytes, &body, allocator = context.temp_allocator) != nil {return {}, false}

	// Identity remap (§4.4.1): resolve the save's embedded form-table against THIS install's slots, so
	// a Form_ID stamped under an old/other-install slot lands on the right form here. A saved slot with
	// no resolvable identity (mod missing from the profile) is absent from `remap` → its keyed entries
	// drop. No bridge / no embedded table ⇒ same-install identity (remap disabled, values verbatim).
	remap := make(map[u32]u32, len(body.form_table), context.temp_allocator)
	have_remap := bridge != nil && len(body.form_table) > 0
	if have_remap {
		for ss in body.form_table {
			if ns, rok := bridge.resolve(bridge.user, ss.uuid, ss.filename); rok {
				remap[ss.slot] = ns
			}
		}
	}
	// rf remaps one Form_ID's slot half (an alias handle's quest slot). ok=false ⇒ the owning mod is
	// missing (caller drops the entry). When remap is disabled every id passes through as-is. The
	// created slot always passes through.
	rf := proc(remap: map[u32]u32, on: bool, fid: Form_ID) -> (Form_ID, bool) {
		if !on || fid == 0 || u32(fid >> 32) == formid.CREATED_SLOT || formid.is_effect(fid) {return fid, true}
		quest, id, is_alias := formid.alias_key(fid)
		src := quest if is_alias else fid
		ns, rok := remap[u32(src >> 32)]
		if !rok {return fid, false}
		out := (Form_ID(ns) << 32) | (src & 0x0000_0000_FFFF_FFFF)
		if is_alias {return formid.alias_handle(out, id)}
		return out, true
	}

	// Commit: wipe and repopulate (upsert rebuilds ref_deltas + the by_cell index; we restore the
	// saved `live` set verbatim rather than going through the per-field verbs, since the file already
	// records which fields diverge).
	destroy_overlay(&ws.overlay)
	init_overlay(&ws.overlay)
	for d in body.deltas {
		fid, kok := rf(remap, have_remap, d.form_id)
		if !kok {continue} // keyed on a missing mod → drop
		cell, _ := rf(remap, have_remap, d.cell)
		e := upsert(ws, fid, cell)
		e.live = transmute(bit_set[Ref_Field])u16(d.live)
		e.world = array_to_mat(d.world)
		e.pos = d.pos
		e.scale = d.scale
		e.disabled = d.disabled
		e.open = d.open
		e.locked = d.locked
		e.dead = d.dead
	}
	// Created refs: restore the exact FormIDs + the allocator cursor (don't re-mint via create_ref,
	// which would hand out fresh ids). Clamp next_created to the floor for saves predating the field.
	// form_id is a created-slot id (passes through); base/cell reference records → remapped.
	ws.next_created = max(body.next_created, formid.CREATED_FORM_BASE)
	for c in body.created {
		base, _ := rf(remap, have_remap, c.base)
		cell, _ := rf(remap, have_remap, c.cell)
		ws.created[c.form_id] = Created_Ref{base = base, cell = cell, pos = c.pos, rot = c.rot, scale = c.scale, count = c.count}
		list, lok := &ws.created_by_cell[cell]
		if !lok {
			ws.created_by_cell[cell] = make([dynamic]Form_ID)
			list = &ws.created_by_cell[cell]
		}
		append(list, c.form_id)
	}
	for u in body.updates {
		timers := &ws.game_updates if u.game else &ws.updates
		if id, kok := rf(remap, have_remap, u.form); kok {timers[id] = u.timers}
	}
	for f in body.item_filters {
		container, cok := rf(remap, have_remap, f.container)
		filter, fok := rf(remap, have_remap, f.filter)
		if cok && fok {add_item_filter(ws, container, filter)}
	}
	for a in body.list_adds {
		list, lok := rf(remap, have_remap, a.list)
		form, fok := rf(remap, have_remap, a.form)
		if lok && fok {add_to_list(ws, list, form)}
	}
	for c in body.cells {
		if id, ok := rf(remap, have_remap, c.cell); ok {ws.cells[id] = c.state}
	}
	load_set(&ws.cleared, body.cleared, remap, have_remap, rf)
	load_set(&ws.books_read, body.books_read, remap, have_remap, rf)
	load_deltas(&ws.words, body.words, remap, have_remap, rf)
	ws.beast_form = body.beast_form
	load_set(&ws.vampires, body.vampires, remap, have_remap, rf)
	load_set(&ws.werewolves, body.werewolves, remap, have_remap, rf)
	for r in body.restocks {
		if id, ok := rf(remap, have_remap, r.chest); ok {ws.restocks[id] = r.hour}
	}
	// An event keeps its quest; a member from a missing mod reads as none.
	for q in body.quest_events {
		quest, ok := rf(remap, have_remap, q.quest)
		if !ok {continue}
		e := q.event
		for &f in ([]^Form_ID{&e.keyword, &e.location1, &e.location2, &e.ref1, &e.ref2, &e.object, &e.form, &e.quest}) {
			f^, _ = rf(remap, have_remap, f^)
		}
		ws.quest_events[quest] = e
	}
	for r in body.story_starts {
		if id, ok := rf(remap, have_remap, r.chest); ok {ws.story_starts[id] = r.hour}
	}
	for r in body.story_ran {
		node, nok := rf(remap, have_remap, r.alias)
		quest, qok := rf(remap, have_remap, r.form)
		if nok && qok {ws.story_ran[{node, quest}] = true}
	}
	for r in body.alias_rounds {
		alias, aok := rf(remap, have_remap, r.alias)
		form, fok := rf(remap, have_remap, r.form)
		if aok && fok {ws.alias_rounds[{alias, form}] = true}
	}
	// A rolled item from a missing mod drops; the owner keeps the rest.
	for r in body.rolled {
		owner, ook := rf(remap, have_remap, r.owner)
		item, iok := rf(remap, have_remap, r.item)
		if !ook {continue}
		if owner not_in ws.rolled {ws.rolled[owner] = make([dynamic]gamedb.Content_Entry)}
		if iok {append(&ws.rolled[owner], gamedb.Content_Entry{item, r.count})}
	}
	for z in body.zone_levels {
		if id, ok := rf(remap, have_remap, z.zone); ok {ws.zone_levels[id] = z.level}
	}
	for r in body.zone_ranges {
		if id, ok := rf(remap, have_remap, r.zone); ok {ws.zone_ranges[id] = {r.min, r.max}}
	}
	for f in body.zone_listeners {
		if id, ok := rf(remap, have_remap, f); ok {ws.zone_listeners[id] = true}
	}
	for l in body.levels {
		if id, ok := rf(remap, have_remap, l.actor); ok {ws.levels[id] = l.state}
	}
	for f in body.level_listeners {
		if id, ok := rf(remap, have_remap, f); ok {ws.level_listeners[id] = true}
	}
	// An actor's rows rebuild its equipment exactly; an item from a missing mod and a slot name the
	// engine no longer has drop.
	for e in body.equipment {
		actor, aok := rf(remap, have_remap, e.actor)
		item, iok := rf(remap, have_remap, e.item)
		if !aok {continue}
		if actor not_in ws.equipment {ws.equipment[actor] = {}}
		slots: gamedb.Slots
		for name in e.slots {
			if s, ok := reflect.enum_from_name(gamedb.Slot, name); ok {slots += {s}}
		}
		if eq := &ws.equipment[actor]; iok && slots != {} {append(&eq.worn, Worn{item, slots, e.kept, e.outfit})}
	}
	for p in body.actor_picks {
		ref, rok := rf(remap, have_remap, p.alias)
		npc, nok := rf(remap, have_remap, p.form)
		if rok && (nok || p.form == 0) {ws.actor_picks[ref] = npc}
	}
	for o in body.outfits {
		actor, aok := rf(remap, have_remap, o.alias)
		outfit, ook := rf(remap, have_remap, o.form)
		if aok && ook {ws.outfits[actor] = outfit}
	}
	for r in body.carried {
		ref, rok := rf(remap, have_remap, r.alias)
		holder, hok := rf(remap, have_remap, r.form)
		if rok && hok {ws.carried[ref] = holder}
	}
	for k in body.keyword_data {
		location, lok := rf(remap, have_remap, k.key.location)
		keyword, kok := rf(remap, have_remap, k.key.keyword)
		if lok && kok {ws.keyword_data[{location, keyword}] = k.value}
	}
	for m in body.pending_moves {
		ref, rok := rf(remap, have_remap, m.ref)
		target, tok := rf(remap, have_remap, m.move.target)
		if rok && tok {ws.pending_moves[ref] = {target, m.move.offset}}
	}
	ws.next_effect = body.next_effect
	for s in body.effects {
		e := s.effect
		ok := true
		for f in ([4]^Form_ID{&e.effect, &e.spell, &e.target, &e.caster}) {
			id, fok := rf(remap, have_remap, f^)
			f^ = id
			ok &&= fok
		}
		if ok {
			ws.effects[s.handle] = e
			index_effect(ws, s.handle, e.target)
		}
	}
	for a in body.anim_regs {
		sender, sok := rf(remap, have_remap, a.sender)
		form, fok := rf(remap, have_remap, a.form)
		if sok && fok {register_anim_event(ws, sender, form, a.event)}
	}
	for a in body.aliases {
		alias, aok := rf(remap, have_remap, a.alias)
		form, fok := rf(remap, have_remap, a.form)
		if aok && fok {fill_alias(ws, alias, form)}
	}
	for sc in body.scripts {
		form, fok := rf(remap, have_remap, sc.form)
		if !fok {continue}
		reset_script_state(ws, form)
		for v in sc.vars {
			value, vok := clone_value(v.value, remap, have_remap, rf)
			if !vok {continue}
			add_script_var(ws, form, {strings.clone(v.script), strings.clone(v.name), value})
		}
	}
	for g in body.globals {
		if id, kok := rf(remap, have_remap, g.id); kok {ws.globals[id] = g.value}
	}
	for sq in body.quests {
		fid, kok := rf(remap, have_remap, sq.form_id)
		if !kok {continue}
		q := quest_upsert(ws, fid)
		q.stage = sq.stage
		q.running = sq.flags & QF_RUNNING != 0
		q.started = sq.flags & QF_STARTED != 0
		q.active = sq.flags & QF_ACTIVE != 0
		q.completed = sq.flags & QF_COMPLETED != 0
		q.running_set = sq.flags & QF_RUNNING_SET != 0
		for stage in sq.done {
			q.done[stage] = true
		}
		for o in sq.objectives {
			q.objectives[o.id] = transmute(Objective_State)o.flags
		}
	}
	// The three Wave-1 stores: rebuild each map-of-maps from its flat triples (verbatim — the file
	// already records full state). Actor values come back by name (a mod AV's values wait in
	// pending_avs until OnGameLoaded creates it); relationship pairs are stored both directions, so
	// each directed entry is set on its own. Entries keyed on a missing mod drop; a secondary ref
	// (item/faction/b) that won't resolve keeps its saved value (dangles).
	load_deltas(&ws.inventories, body.inventory, remap, have_remap, rf)
	load_deltas(&ws.spells, body.spells, remap, have_remap, rf)
	for a in body.actor_values {
		actor, kok := rf(remap, have_remap, a.actor)
		if !kok {continue}
		av, aok := gamedb.actor_value_name(a.name)
		if !aok {
			mod := a
			mod.actor, mod.name = actor, strings.clone(a.name)
			append(&ws.pending_avs, mod)
			continue
		}
		av_bind(ws, actor, av, a)
	}
	for f in body.factions {
		actor, kok := rf(remap, have_remap, f.actor)
		if !kok {continue}
		faction, _ := rf(remap, have_remap, f.faction)
		faction_upsert(ws, actor)^[faction] = f.rank
	}
	load_deltas(&ws.perks, body.perks, remap, have_remap, rf)
	for r in body.relationships {
		a, kok := rf(remap, have_remap, r.a)
		if !kok {continue}
		b, _ := rf(remap, have_remap, r.b)
		rel_upsert(ws, a)^[b] = r.rank
	}
	ws.clock = body.clock
	return m, true
}

// build_bridge collects every stable slot the body's Form_IDs reference (excluding 0 and the created
// slot) and tags each with its portable identity via the bridge — the save's embedded remap table.
@(private = "file")
build_bridge :: proc(body: ^Save_Body, bridge: ^Form_Bridge) -> []Saved_Slot {
	seen := make(map[u32]bool, 32, context.temp_allocator)
	for d in body.deltas {add_slot(&seen, d.form_id);add_slot(&seen, d.cell)}
	for c in body.created {add_slot(&seen, c.base);add_slot(&seen, c.cell)} // form_id is the created slot
	for g in body.globals {add_slot(&seen, g.id)}
	for q in body.quests {add_slot(&seen, q.form_id)}
	for r in body.inventory {add_slot(&seen, r.owner);add_slot(&seen, r.item)}
	for r in body.spells {add_slot(&seen, r.owner);add_slot(&seen, r.item)}
	for a in body.actor_values {add_slot(&seen, a.actor)}
	for f in body.factions {add_slot(&seen, f.actor);add_slot(&seen, f.faction)}
	for r in body.relationships {add_slot(&seen, r.a);add_slot(&seen, r.b)}
	for r in body.perks {add_slot(&seen, r.owner);add_slot(&seen, r.item)}
	for u in body.updates {add_slot(&seen, u.form)}
	for f in body.item_filters {add_slot(&seen, f.container);add_slot(&seen, f.filter)}
	for a in body.aliases {add_slot(&seen, a.alias);add_slot(&seen, a.form)}
	for a in body.list_adds {add_slot(&seen, a.list);add_slot(&seen, a.form)}
	for k in body.keyword_data {add_slot(&seen, k.key.location);add_slot(&seen, k.key.keyword)}
	for c in body.cells {add_slot(&seen, c.cell)}
	for l in body.cleared {add_slot(&seen, l)}
	for b in body.books_read {add_slot(&seen, b)}
	for w in body.words {add_slot(&seen, w.owner);add_slot(&seen, w.item)}
	for v in body.vampires {add_slot(&seen, v)}
	for w in body.werewolves {add_slot(&seen, w)}
	for r in body.restocks {add_slot(&seen, r.chest)}
	for q in body.quest_events {
		add_slot(&seen, q.quest)
		e := q.event
		for f in ([]Form_ID{e.keyword, e.location1, e.location2, e.ref1, e.ref2, e.object, e.form, e.quest}) {add_slot(&seen, f)}
	}
	for r in body.story_starts {add_slot(&seen, r.chest)}
	for r in body.story_ran {add_slot(&seen, r.alias);add_slot(&seen, r.form)}
	for r in body.alias_rounds {add_slot(&seen, r.alias);add_slot(&seen, r.form)}
	for r in body.rolled {add_slot(&seen, r.owner);add_slot(&seen, r.item)}
	for z in body.zone_levels {add_slot(&seen, z.zone)}
	for p in body.actor_picks {add_slot(&seen, p.alias);add_slot(&seen, p.form)}
	for o in body.outfits {add_slot(&seen, o.alias);add_slot(&seen, o.form)}
	for r in body.carried {add_slot(&seen, r.alias);add_slot(&seen, r.form)}
	for r in body.zone_ranges {add_slot(&seen, r.zone)}
	for f in body.zone_listeners {add_slot(&seen, f)}
	for e in body.equipment {add_slot(&seen, e.actor);add_slot(&seen, e.item)}
	for l in body.levels {add_slot(&seen, l.actor)}
	for f in body.level_listeners {add_slot(&seen, f)}
	for m in body.pending_moves {add_slot(&seen, m.ref);add_slot(&seen, m.move.target)}
	for a in body.anim_regs {add_slot(&seen, a.sender);add_slot(&seen, a.form)}
	for s in body.effects {add_slot(&seen, s.effect.effect);add_slot(&seen, s.effect.spell);add_slot(&seen, s.effect.target);add_slot(&seen, s.effect.caster)}
	for sc in body.scripts {
		add_slot(&seen, sc.form)
		for v in sc.vars {add_value_slots(&seen, v.value)}
	}

	out := make([dynamic]Saved_Slot, 0, len(seen), context.temp_allocator)
	for s in seen {
		if uuid, fname, ok := bridge.identify(bridge.user, s); ok {
			append(&out, Saved_Slot{slot = s, uuid = uuid, filename = fname})
		}
	}
	return out[:]
}

// clone_value copies a loaded member value into the store, remapping its refs. ok=false when a ref's
// mod is missing: the member then rebuilds at its start value.
@(private = "file")
clone_value :: proc(v: Script_Value, remap: map[u32]u32, on: bool, rf: proc(map[u32]u32, bool, Form_ID) -> (Form_ID, bool)) -> (Script_Value, bool) {
	#partial switch x in v {
	case string:
		return strings.clone(x), true
	case Form_ID:
		return rf(remap, on, x)
	case []Script_Value:
		out := make([]Script_Value, len(x))
		for e, i in x {
			ok: bool
			out[i], ok = clone_value(e, remap, on, rf)
			if !ok {
				free_script_value(out)
				return nil, false
			}
		}
		return out, true
	}
	return v, true
}

@(private = "file")
add_value_slots :: proc(seen: ^map[u32]bool, v: Script_Value) {
	#partial switch x in v {
	case Form_ID:
		add_slot(seen, x)
	case []Script_Value:
		for e in x {add_value_slots(seen, e)}
	}
}

@(private = "file")
add_slot :: proc(seen: ^map[u32]bool, fid: Form_ID) {
	if fid == 0 {return}
	quest, _, is_alias := formid.alias_key(fid)
	s := u32((quest if is_alias else fid) >> 32)
	if s == formid.CREATED_SLOT || s == formid.EFFECT_SLOT {return}
	seen[s] = true
}

// --- container framing helpers ---

@(private = "file")
Reader :: struct {
	data: []u8,
	pos:  int,
}

@(private = "file")
check_header :: proc(r: ^Reader) -> bool {
	if len(r.data) < len(MAGIC) + 4 {return false}
	if string(r.data[:len(MAGIC)]) != MAGIC {return false}
	r.pos = len(MAGIC)
	ver := read_u32(r)
	return ver == FORMAT_VERSION
}

// put_section appends a section as [u32 len][bytes][u32 crc32(bytes)].
@(private = "file")
put_section :: proc(buf: ^[dynamic]u8, bytes: []u8) {
	put_u32(buf, u32(len(bytes)))
	append(buf, ..bytes)
	put_u32(buf, hash.crc32(bytes))
}

// get_section reads a length-prefixed, CRC-guarded section; ok=false on truncation or CRC mismatch.
@(private = "file")
get_section :: proc(r: ^Reader) -> (bytes: []u8, ok: bool) {
	if r.pos + 4 > len(r.data) {return nil, false}
	n := int(read_u32(r))
	if r.pos + n + 4 > len(r.data) || n < 0 {return nil, false}
	bytes = r.data[r.pos:r.pos + n]
	r.pos += n
	crc := read_u32(r)
	if hash.crc32(bytes) != crc {return nil, false}
	return bytes, true
}

@(private = "file")
put_u32 :: proc(buf: ^[dynamic]u8, v: u32) {
	append(buf, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private = "file")
read_u32 :: proc(r: ^Reader) -> u32 {
	if r.pos + 4 > len(r.data) {return 0}
	v := u32(r.data[r.pos]) | u32(r.data[r.pos + 1]) << 8 | u32(r.data[r.pos + 2]) << 16 | u32(r.data[r.pos + 3]) << 24
	r.pos += 4
	return v
}

@(private = "file")
mat_to_array :: proc(m: matrix[4, 4]f32) -> [16]f32 {
	out: [16]f32
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {
			out[i * 4 + j] = m[i, j]
		}
	}
	return out
}

@(private = "file")
array_to_mat :: proc(a: [16]f32) -> matrix[4, 4]f32 {
	m: matrix[4, 4]f32
	for i in 0 ..< 4 {
		for j in 0 ..< 4 {
			m[i, j] = a[i * 4 + j]
		}
	}
	return m
}
