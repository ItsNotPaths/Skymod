package unit_tests

// NIF header spine test (ROADMAP Iteration 1, Milestone B). Hermetic + SYNTHETIC: a
// hand-built minimal Skyrim-LE NIF header (no game bytes). This is a regression
// guard on the field-order logic only — REAL correctness is proven by parsing the
// user's own NIFs (tools/nifdump against the install), since a synthetic file just
// encodes whatever layout we assume.

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/nif"

@(test)
test_nif_header :: proc(t: ^testing.T) {
	data := build_nif_header()
	defer delete(data)

	h, ok := nif.parse_header(data)
	testing.expect(t, ok, "parse header")
	defer nif.destroy_header(&h)

	testing.expect_value(t, h.version, u32(0x14020007))
	testing.expect_value(t, h.user_version, u32(12))
	testing.expect_value(t, h.bs_version, u32(83))
	testing.expect_value(t, h.num_blocks, u32(2))
	testing.expect_value(t, len(h.block_types), 2)
	testing.expect_value(t, nif.block_type(&h, 0), "NiNode")
	testing.expect_value(t, nif.block_type(&h, 1), "NiTriShape")
	testing.expect_value(t, len(h.strings), 1)
	testing.expect_value(t, h.strings[0], "Root")
}

// test_skin_partition_tris is a regression guard on the NiSkinPartition triangle
// reader's field order (Skyrim LE). It hand-builds one partition sub-block — a
// triangle list with a vertex map — and checks the partition-local indices are mapped
// back to global vertex indices, and that triangles mapping out of the geometry's
// vertex range are dropped. REAL correctness is the nifdump sweep over the install.
@(test)
test_skin_partition_tris :: proc(t: ^testing.T) {
	b := make([dynamic]u8, 0, 64)
	defer delete(b)

	nput_u32(&b, 1) // num skin partition blocks
	// --- one SkinPartition sub-block ---
	nput_u16(&b, 4) // num vertices
	nput_u16(&b, 2) // num triangles
	nput_u16(&b, 0) // num bones
	nput_u16(&b, 0) // num strips (→ triangle list, not strips)
	nput_u16(&b, 1) // num weights per vertex
	// (no bones)
	append(&b, 1) // has vertex map
	nput_u16(&b, 10);nput_u16(&b, 11);nput_u16(&b, 12);nput_u16(&b, 13) // local→global map
	append(&b, 1) // has vertex weights
	for _ in 0 ..< 4 {nput_f32(&b, 1.0)} // 4 verts × 1 weight (skipped)
	// (no strip lengths)
	append(&b, 1) // has faces
	nput_u16(&b, 0);nput_u16(&b, 1);nput_u16(&b, 2) // tri 0
	nput_u16(&b, 1);nput_u16(&b, 3);nput_u16(&b, 2) // tri 1
	append(&b, 0) // has bone indices
	nput_u16(&b, 0) // BS unknown short

	// All four mapped verts in range → both triangles survive, indices remapped.
	tris, ok := nif.parse_skin_partition_tris(b[:], 14)
	defer delete(tris)
	testing.expect(t, ok, "parse skin partition")
	testing.expect_value(t, len(tris), 6)
	testing.expect_value(t, tris[0], u16(10))
	testing.expect_value(t, tris[1], u16(11))
	testing.expect_value(t, tris[2], u16(12))
	testing.expect_value(t, tris[5], u16(12))

	// With only 13 geometry verts, the tri touching global index 13 is dropped.
	tris2, ok2 := nif.parse_skin_partition_tris(b[:], 13)
	defer delete(tris2)
	testing.expect(t, ok2, "parse skin partition (clamped)")
	testing.expect_value(t, len(tris2), 3)
}

// build_nif_header lays out a minimal valid Skyrim-LE (20.2.0.7) NIF header: two
// blocks (NiNode, NiTriShape), one header string ("Root"), empty export info, no
// block data. Caller frees.
@(private = "file")
build_nif_header :: proc(allocator := context.allocator) -> []u8 {
	b := make([dynamic]u8, 0, 256, allocator)

	append(&b, ..transmute([]u8)string("Gamebryo File Format, Version 20.2.0.7\n"))
	nput_u32(&b, 0x14020007) // version
	append(&b, 1) // endian: little
	nput_u32(&b, 12) // user version
	nput_u32(&b, 2) // num blocks
	nput_u32(&b, 83) // BS version (Skyrim LE)
	append(&b, 0, 0, 0) // export info: 3 empty short strings (length 0)

	nput_u16(&b, 2) // num block types
	nput_sized(&b, "NiNode")
	nput_sized(&b, "NiTriShape")
	nput_u16(&b, 0) // block 0 -> type 0
	nput_u16(&b, 1) // block 1 -> type 1
	nput_u32(&b, 0) // block 0 size
	nput_u32(&b, 0) // block 1 size

	nput_u32(&b, 1) // num strings
	nput_u32(&b, 4) // max string length
	nput_sized(&b, "Root")
	nput_u32(&b, 0) // num groups
	return b[:]
}

@(private = "file")
nput_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	t: [2]u8
	endian.put_u16(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
nput_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
nput_f32 :: proc(b: ^[dynamic]u8, v: f32) {
	nput_u32(b, transmute(u32)v)
}

@(private = "file")
nput_sized :: proc(b: ^[dynamic]u8, s: string) {
	nput_u32(b, u32(len(s)))
	append(b, ..transmute([]u8)s)
}
