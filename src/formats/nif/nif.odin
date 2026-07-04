package nif

// NIF (Gamebryo/NetImmerse) parser (ROADMAP Iteration 1, Milestone B). Target:
// Skyrim Legendary Edition — NIF version 20.2.0.7, user version 12, BS version 83.
// Pure parser, no engine deps.
//
// This file is the SPINE: the header (version, the block-type table, the block
// size table, and the header string table) and block enumeration. Per-block field
// decoding (NiNode transforms, NiTriShape(Data) geometry, BSLightingShaderProperty
// + BSShaderTextureSet) builds on top of this. Synthetic tests only prove
// self-consistency here; real validation is parsing the user's own NIFs (see
// tools/nifdump) and, ultimately, the mesh rendering correctly.
//
// Layout (little-endian): header string line → version/endian/user/num-blocks →
// BS stream (bs version + export info) → block-type table → per-block type index →
// per-block size → header string table → groups → block data → footer.

import "core:encoding/endian"
import "core:strings"

VERSION_LE :: 0x14020007 // 20.2.0.7 — same NIF version in LE and SSE
BS_VERSION_LE :: 83      // Skyrim Legendary Edition
BS_VERSION_SE :: 100     // Skyrim Special Edition — BSTriShape packed geometry

Header :: struct {
	version:          u32,
	endian_little:    bool,
	user_version:     u32,
	bs_version:       u32,
	num_blocks:       u32,
	block_types:      []string, // distinct type names (heap)
	block_type_index: []u16,    // per block -> index into block_types (heap)
	block_sizes:      []u32,    // per block, bytes of block data (heap)
	strings:          []string, // header string table (heap)
	blocks_offset:    int,      // byte offset where block data begins
	block_offsets:    []int,    // per block, absolute byte offset of its data (heap)
}

// block_data returns the raw bytes of block i within the full file `data`.
block_data :: proc(h: ^Header, data: []u8, i: int) -> []u8 {
	if i < 0 || i >= len(h.block_offsets) {
		return nil
	}
	off := h.block_offsets[i]
	end := off + int(h.block_sizes[i])
	if off < 0 || end > len(data) {
		return nil
	}
	return data[off:end]
}

// block_type returns the type name of block i, or "" if out of range.
block_type :: proc(h: ^Header, i: int) -> string {
	if i < 0 || i >= len(h.block_type_index) {
		return ""
	}
	ti := int(h.block_type_index[i])
	if ti < 0 || ti >= len(h.block_types) {
		return ""
	}
	return h.block_types[ti]
}

// parse_header reads the NIF header off `data` (the full decompressed file). On
// success, blocks_offset marks where block data starts. Returns ok=false (with
// allocations freed) on anything malformed or non-LE-Skyrim.
parse_header :: proc(data: []u8, allocator := context.allocator) -> (h: Header, ok: bool) {
	context.allocator = allocator
	r := Reader{data = data, ok = true}

	line := read_header_line(&r)
	if !strings.has_prefix(line, "Gamebryo File Format") {
		return {}, false
	}
	h.version = read_u32(&r)
	h.endian_little = read_u8(&r) == 1
	h.user_version = read_u32(&r)
	h.num_blocks = read_u32(&r)
	h.bs_version = read_u32(&r)
	// Export info: author / process script / export script (short strings, skipped).
	skip_short_string(&r)
	skip_short_string(&r)
	skip_short_string(&r)

	if h.version != VERSION_LE {
		return {}, false // 20.2.0.7 covers both LE (BS 83) and SSE (BS 100)
	}

	num_types := int(read_u16(&r))
	h.block_types = make([]string, num_types)
	for i in 0 ..< num_types {
		h.block_types[i] = read_sized_string(&r)
	}
	h.block_type_index = make([]u16, int(h.num_blocks))
	for i in 0 ..< int(h.num_blocks) {
		h.block_type_index[i] = read_u16(&r)
	}
	h.block_sizes = make([]u32, int(h.num_blocks))
	for i in 0 ..< int(h.num_blocks) {
		h.block_sizes[i] = read_u32(&r)
	}

	num_strings := int(read_u32(&r))
	_ = read_u32(&r) // max string length (unused)
	h.strings = make([]string, num_strings)
	for i in 0 ..< num_strings {
		h.strings[i] = read_sized_string(&r)
	}

	num_groups := int(read_u32(&r))
	for _ in 0 ..< num_groups {
		_ = read_u32(&r)
	}

	if !r.ok {
		destroy_header(&h)
		return {}, false
	}
	h.blocks_offset = r.pos

	// Precompute each block's absolute data offset (blocks are laid out contiguously
	// in order, sized by block_sizes).
	h.block_offsets = make([]int, int(h.num_blocks))
	off := r.pos
	for i in 0 ..< int(h.num_blocks) {
		h.block_offsets[i] = off
		off += int(h.block_sizes[i])
	}
	return h, true
}

