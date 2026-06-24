package unit_tests

// ESM container reader tests (ROADMAP Iteration 1, Milestone C). Hermetic +
// SYNTHETIC: a hand-built minimal plugin (TES4 + a top CELL group → interior CELL →
// cell-children GRUP → REFR), no game bytes. Regression guard on the record/group/
// field structural logic — REAL correctness is proven by walking the user's own
// Skyrim.esm (tools/esmdump), where resolved refs must name real meshes.

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"

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
// Synthetic IMGS: HNAM (HDR, 9 floats) + CNAM (cinematic, 3) + TNAM (tint, 4), the real
// Skyrim subrecord split (validated against Skyrim.esm via esmdump --imgs). Guards the
// HNAM white/sun/sky + CNAM saturation/brightness/contrast + TNAM amount/color offsets.
test_esm_imagespace :: proc(t: ^testing.T) {
	hnam := make([dynamic]u8, 0, 36);defer delete(hnam)
	for v in ([?]f32{45, 7, 0.7, 3.25, 0.7, 0.95, 2.3, 0.315, 5}) {append(&hnam, ..f32_bytes(v))}
	cnam := make([dynamic]u8, 0, 12);defer delete(cnam)
	for v in ([?]f32{1.375, 1.1, 1.275}) {append(&cnam, ..f32_bytes(v))}
	tnam := make([dynamic]u8, 0, 16);defer delete(tnam)
	for v in ([?]f32{0.65, 0.81, 0.69, 0.64}) {append(&tnam, ..f32_bytes(v))}

	body := make([dynamic]u8, 0, 80);defer delete(body)
	field(&body, "EDID", []u8{'I', 'S', 0})
	field(&body, "HNAM", hnam[:])
	field(&body, "CNAM", cnam[:])
	field(&body, "TNAM", tnam[:])

	rec := esm.Record{type = "IMGS", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok)
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	im, dok := esm.decode_imagespace(fl)
	testing.expect(t, dok, "decode HNAM/CNAM/TNAM")
	testing.expect_value(t, im.hdr_white, f32(0.95))
	testing.expect_value(t, im.sunlight_scale, f32(2.3))
	testing.expect_value(t, im.sky_scale, f32(0.315))
	testing.expect_value(t, im.saturation, f32(1.375))
	testing.expect_value(t, im.brightness, f32(1.1))
	testing.expect_value(t, im.contrast, f32(1.275))
	testing.expect_value(t, im.tint_amount, f32(0.65))
	testing.expect_value(t, im.tint_color.y, f32(0.69))
}

@(test)
test_esm_land_heights :: proc(t: ^testing.T) {
	// VHGT = base offset f32 + 33×33 signed-byte gradients + 3 pad. Heights accumulate:
	// the first column of each row is a delta from the previous row's first column, and
	// every other cell is a delta from the previous cell in its row.
	G :: esm.LAND_GRID
	vhgt := make([]u8, 4 + G * G + 3)
	defer delete(vhgt)
	put_f32(vhgt, 0, 100) // base offset
	vhgt[4 + 0] = transmute(u8)i8(5) // (0,0): 100 + 5 = 105
	vhgt[4 + 1] = transmute(u8)i8(2) // (1,0): 105 + 2 = 107
	vhgt[4 + 2] = transmute(u8)i8(-4) // (2,0): 107 - 4 = 103
	vhgt[4 + G] = transmute(u8)i8(10) // (0,1): col0 105 + 10 = 115

	body := make([dynamic]u8, 0, 1200)
	defer delete(body)
	field(&body, "VHGT", vhgt)
	rec := esm.Record{type = "LAND", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok, "split LAND fields")
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	h, hok := esm.land_heights(fl, context.allocator)
	testing.expect(t, hok, "decode VHGT")
	defer delete(h)
	testing.expect_value(t, len(h), G * G)
	testing.expect_value(t, h[0], f32(105))
	testing.expect_value(t, h[1], f32(107))
	testing.expect_value(t, h[2], f32(103))
	testing.expect_value(t, h[G], f32(115)) // first cell of row 1
}

@(test)
test_esm_land_textures :: proc(t: ^testing.T) {
	// LAND BTXT base-texture-per-quadrant (8 bytes: LTEX formID + quadrant + pad + layer).
	body := make([dynamic]u8, 0, 64)
	defer delete(body)
	b0: [8]u8
	put_u32(b0[:], 0, 0x0000_0111) // quadrant 0 (SW) → LTEX 0x111
	field(&body, "BTXT", b0[:])
	b2: [8]u8
	put_u32(b2[:], 0, 0x0000_0222)
	b2[4] = 2 // quadrant 2 (NW) → LTEX 0x222
	field(&body, "BTXT", b2[:])

	rec := esm.Record{type = "LAND", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok, "split LAND fields")
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	bt := esm.land_base_textures(fl)
	testing.expect_value(t, bt[0], u32(0x0000_0111))
	testing.expect_value(t, bt[2], u32(0x0000_0222))
	testing.expect_value(t, bt[1], u32(0)) // no BTXT for quadrant 1

	// LTEX TNAM → TXST formID.
	lbody := make([dynamic]u8, 0, 16)
	defer delete(lbody)
	field(&lbody, "TNAM", u32_bytes(0x0000_0333))
	lrec := esm.Record{type = "LTEX", data = lbody[:]}
	lfl, lb, lok := esm.fields(lrec)
	testing.expect(t, lok, "split LTEX fields")
	defer delete(lfl)
	defer if lb != nil {delete(lb)}
	txst, has := esm.landscape_txst(lfl)
	testing.expect(t, has, "LTEX has TNAM")
	testing.expect_value(t, txst, u32(0x0000_0333))

	// TXST TX00 → diffuse path (NUL-terminated zstring).
	tbody := make([dynamic]u8, 0, 32)
	defer delete(tbody)
	field(&tbody, "TX00", transmute([]u8)string("Landscape\\Dirt02.dds\x00"))
	trec := esm.Record{type = "TXST", data = tbody[:]}
	tfl, tb, tok := esm.fields(trec)
	testing.expect(t, tok, "split TXST fields")
	defer delete(tfl)
	defer if tb != nil {delete(tb)}
	testing.expect_value(t, esm.texture_set_diffuse(tfl), "Landscape\\Dirt02.dds")
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

@(test)
test_gamedb_grid_index :: proc(t: ^testing.T) {
	// gamedb should index the synthetic worldspace: find it by name, list its cell,
	// resolve that cell by grid coordinate (the streamer's lookup), and keep the
	// exterior REFR under it.
	data := build_world_plugin()
	defer delete(data)

	db := gamedb.build(data)
	defer gamedb.destroy(&db)

	wfid, wok := gamedb.find_world(&db, "testworld") // case-insensitive
	testing.expect(t, wok, "find_world TestWorld")
	testing.expect_value(t, wfid, u32(0x0000_0099))

	cells := gamedb.cells_of(&db, wfid)
	testing.expect_value(t, len(cells), 1)

	cid, cok := gamedb.cell_at(&db, wfid, 3, -2) // the CELL's XCLC grid
	testing.expect(t, cok, "cell_at (3,-2)")
	testing.expect_value(t, cid, u32(0x0000_00CC))

	miss, mok := gamedb.cell_at(&db, wfid, 99, 99) // a hole
	_ = miss
	testing.expect(t, !mok, "cell_at hole misses")

	testing.expect_value(t, len(gamedb.refs_of(&db, cid)), 1) // exterior REFR kept
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
