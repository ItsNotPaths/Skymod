package esm

// Plugin (ESM/ESP/ESL) container reader (ROADMAP Phase 1b / Iteration 1, Milestone
// C). The TES4 record/group/subrecord format: fixed 24-byte record + GRUP headers,
// nested GRUP descent, per-record zlib compression, and the subrecord (field)
// stream with its XXXX big-field overflow. Pure parser, no engine deps — the
// in-memory record DB it feeds lives in src/gamedb.
//
// Layout (little-endian). A file is a TES4 record followed by top GRUPs. Every
// entry begins with a 4-char signature:
//   Record: sig[4] dataSize:u32 flags:u32 formID:u32 timestamp:u32 version:u32  (24)
//           then dataSize bytes of subrecords (zlib-compressed if flags&COMPRESSED).
//   GRUP:   "GRUP" groupSize:u32 label[4] groupType:i32 stamp:u32 version:u32     (24)
//           then groupSize-24 bytes of nested records/GRUPs. (groupSize INCLUDES
//           the header; a record's dataSize EXCLUDES it.)
//   Field:  sig[4] dataSize:u16 then dataSize bytes. An "XXXX" field (size 4) holds
//           the u32 real size of the FOLLOWING field (whose own size reads 0).
// Refs: UESP "Skyrim Mod:Mod File Format". Validated against the real Skyrim.esm
// (tools/esmdump): the structure walks cleanly and resolved refs name real meshes.

import "base:intrinsics"
import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:strings"

REC_HEADER :: 24
FIELD_HEADER :: 6

// Record flags we act on.
FLAG_COMPRESSED :: 0x0004_0000
// TES4 header flag: the plugin is LOCALIZED — its string-typed subrecords (FULL, DESC,
// dialogue) hold a u32 string id resolved via the plugin's external STRINGS file, not
// inline text. Read off the TES4 record; drives the FULL decode branch (see records.full_*).
FLAG_LOCALIZED :: 0x0000_0080
// TES4 header flag: SSE light master (.esl, or flagged .esp). Informational for us —
// the wide 64-bit Form_ID model gives every plugin a full 32-bit slot, so the FE-prefix
// packing this flag drives in the real engine never applies (see the Form_ID note below).
FLAG_LIGHT_MASTER :: 0x0000_0200

// GRUP group types (the label field's meaning depends on this).
GRUP_TOP :: 0 // label = record-type signature (e.g. "STAT", "CELL")
GRUP_WORLD_CHILDREN :: 1 // label = parent WRLD formID (exterior cells live below)
GRUP_CELL_CHILDREN :: 6 // label = parent CELL formID
GRUP_CELL_PERSISTENT :: 8
GRUP_CELL_TEMPORARY :: 9

// Record is one parsed record header + its raw data slice (still compressed if the
// flag is set; call fields() to get the subrecords). type/data slice into the file.
Record :: struct {
	type:    string, // 4-char signature, view into the source bytes
	flags:   u32,
	form_id: Form_ID, // global (remapped) when walked with a Form_Map; raw otherwise
	data:    []u8,
}

sig :: proc(r: Record) -> string {return r.type}

// Field is one decoded subrecord: its 4-char type and data (both slice into the
// record's — possibly decompressed — bytes; valid until that backing is freed).
Field :: struct {
	type: string,
	data: []u8,
}

fsig :: proc(f: Field) -> string {return f.type}

// Form_ID is a global form handle: (slot:u32 << 32) | local:u32, where `slot` is the
// form's owning plugin in global space and `local` is its plugin-local form number (the
// low 24 bits Skyrim uses, with room to spare). Wide on purpose — no 255-master wall, no
// ESL FExxx special-casing. `slot` is allocated stably (the form-table, manager layer);
// today slot == load-order index. See docs/mods.md.
Form_ID :: u64

// INVALID_SLOT is a reserved slot for an UNRESOLVED master reference — a plugin whose declared
// master is missing/disabled. resolve_load_order maps that master's local index here so its forms
// remap to a slot no record owns (a visibly dangling ref) instead of silently cross-wiring onto
// whatever slot happens to equal the local index — the #1 Skyrim-modding footgun. The manager
// catches this at apply (gamedb.validate_masters); INVALID_SLOT is the last-line engine guard. It
// sits just below the runtime-created slot 0xFFFFFFFF and far above any real allocation.
INVALID_SLOT :: u32(0xFFFF_FFFE)

