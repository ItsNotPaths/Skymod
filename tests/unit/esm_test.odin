package unit_tests

// ESM container reader tests (ROADMAP Iteration 1, Milestone C). Hermetic +
// SYNTHETIC: a hand-built minimal plugin (TES4 + a top CELL group → interior CELL →
// cell-children GRUP → REFR), no game bytes. Regression guard on the record/group/
// field structural logic — REAL correctness is proven by walking the user's own
// Skyrim.esm (tools/esmdump), where resolved refs must name real meshes.

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/esm"

@(test)
test_esm_walk_and_decode :: proc(t: ^testing.T) {
	data := build_plugin()
	defer delete(data)

	h, hok := esm.parse_header(data)
	testing.expect(t, hok, "parse TES4 header")
	defer esm.destroy_header(&h)
	testing.expect_value(t, len(h.masters), 0)
	testing.expect_value(t, h.next_object_id, u32(0x0000_0042))

	// Walk: collect each record's (sig, owning cell). The REFR must arrive tagged
	// with its parent CELL's formID (the cell-children GRUP descent).
	Seen :: struct {
		refr_cell: u32,
		saw_cell:  bool,
		saw_refr:  bool,
	}
	seen: Seen
	esm.walk(data, proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
		s := (^Seen)(user)
		switch esm.sig(rec) {
		case "CELL":
			s.saw_cell = true
		case "REFR":
			s.saw_refr = true
			s.refr_cell = ctx.cell_form_id
		}
		return true
	}, &seen)
	testing.expect(t, seen.saw_cell, "walk saw CELL")
	testing.expect(t, seen.saw_refr, "walk saw REFR")
	testing.expect_value(t, seen.refr_cell, u32(0x0000_00AA)) // the CELL's formID
}

@(test)
test_esm_refr_fields :: proc(t: ^testing.T) {
	// A REFR record body: NAME(base) + DATA(pos+rot) + XSCL(scale).
	body := make([dynamic]u8, 0, 64)
	defer delete(body)
	field(&body, "NAME", u32_bytes(0x0001_2345))
	data: [24]u8
	put_f32(data[:], 0, 10)
	put_f32(data[:], 4, 20)
	put_f32(data[:], 8, 30)
	field(&body, "DATA", data[:])
	field(&body, "XSCL", f32_bytes(2.5))

	rec := esm.Record{type = "REFR", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok, "split REFR fields")
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	p := esm.decode_refr(fl)
	testing.expect_value(t, p.base, u32(0x0001_2345))
	testing.expect_value(t, p.pos.x, f32(10))
	testing.expect_value(t, p.pos.z, f32(30))
	testing.expect_value(t, p.scale, f32(2.5))
}

@(test)
test_esm_xxxx_overflow :: proc(t: ^testing.T) {
	// XXXX(size 4)=u32(10) overrides the next field's size; that field's own u16 reads
	// 0 but it actually carries 10 bytes.
	body := make([dynamic]u8, 0, 32)
	defer delete(body)
	field(&body, "XXXX", u32_bytes(10))
	append(&body, 'O', 'B', 'N', 'D') // next field type
	append(&body, 0, 0) // its u16 size = 0 (real size comes from XXXX)
	for _ in 0 ..< 10 {append(&body, 0xAB)}

	rec := esm.Record{type = "TEST", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok, "split with XXXX")
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	testing.expect_value(t, len(fl), 1) // XXXX itself is not emitted
	testing.expect_value(t, esm.fsig(fl[0]), "OBND")
	testing.expect_value(t, len(fl[0].data), 10)
}

