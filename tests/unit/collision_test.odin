package unit_tests

// NIF bhk* collision parser regression guard (ROADMAP §2e / physics). Hermetic +
// SYNTHETIC: hand-builds a complete minimal Skyrim-LE NIF whose root node carries a
// collision chain NiNode → bhkCollisionObject → bhkRigidBodyT → bhkBoxShape, then
// checks parse_collision recovers the box with the right half-extents (×HAVOK_SCALE)
// and the rigid-body-T translation applied at the spec offset. REAL correctness is
// the `nifdump --collision` sweep over the install (synthetic only proves the field
// order we assume is read back consistently).

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/nif"

@(test)
test_collision_box :: proc(t: ^testing.T) {
	data := build_collision_nif()
	defer delete(data)

	h, hok := nif.parse_header(data)
	testing.expect(t, hok, "parse header")
	defer nif.destroy_header(&h)
	testing.expect_value(t, h.num_blocks, u32(4))

	col := nif.parse_collision(data, &h)
	defer nif.destroy_collision(&col)

	testing.expect_value(t, len(col.shapes), 1)
	testing.expect_value(t, col.unhandled, 0)
	if len(col.shapes) != 1 {return}
	s := col.shapes[0]
	testing.expect_value(t, s.kind, nif.Collision_Kind.Box)

	// Box dimensions (1,2,3) Havok units → half-extents × HAVOK_SCALE.
	hs := nif.HAVOK_SCALE
	expect_near(t, s.half_extents.x, 1 * hs, "box half x")
	expect_near(t, s.half_extents.y, 2 * hs, "box half y")
	expect_near(t, s.half_extents.z, 3 * hs, "box half z")

	// bhkRigidBodyT translation (10,0,0) Havok units → × HAVOK_SCALE in the placement.
	expect_near(t, s.transform[0, 3], 10 * hs, "body translation x")
	expect_near(t, s.transform[1, 3], 0, "body translation y")
	expect_near(t, s.transform[2, 3], 0, "body translation z")
	// Identity rotation → orthonormal upper-left (diagonal ~1).
	expect_near(t, s.transform[0, 0], 1, "rotation m00")
	expect_near(t, s.transform[1, 1], 1, "rotation m11")
}

@(private = "file")
expect_near :: proc(t: ^testing.T, got, want: f32, msg: string) {
	d := got - want
	if d < 0 {d = -d}
	testing.expectf(t, d < 0.01, "%s: got %f want %f", msg, got, want)
}

// build_collision_nif assembles a complete NIF: header → 4 blocks (NiNode w/ a
// collision ref, bhkCollisionObject, bhkRigidBodyT, bhkBoxShape) → footer (root = 0).
@(private = "file")
build_collision_nif :: proc(allocator := context.allocator) -> []u8 {
	// --- block 0: NiNode "Root", collision ref = block 1, no children ---
	n0 := make([dynamic]u8, 0, 128);defer delete(n0)
	cput_i32(&n0, 0) // Name → strings[0] "Root"
	cput_u32(&n0, 0) // num extra data
	cput_i32(&n0, -1) // controller
	cput_u32(&n0, 0) // flags
	cput_f32(&n0, 0);cput_f32(&n0, 0);cput_f32(&n0, 0) // translation
	for v in ([9]f32{1, 0, 0, 0, 1, 0, 0, 0, 1}) {cput_f32(&n0, v)} // rotation (identity)
	cput_f32(&n0, 1) // scale
	cput_i32(&n0, 1) // collision object → block 1
	cput_u32(&n0, 0) // num children

	// --- block 1: bhkCollisionObject → body = block 2 ---
	n1 := make([dynamic]u8, 0, 16);defer delete(n1)
	cput_i32(&n1, 0) // Target (back-ptr)
	cput_u16(&n1, 1) // Flags (bhkCOFlags)
	cput_i32(&n1, 2) // Body → block 2

	// --- block 2: bhkRigidBodyT: shape @0, translation @52, rotation @68 ---
	n2 := make([dynamic]u8, 0, 96);defer delete(n2)
	cput_i32(&n2, 3) // Shape → block 3 (bhkWorldObject.Shape, first field)
	for _ in 0 ..< 48 {append(&n2, 0)} // bytes 4..51 (filter/world/entity cinfo, unused here)
	cput_f32(&n2, 10);cput_f32(&n2, 0);cput_f32(&n2, 0);cput_f32(&n2, 0) // translation @52 (vec4)
	cput_f32(&n2, 0);cput_f32(&n2, 0);cput_f32(&n2, 0);cput_f32(&n2, 1) // rotation @68 (quat xyzw)

	// --- block 3: bhkBoxShape: material@0, radius@4, padding@8, dimensions@16, unused@28 ---
	n3 := make([dynamic]u8, 0, 48);defer delete(n3)
	cput_u32(&n3, 0) // material
	cput_f32(&n3, 0.05) // radius
	for _ in 0 ..< 8 {append(&n3, 0)} // padding
	cput_f32(&n3, 1);cput_f32(&n3, 2);cput_f32(&n3, 3) // dimensions @16
	cput_f32(&n3, 0) // unused float

	// --- header ---
	b := make([dynamic]u8, 0, 512, allocator)
	append(&b, ..transmute([]u8)string("Gamebryo File Format, Version 20.2.0.7\n"))
	cput_u32(&b, 0x14020007) // version
	append(&b, 1) // little-endian
	cput_u32(&b, 12) // user version
	cput_u32(&b, 4) // num blocks
	cput_u32(&b, 83) // BS version
	append(&b, 0, 0, 0) // export info: 3 empty short strings

	cput_u16(&b, 4) // num block types
	cput_sized(&b, "NiNode")
	cput_sized(&b, "bhkCollisionObject")
	cput_sized(&b, "bhkRigidBodyT")
	cput_sized(&b, "bhkBoxShape")
	cput_u16(&b, 0);cput_u16(&b, 1);cput_u16(&b, 2);cput_u16(&b, 3) // per-block type index
	cput_u32(&b, u32(len(n0)));cput_u32(&b, u32(len(n1)));cput_u32(&b, u32(len(n2)));cput_u32(&b, u32(len(n3))) // sizes

	cput_u32(&b, 1) // num strings
	cput_u32(&b, 4) // max string length
	cput_sized(&b, "Root")
	cput_u32(&b, 0) // num groups

	// --- block data, in order ---
	append(&b, ..n0[:])
	append(&b, ..n1[:])
	append(&b, ..n2[:])
	append(&b, ..n3[:])

	// --- footer: 1 root, block 0 ---
	cput_u32(&b, 1)
	cput_i32(&b, 0)
	return b[:]
}

@(private = "file")
cput_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	t: [2]u8
	endian.put_u16(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
cput_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
cput_i32 :: proc(b: ^[dynamic]u8, v: i32) {cput_u32(b, transmute(u32)v)}

@(private = "file")
cput_f32 :: proc(b: ^[dynamic]u8, v: f32) {cput_u32(b, transmute(u32)v)}

@(private = "file")
cput_sized :: proc(b: ^[dynamic]u8, s: string) {
	cput_u32(b, u32(len(s)))
	append(b, ..transmute([]u8)s)
}