// Form_Map remaps one plugin's local FormIDs into global Form_ID space. A source FormID's
// high byte indexes the plugin's [masters…, self] list; `slot[index]` is the corresponding
// GLOBAL slot. Built by gamedb.resolve_load_order; nil = identity (raw passthrough, for
// single-file tool walks / synthetic tests).
Form_Map :: struct {
	slot: [256]u32, // local master/self index (source form high byte) -> global slot
}

// remap_form rewrites a plugin-local FormID into a global Form_ID. fm==nil passes the raw
// value through unchanged (the tool/test single-file path).
remap_form :: proc(fm: ^Form_Map, local: u32) -> Form_ID {
	if fm == nil {
		return Form_ID(local)
	}
	return (Form_ID(fm.slot[local >> 24]) << 32) | Form_ID(local & 0x00FF_FFFF)
}

// Walk_Context carries the structural position a record was found in. cell_form_id
// is the CELL whose children-GRUP we're inside (0 at top level) — so REFRs arrive
// knowing their owning cell. world_form_id is the WRLD whose children-GRUP we're
// inside (0 outside any worldspace) — so exterior CELLs arrive knowing their world.
// These are already global (remapped). fm is the current plugin's Form_Map, so the
// visitor can remap the FormIDs it decodes out of subrecords (NAME, XTEL, BTXT…).
Walk_Context :: struct {
	cell_form_id:  Form_ID,
	world_form_id: Form_ID,
	temporary:     bool, // inside a cell's temporary (vs persistent) children
	fm:            ^Form_Map,
}

// Visitor is called for every record encountered (GRUPs are descended, not
// visited). Return false to stop the walk early.
Visitor :: proc(rec: Record, ctx: Walk_Context, user: rawptr) -> bool

// walk visits every record in the file, descending GRUPs. `user` is passed through
// to `visit` untouched. `fm` (optional) remaps every FormID — record headers and GRUP
// labels here, subrecord refs in the visitor — into global load-order space; nil =
// identity (a single no-master plugin).
// `progress` (optional) receives the running byte offset into `data` as the top-level walk advances
// — a cheap progress signal for a loading bar (the worker writes it, the UI thread reads it).
// progress_base is added to the offset so callers walking several plugins get a cumulative count.
walk :: proc(data: []u8, visit: Visitor, user: rawptr, fm: ^Form_Map = nil, progress: ^int = nil, progress_base := 0) {
	walk_range(data, 0, len(data), {fm = fm}, visit, user, progress, progress_base)
}

@(private)
walk_range :: proc(data: []u8, start, end: int, ctx: Walk_Context, visit: Visitor, user: rawptr, progress: ^int = nil, progress_base := 0) -> bool {
	pos := start
	for pos + REC_HEADER <= end {
		if progress != nil {
			intrinsics.atomic_store(progress, progress_base + pos) // top-level byte offset, for the load bar
		}
		s := string(data[pos:pos + 4])
		size := rd32(data, pos + 4)
		if s == "GRUP" {
			gtype := i32(rd32(data, pos + 12))
			child := ctx
			switch gtype {
			case GRUP_WORLD_CHILDREN:
				child.world_form_id = remap_form(ctx.fm, rd32(data, pos + 8)) // label = parent WRLD formID
			case GRUP_CELL_CHILDREN:
				child.cell_form_id = remap_form(ctx.fm, rd32(data, pos + 8)) // label = parent CELL formID
			case GRUP_CELL_PERSISTENT:
				child.temporary = false
			case GRUP_CELL_TEMPORARY:
				child.temporary = true
			}
			gend := pos + int(size)
			if gend > end || size < REC_HEADER {
				return true // malformed group size — stop this range
			}
			if !walk_range(data, pos + REC_HEADER, gend, child, visit, user) {
				return false
			}
			pos = gend
		} else {
			dend := pos + REC_HEADER + int(size)
			if dend > end {
				return true // truncated record
			}
			rec := Record {
				type    = string(data[pos:pos + 4]),
				flags   = rd32(data, pos + 8),
				form_id = remap_form(ctx.fm, rd32(data, pos + 12)),
				data    = data[pos + REC_HEADER:dend],
			}
			if !visit(rec, ctx, user) {
				return false
			}
			pos = dend
		}
	}
	return true
}

