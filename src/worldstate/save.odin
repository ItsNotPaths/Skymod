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
FORMAT_VERSION :: u32(2) // v2: FormIDs widened to u64 (global load-order space); v1 saves are dropped

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

// Save_Body is the overlay's serialised sections (§4.2). New sections become new fields here; CBOR's
// tagged encoding loads old saves into the extended struct unharmed (a save without a field decodes it
// as zero — handled in load_from_file). Player_State is already plain/CBOR-friendly, stored as-is.
Save_Body :: struct {
	deltas:       []Saved_Delta,
	created:      []Saved_Created,
	next_created: Form_ID,
	globals:      []Saved_Global,
	player:       Player_State,
}

// save_to_file writes the overlay + manifest to `path` as a `.skysave`. The manifest's delta_count
// is filled from the overlay (the caller need only set save_number/created_unix/game_cell). Returns
// false on a marshal or write failure.
save_to_file :: proc(ws: ^World_State, path: string, m: Save_Manifest) -> bool {
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
	body := Save_Body {
		deltas       = deltas,
		created      = created,
		next_created = ws.next_created,
		globals      = globals,
		player       = ws.player,
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
load_from_file :: proc(ws: ^World_State, path: string) -> (m: Save_Manifest, ok: bool) {
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

	// Commit: wipe and repopulate (upsert rebuilds ref_deltas + the by_cell index; we restore the
	// saved `live` set verbatim rather than going through the per-field verbs, since the file already
	// records which fields diverge).
	clear_overlay(ws)
	for d in body.deltas {
		e := upsert(ws, d.form_id, d.cell)
		e.live = transmute(bit_set[Ref_Field])u8(d.live)
		e.world = array_to_mat(d.world)
		e.pos = d.pos
		e.scale = d.scale
		e.disabled = d.disabled
		e.open = d.open
		e.locked = d.locked
	}
	// Created refs: restore the exact FormIDs + the allocator cursor (don't re-mint via create_ref,
	// which would hand out fresh ids). Clamp next_created to the floor for saves predating the field.
	ws.next_created = max(body.next_created, CREATED_FORM_BASE)
	for c in body.created {
		ws.created[c.form_id] = Created_Ref{base = c.base, cell = c.cell, pos = c.pos, rot = c.rot, scale = c.scale}
		list, ok := &ws.created_by_cell[c.cell]
		if !ok {
			ws.created_by_cell[c.cell] = make([dynamic]Form_ID)
			list = &ws.created_by_cell[c.cell]
		}
		append(list, c.form_id)
	}
	for g in body.globals {
		ws.globals[g.id] = g.value
	}
	ws.player = body.player
	return m, true
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
	clear(&ws.by_cell)
	clear(&ws.ref_deltas)
	clear(&ws.created_by_cell)
	clear(&ws.created)
	clear(&ws.globals)
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
