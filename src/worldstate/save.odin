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

import "core:encoding/cbor"
import "core:hash"
import "core:os"

MAGIC :: "SKYSAVE\x00"
FORMAT_VERSION :: u32(3) // v3: stable identity slots + embedded form-table bridge (§4.4); v2 dropped

// CREATED_SLOT is the reserved high word of runtime-created forms (CREATED_FORM_BASE >> 32). Identical
// across installs, so its forms are never in the form-table bridge and pass remap through untouched.
CREATED_SLOT :: u32(0xFFFF_FFFF)

// Form_Bridge decouples the save from the mods/form-table package (which owns identity): the app
// supplies these hooks over its Form_Table so the save can (identify) name the stable slots it
// references and (resolve) map a saved identity back to THIS install's slot on load — the cross-
// install portability remap (docs/saves.md §4.4/§4.4.1). nil ⇒ no bridge (same-install identity).
Form_Bridge :: struct {
	user:     rawptr,
	identify: proc(user: rawptr, slot: u32) -> (uuid: string, filename: string, ok: bool),
	resolve:  proc(user: rawptr, uuid: string, filename: string) -> (slot: u32, ok: bool),
}

// Ref_Field (8 values) backs bit_set onto a single byte; the save lowers `live` through u8. If a
// 9th field ever widens the backing integer this assert fires (a loud, correct compile error).
#assert(size_of(bit_set[Ref_Field]) == 1)