// fields decodes a record's subrecords. If the record is compressed it is inflated
// into `backing` (which the caller frees); otherwise backing is nil and the field
// data slices into the original file bytes. Returns ok=false on a bad stream.
fields :: proc(
	rec: Record,
	allocator := context.allocator,
) -> (out: []Field, backing: []u8, ok: bool) {
	buf := rec.data
	if rec.flags & FLAG_COMPRESSED != 0 {
		if len(rec.data) < 4 {
			return nil, nil, false
		}
		decomp_size := rd32(rec.data, 0)
		dec, derr := inflate(rec.data[4:], int(decomp_size), allocator)
		if !derr {
			return nil, nil, false
		}
		buf = dec
		backing = dec
	}

	list := make([dynamic]Field, 0, 16, allocator)
	pos := 0
	override := 0
	for pos + FIELD_HEADER <= len(buf) {
		ftype := string(buf[pos:pos + 4])
		fsize := int(rd16(buf, pos + 4))
		pos += FIELD_HEADER
		actual := fsize
		if override > 0 {
			actual = override
			override = 0
		}
		if pos + actual > len(buf) {
			break
		}
		if ftype == "XXXX" {
			override = int(rd32(buf, pos)) // size of the next field
			pos += actual
			continue
		}
		append(&list, Field{type = ftype, data = buf[pos:pos + actual]})
		pos += actual
	}
	return list[:], backing, true
}

// find_field returns the first field of type `tag` (a 4-char signature), or ok=false.
find_field :: proc(fields: []Field, tag: string) -> (Field, bool) {
	for f in fields {
		if f.type == tag {
			return f, true
		}
	}
	return {}, false
}

// --- TES4 header ---

// Header is the plugin's TES4 record: its masters (in order, for FormID remapping)
// and the next-object id. masters are cloned into the ambient allocator.
Header :: struct {
	masters:        []string,
	next_object_id: u32,
	localized:      bool, // TES4 flag 0x80 — string subrecords are STRINGS ids, not inline text
}

