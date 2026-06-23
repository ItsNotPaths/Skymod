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

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:strings"

REC_HEADER :: 24
FIELD_HEADER :: 6

// Record flags we act on.
FLAG_COMPRESSED :: 0x0004_0000

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
	form_id: u32,
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

// Walk_Context carries the structural position a record was found in. cell_form_id
// is the CELL whose children-GRUP we're inside (0 at top level) — so REFRs arrive
// knowing their owning cell. world_form_id is the WRLD whose children-GRUP we're
// inside (0 outside any worldspace) — so exterior CELLs arrive knowing their world.
Walk_Context :: struct {
	cell_form_id:  u32,
	world_form_id: u32,
	temporary:     bool, // inside a cell's temporary (vs persistent) children
}

// Visitor is called for every record encountered (GRUPs are descended, not
// visited). Return false to stop the walk early.
Visitor :: proc(rec: Record, ctx: Walk_Context, user: rawptr) -> bool

// walk visits every record in the file, descending GRUPs. `user` is passed through
// to `visit` untouched.
walk :: proc(data: []u8, visit: Visitor, user: rawptr) {
	walk_range(data, 0, len(data), {}, visit, user)
}

@(private)
walk_range :: proc(data: []u8, start, end: int, ctx: Walk_Context, visit: Visitor, user: rawptr) -> bool {
	pos := start
	for pos + REC_HEADER <= end {
		s := string(data[pos:pos + 4])
		size := rd32(data, pos + 4)
		if s == "GRUP" {
			gtype := i32(rd32(data, pos + 12))
			child := ctx
			switch gtype {
			case GRUP_WORLD_CHILDREN:
				child.world_form_id = rd32(data, pos + 8) // label = parent WRLD formID
			case GRUP_CELL_CHILDREN:
				child.cell_form_id = rd32(data, pos + 8) // label = parent CELL formID
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
				form_id = rd32(data, pos + 12),
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
		form_id = rd32(data, 12),
		data    = data[REC_HEADER:min(REC_HEADER + size, len(data))],
	}
	fl, backing, fok := fields(rec)
	if !fok {
		return {}, false
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

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