destroy_header :: proc(h: ^Header) {
	for s in h.block_types {
		delete(s)
	}
	delete(h.block_types)
	delete(h.block_type_index)
	delete(h.block_sizes)
	for s in h.strings {
		delete(s)
	}
	delete(h.strings)
	delete(h.block_offsets)
	h^ = {}
}

// --- byte reader ---

Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

@(private)
have :: proc(r: ^Reader, n: int) -> bool {
	if !r.ok || r.pos + n > len(r.data) {
		r.ok = false
		return false
	}
	return true
}

@(private)
read_u8 :: proc(r: ^Reader) -> u8 {
	if !have(r, 1) {return 0}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

@(private)
read_u16 :: proc(r: ^Reader) -> u16 {
	if !have(r, 2) {return 0}
	v, _ := endian.get_u16(r.data[r.pos:r.pos + 2], .Little)
	r.pos += 2
	return v
}

@(private)
read_u32 :: proc(r: ^Reader) -> u32 {
	if !have(r, 4) {return 0}
	v, _ := endian.get_u32(r.data[r.pos:r.pos + 4], .Little)
	r.pos += 4
	return v
}

@(private)
read_i32 :: proc(r: ^Reader) -> i32 {
	return i32(read_u32(r))
}

@(private)
read_u64 :: proc(r: ^Reader) -> u64 {
	if !have(r, 8) {return 0}
	v, _ := endian.get_u64(r.data[r.pos:r.pos + 8], .Little)
	r.pos += 8
	return v
}

// read_f16 reads an IEEE half float and widens it — SSE packed vertex data
// (positions, UVs) is half-precision.
@(private)
read_f16 :: proc(r: ^Reader) -> f32 {
	return f32(transmute(f16)read_u16(r))
}

@(private)
read_f32 :: proc(r: ^Reader) -> f32 {
	return transmute(f32)read_u32(r)
}

@(private)
read_vec2 :: proc(r: ^Reader) -> [2]f32 {
	x := read_f32(r)
	y := read_f32(r)
	return {x, y}
}

@(private)
read_vec3 :: proc(r: ^Reader) -> [3]f32 {
	x := read_f32(r)
	y := read_f32(r)
	z := read_f32(r)
	return {x, y, z}
}

// read_mat3 reads a 3x3 rotation matrix stored row-major (m00 m01 m02 m10 ...).
@(private)
read_mat3 :: proc(r: ^Reader) -> matrix[3, 3]f32 {
	m: matrix[3, 3]f32
	for row in 0 ..< 3 {
		for col in 0 ..< 3 {
			m[row, col] = read_f32(r)
		}
	}
	return m
}

// read_header_line reads bytes up to and including the terminating '\n'; returns
// the line without the newline.
@(private)
read_header_line :: proc(r: ^Reader) -> string {
	start := r.pos
	for r.pos < len(r.data) && r.data[r.pos] != '\n' {
		r.pos += 1
	}
	line := string(r.data[start:r.pos])
	if r.pos < len(r.data) {
		r.pos += 1 // consume '\n'
	}
	return line
}

// read_sized_string reads a u32-length-prefixed string (no null terminator),
// cloned into the ambient allocator.
@(private)
read_sized_string :: proc(r: ^Reader) -> string {
	n := int(read_u32(r))
	if !have(r, n) {return ""}
	s := strings.clone(string(r.data[r.pos:r.pos + n]))
	r.pos += n
	return s
}

// skip_short_string skips a u8-length-prefixed string (length includes the null
// terminator). Used for header export info we don't keep.
@(private)
skip_short_string :: proc(r: ^Reader) {
	n := int(read_u8(r))
	if have(r, n) {
		r.pos += n
	}
}