// parse_header reads the leading TES4 record. The file must begin with it.
parse_header :: proc(data: []u8, allocator := context.allocator) -> (h: Header, ok: bool) {
	context.allocator = allocator
	if len(data) < REC_HEADER || string(data[0:4]) != "TES4" {
		return {}, false
	}
	size := int(rd32(data, 4))
	rec := Record {
		type    = string(data[0:4]),
		flags   = rd32(data, 8),
		form_id = Form_ID(rd32(data, 12)),
		data    = data[REC_HEADER:min(REC_HEADER + size, len(data))],
	}
	fl, backing, fok := fields(rec)
	if !fok {
		return {}, false
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	h.localized = rec.flags & FLAG_LOCALIZED != 0
	masters := make([dynamic]string, 0, 8)
	for f in fl {
		switch f.type {
		case "MAST": // master filename, NUL-terminated; one per master, in load order
			append(&masters, strings.clone(cstr(f.data)))
		case "HEDR": // version f32, num records i32, next object id u32
			if len(f.data) >= 12 {
				h.next_object_id = rd32(f.data, 8)
			}
		}
	}
	h.masters = masters[:]
	return h, true
}

destroy_header :: proc(h: ^Header) {
	for m in h.masters {
		delete(m)
	}
	delete(h.masters)
	h^ = {}
}

// --- load order ---

// OFFICIAL_ORDER is Bethesda's hardcoded load order for the base game + DLC masters.
// It only breaks ties the master graph leaves ambiguous (Dawnguard vs HearthFires both
// become loadable after Update); anything unlisted sorts after these within its tier.
@(private)
OFFICIAL_ORDER := []string {
	"skyrim.esm",
	"update.esm",
	"dawnguard.esm",
	"hearthfires.esm",
	"dragonborn.esm",
}

// load_order returns a permutation of plugin indices in Skyrim load order: every plugin
// loads after all of its masters (a topological sort over the master graph), ties broken
// by tier (.esm/.esl masters before .esp plugins), then Bethesda's official order, then
// case-insensitive name. `masters[i]` is plugin i's master filenames (its TES4 MAST list).
// Plugins with a missing/cyclic master are emitted best-effort (by tie-break) so the load
// still makes progress. The returned slice is allocated in `allocator`; caller frees it.
load_order :: proc(names: []string, masters: [][]string, allocator := context.allocator, rank: map[string]int = nil) -> []int {
	n := len(names)
	perm := make([dynamic]int, 0, n, allocator)
	emitted := make([]bool, n, context.temp_allocator)
	idx_of := make(map[string]int, n, context.temp_allocator) // lower(name) -> plugin index
	for nm, i in names {
		idx_of[strings.to_lower(nm, context.temp_allocator)] = i
	}
	for len(perm) < n {
		best := -1
		// Prefer a READY plugin (all masters already emitted); among those, the tie-break.
		for i in 0 ..< n {
			if emitted[i] {
				continue
			}
			ready := true
			for m in masters[i] {
				if mi, ok := idx_of[strings.to_lower(m, context.temp_allocator)]; ok && !emitted[mi] {
					ready = false
					break
				}
			}
			if ready && (best < 0 || less_plugin(names[i], names[best], rank)) {
				best = i
			}
		}
		// None ready ⇒ cyclic/missing dependency: emit the best remaining anyway.
		if best < 0 {
			for i in 0 ..< n {
				if !emitted[i] && (best < 0 || less_plugin(names[i], names[best], rank)) {
					best = i
				}
			}
		}
		emitted[best] = true
		append(&perm, best)
	}
	return perm[:]
}

// less_plugin orders plugins for load-order tie-breaks: masters before plugins, then
// Bethesda's official sequence, then case-insensitive name.
@(private)
less_plugin :: proc(a, b: string, rank: map[string]int = nil) -> bool {
	if ta, tb := plugin_tier(a), plugin_tier(b); ta != tb {
		return ta < tb
	}
	if oa, ob := official_rank(a), official_rank(b); oa != ob {
		return oa < ob
	}
	// Caller-supplied order (the mod-list priority) breaks ties among non-official plugins, so the
	// derived plugin order follows the mod order. Falls back to name when a plugin is unranked.
	if rank != nil {
		ra, oka := rank[strings.to_lower(a, context.temp_allocator)]
		rb, okb := rank[strings.to_lower(b, context.temp_allocator)]
		if oka && okb && ra != rb {
			return ra < rb
		}
	}
	return strings.to_lower(a, context.temp_allocator) < strings.to_lower(b, context.temp_allocator)
}

@(private)
plugin_tier :: proc(name: string) -> int {
	if strings.has_suffix(strings.to_lower(name, context.temp_allocator), ".esp") {
		return 1 // plugins load after masters (.esm/.esl)
	}
	return 0
}

@(private)
official_rank :: proc(name: string) -> int {
	l := strings.to_lower(name, context.temp_allocator)
	for o, i in OFFICIAL_ORDER {
		if l == o {
			return i
		}
	}
	return len(OFFICIAL_ORDER)
}

// --- small readers ---

// cstr returns the string up to the first NUL (Bethesda zstrings) without the NUL.
cstr :: proc(b: []u8) -> string {
	for c, i in b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

@(private)
inflate :: proc(stream: []u8, decomp_size: int, allocator := context.allocator) -> ([]u8, bool) {
	out: bytes.Buffer
	if err := zlib.inflate(stream, &out, false, decomp_size); err != nil {
		bytes.buffer_destroy(&out)
		return nil, false
	}
	return bytes.buffer_to_bytes(&out), true
}

@(private)
rd16 :: proc(b: []u8, off: int) -> u16 {
	v, _ := endian.get_u16(b[off:off + 2], .Little)
	return v
}

@(private)
rd32 :: proc(b: []u8, off: int) -> u32 {
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return v
}