@(test)
test_esm_worldspace :: proc(t: ^testing.T) {
	// Exterior structure: TES4 + top WRLD GRUP → WRLD record → world-children GRUP(1)
	// → exterior CELL (with XCLC grid) → cell-children GRUP(6) → REFR. The REFR must
	// arrive tagged with BOTH its worldspace and its cell; the CELL's XCLC must decode.
	data := build_world_plugin()
	defer delete(data)

	Seen :: struct {
		saw_wrld:               bool,
		refr_world, refr_cell:  u32,
		cell_world:             u32,
		gx, gy:                 i32,
		has_grid, saw_ext_refr: bool,
	}
	seen: Seen
	esm.walk(data, proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
		s := (^Seen)(user)
		switch esm.sig(rec) {
		case "WRLD":
			s.saw_wrld = true
		case "CELL":
			s.cell_world = ctx.world_form_id
			if fl, backing, ok := esm.fields(rec); ok {
				s.gx, s.gy, s.has_grid = esm.cell_grid(fl)
				delete(fl)
				if backing != nil {delete(backing)}
			}
		case "REFR":
			s.saw_ext_refr = true
			s.refr_world = ctx.world_form_id
			s.refr_cell = ctx.cell_form_id
		}
		return true
	}, &seen)

	testing.expect(t, seen.saw_wrld, "walk saw WRLD")
	testing.expect(t, seen.saw_ext_refr, "walk saw exterior REFR")
	testing.expect_value(t, seen.cell_world, u32(0x0000_0099)) // CELL knows its WRLD
	testing.expect_value(t, seen.refr_world, u32(0x0000_0099)) // REFR knows its WRLD
	testing.expect_value(t, seen.refr_cell, u32(0x0000_00CC)) // REFR knows its CELL
	testing.expect(t, seen.has_grid, "exterior CELL has XCLC grid")
	testing.expect_value(t, seen.gx, i32(3))
	testing.expect_value(t, seen.gy, i32(-2))
}

// --- synthetic plugin builder ---

// build_world_plugin: TES4 + a top "WRLD" GRUP holding one WRLD record (formID 0x99,
// "TestWorld") followed by its world-children GRUP(1) → one exterior CELL (formID
// 0xCC, XCLC grid 3,-2) → cell-children GRUP(6) → one REFR.
@(private = "file")
build_world_plugin :: proc() -> []u8 {
	tes4_body := make([dynamic]u8, 0, 32)
	defer delete(tes4_body)
	hedr: [12]u8
	put_f32(hedr[:], 0, 1.7)
	put_u32(hedr[:], 8, 0x0000_0042)
	field(&tes4_body, "HEDR", hedr[:])

	wrld_body := make([dynamic]u8, 0, 32)
	defer delete(wrld_body)
	field(&wrld_body, "EDID", transmute([]u8)string("TestWorld\x00"))

	// Exterior CELL: non-interior DATA + XCLC grid (X=3, Y=-2, flags=0).
	cell_body := make([dynamic]u8, 0, 32)
	defer delete(cell_body)
	field(&cell_body, "DATA", []u8{0x02}) // no CELL_INTERIOR bit
	xclc: [12]u8
	put_u32(xclc[:], 0, transmute(u32)i32(3))
	put_u32(xclc[:], 4, transmute(u32)i32(-2))
	field(&cell_body, "XCLC", xclc[:])

	refr_body := make([dynamic]u8, 0, 48)
	defer delete(refr_body)
	field(&refr_body, "NAME", u32_bytes(0x0000_BEEF))
	rdata: [24]u8
	field(&refr_body, "DATA", rdata[:])

	out := make([dynamic]u8, 0, 256)
	record(&out, "TES4", 0, 0, tes4_body[:])

	// Cell-children GRUP(6), label = CELL formID, holds the REFR.
	cc_content := make([dynamic]u8, 0, 64)
	defer delete(cc_content)
	record(&cc_content, "REFR", 0, 0x0000_2222, refr_body[:])
	cc_grup := make([dynamic]u8, 0, 96)
	defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00CC), 6, cc_content[:])

	// World-children GRUP(1), label = WRLD formID, holds the CELL then its children.
	wc_content := make([dynamic]u8, 0, 128)
	defer delete(wc_content)
	record(&wc_content, "CELL", 0, 0x0000_00CC, cell_body[:])
	append(&wc_content, ..cc_grup[:])
	wc_grup := make([dynamic]u8, 0, 160)
	defer delete(wc_grup)
	group(&wc_grup, u32_bytes(0x0000_0099), 1, wc_content[:])

	// Top "WRLD" GRUP holds the WRLD record then its world-children GRUP.
	wrld_group_content := make([dynamic]u8, 0, 256)
	defer delete(wrld_group_content)
	record(&wrld_group_content, "WRLD", 0, 0x0000_0099, wrld_body[:])
	append(&wrld_group_content, ..wc_grup[:])
	group(&out, transmute([]u8)string("WRLD"), 0, wrld_group_content[:])
	return out[:]
}