// Save_Manifest is the small, body-free header the load menu reads (§4.2). Numbers only — no owned
// strings — so reading it allocates nothing and can't leak; the location NAME is resolved from
// game_cell at display time (gamedb), not stored.
Save_Manifest :: struct {
	schema_version: u32,
	save_number:    u32,
	created_unix:   i64, // wall-clock nanoseconds at save (display/sort only)
	game_cell:      Form_ID, // cell the player was in (0 = exterior/none)
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
Saved_AV :: struct {
	actor: Form_ID,
	name:  string, // AV name (lowercased in the store)
	value: f32,
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
// as zero — handled in load_from_file). Player_State is already plain/CBOR-friendly, stored as-is.
Save_Body :: struct {
	deltas:       []Saved_Delta,
	created:      []Saved_Created,
	next_created:  Form_ID,
	globals:       []Saved_Global,
	quests:        []Saved_Quest,
	inventory:     []Saved_Inv,
	actor_values:  []Saved_AV,
	factions:      []Saved_Faction,
	relationships: []Saved_Rel,
	player:        Player_State,
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
			live     = u32(transmute(u8)d.live),
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
	// The three Wave-1 stores: flatten each map-of-maps to a triple array (size = sum of inner sizes).
	inv := make([dynamic]Saved_Inv, 0, len(ws.inventories), context.temp_allocator)
	for owner, items in ws.inventories {
		for item, count in items {
			append(&inv, Saved_Inv{owner = owner, item = item, count = count})
		}
	}
	avs := make([dynamic]Saved_AV, 0, len(ws.actor_values), context.temp_allocator)
	for actor, vals in ws.actor_values {
		for name, value in vals {
			append(&avs, Saved_AV{actor = actor, name = name, value = value})
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
	body := Save_Body {
		deltas       = deltas,
		created      = created,
		next_created  = ws.next_created,
		globals       = globals,
		quests        = quests,
		inventory     = inv[:],
		actor_values  = avs[:],
		factions      = facs[:],
		relationships = rels[:],
		player        = ws.player,
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
	// rf remaps one Form_ID's slot half. ok=false ⇒ the owning mod is missing (caller drops the entry).
	// When remap is disabled every id passes through as-is. The created slot always passes through.
	rf := proc(remap: map[u32]u32, on: bool, fid: Form_ID) -> (Form_ID, bool) {
		if !on || fid == 0 || u32(fid >> 32) == CREATED_SLOT {return fid, true}
		if ns, rok := remap[u32(fid >> 32)]; rok {return (Form_ID(ns) << 32) | (fid & 0x0000_0000_FFFF_FFFF), true}
		return fid, false
	}

	// Commit: wipe and repopulate (upsert rebuilds ref_deltas + the by_cell index; we restore the
	// saved `live` set verbatim rather than going through the per-field verbs, since the file already
	// records which fields diverge).
	clear_overlay(ws)
	for d in body.deltas {
		fid, kok := rf(remap, have_remap, d.form_id)
		if !kok {continue} // keyed on a missing mod → drop
		cell, _ := rf(remap, have_remap, d.cell)
		e := upsert(ws, fid, cell)
		e.live = transmute(bit_set[Ref_Field])u8(d.live)
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
	ws.next_created = max(body.next_created, CREATED_FORM_BASE)
	for c in body.created {
		base, _ := rf(remap, have_remap, c.base)
		cell, _ := rf(remap, have_remap, c.cell)
		ws.created[c.form_id] = Created_Ref{base = base, cell = cell, pos = c.pos, rot = c.rot, scale = c.scale}
		list, lok := &ws.created_by_cell[cell]
		if !lok {
			ws.created_by_cell[cell] = make([dynamic]Form_ID)
			list = &ws.created_by_cell[cell]
		}
		append(list, c.form_id)
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
	// already records full state). av_set owns/lowercases the key; relationship pairs are stored both
	// directions, so each directed entry is set on its own. Entries keyed on a missing mod drop; a
	// secondary ref (item/faction/b) that won't resolve keeps its saved value (dangles).
	for r in body.inventory {
		owner, kok := rf(remap, have_remap, r.owner)
		if !kok {continue}
		item, _ := rf(remap, have_remap, r.item)
		inv_upsert(ws, owner)^[item] = r.count
	}
	for a in body.actor_values {
		if actor, kok := rf(remap, have_remap, a.actor); kok {av_set(ws, actor, a.name, a.value)}
	}
	for f in body.factions {
		actor, kok := rf(remap, have_remap, f.actor)
		if !kok {continue}
		faction, _ := rf(remap, have_remap, f.faction)
		faction_upsert(ws, actor)^[faction] = f.rank
	}
	for r in body.relationships {
		a, kok := rf(remap, have_remap, r.a)
		if !kok {continue}
		b, _ := rf(remap, have_remap, r.b)
		rel_upsert(ws, a)^[b] = r.rank
	}
	ws.player = body.player
	ws.player.cell, _ = rf(remap, have_remap, body.player.cell)
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
	for a in body.actor_values {add_slot(&seen, a.actor)}
	for f in body.factions {add_slot(&seen, f.actor);add_slot(&seen, f.faction)}
	for r in body.relationships {add_slot(&seen, r.a);add_slot(&seen, r.b)}
	add_slot(&seen, body.player.cell)

	out := make([dynamic]Saved_Slot, 0, len(seen), context.temp_allocator)
	for s in seen {
		if uuid, fname, ok := bridge.identify(bridge.user, s); ok {
			append(&out, Saved_Slot{slot = s, uuid = uuid, filename = fname})
		}
	}
	return out[:]
}

@(private = "file")
add_slot :: proc(seen: ^map[u32]bool, fid: Form_ID) {
	if fid == 0 {return}
	s := u32(fid >> 32)
	if s == CREATED_SLOT {return}
	seen[s] = true
}

// --- container framing helpers ---

@(private = "file")
clear_overlay :: proc(ws: ^World_State) {
	for _, &list in ws.by_cell {
		delete(list)
	}
	for _, &list in ws.created_by_cell {
		delete(list)
	}
	free_stores(ws) // quests' nested maps + the three stores' inner maps + AV key strings
	clear(&ws.by_cell)
	clear(&ws.ref_deltas)
	clear(&ws.created_by_cell)
	clear(&ws.created)
	clear(&ws.globals)
	clear(&ws.quests)
	clear(&ws.inventories)
	clear(&ws.actor_values)
	clear(&ws.factions)
	clear(&ws.relationships)
	ws.next_created = CREATED_FORM_BASE
	ws.player = {}
}

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