// build_plugin: TES4 (HEDR, next id 0x42) + a top "CELL" GRUP holding one interior
// CELL (formID 0xAA) followed by its cell-children GRUP(6) holding one REFR.
@(private = "file")
build_plugin :: proc() -> []u8 {
	// TES4 body: HEDR (version f32, num records i32, next object id u32).
	tes4_body := make([dynamic]u8, 0, 32)
	defer delete(tes4_body)
	hedr: [12]u8
	put_f32(hedr[:], 0, 1.7)
	put_u32(hedr[:], 8, 0x0000_0042)
	field(&tes4_body, "HEDR", hedr[:])

	// CELL body: EDID + DATA (interior flag).
	cell_body := make([dynamic]u8, 0, 32)
	defer delete(cell_body)
	field(&cell_body, "EDID", transmute([]u8)string("TestCell\x00"))
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})

	// REFR body: NAME + DATA.
	refr_body := make([dynamic]u8, 0, 48)
	defer delete(refr_body)
	field(&refr_body, "NAME", u32_bytes(0x0001_2345))
	rdata: [24]u8
	field(&refr_body, "DATA", rdata[:])

	out := make([dynamic]u8, 0, 256)
	record(&out, "TES4", 0, 0, tes4_body[:])

	// Cell-children GRUP(6), label = CELL formID, holds the REFR.
	children := make([dynamic]u8, 0, 64)
	defer delete(children)
	record(&children, "REFR", 0, 0x0001_0000, refr_body[:])
	cc_grup := make([dynamic]u8, 0, 96)
	defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, children[:])

	// Top "CELL" GRUP holds the CELL record then its children GRUP.
	cell_group_content := make([dynamic]u8, 0, 128)
	defer delete(cell_group_content)
	record(&cell_group_content, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_group_content, ..cc_grup[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_group_content[:])
	return out[:]
}

@(private = "file")
record :: proc(b: ^[dynamic]u8, type: string, flags, formid: u32, data: []u8) {
	append(b, ..transmute([]u8)type)
	put_dyn_u32(b, u32(len(data)))
	put_dyn_u32(b, flags)
	put_dyn_u32(b, formid)
	put_dyn_u32(b, 0) // timestamp/vc
	put_dyn_u32(b, 0) // versions
	append(b, ..data)
}

@(private = "file")
group :: proc(b: ^[dynamic]u8, label: []u8, gtype: u32, content: []u8) {
	append(b, ..transmute([]u8)string("GRUP"))
	put_dyn_u32(b, u32(24 + len(content))) // groupSize INCLUDES the 24-byte header
	append(b, ..label)
	put_dyn_u32(b, gtype)
	put_dyn_u32(b, 0)
	put_dyn_u32(b, 0)
	append(b, ..content)
}

@(private = "file")
field :: proc(b: ^[dynamic]u8, type: string, data: []u8) {
	append(b, ..transmute([]u8)type)
	t: [2]u8
	endian.put_u16(t[:], .Little, u16(len(data)))
	append(b, ..t[:])
	append(b, ..data)
}

@(private = "file")
put_dyn_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
u32_bytes :: proc(v: u32) -> []u8 {
	b := make([]u8, 4, context.temp_allocator)
	endian.put_u32(b, .Little, v)
	return b
}

@(private = "file")
f32_bytes :: proc(v: f32) -> []u8 {
	return u32_bytes(transmute(u32)v)
}

@(private = "file")
put_u32 :: proc(b: []u8, off: int, v: u32) {
	endian.put_u32(b[off:off + 4], .Little, v)
}

@(private = "file")
put_f32 :: proc(b: []u8, off: int, v: f32) {
	endian.put_u32(b[off:off + 4], .Little, transmute(u32)v)
}
