package unit_tests

// ESM container reader tests (ROADMAP Iteration 1, Milestone C). Hermetic +
// SYNTHETIC: a hand-built minimal plugin (TES4 + a top CELL group → interior CELL →
// cell-children GRUP → REFR), no game bytes. Regression guard on the record/group/
// field structural logic — REAL correctness is proven by walking the user's own
// Skyrim.esm (tools/esmdump), where resolved refs must name real meshes.

import "core:strings"
import "core:encoding/endian"
import "core:testing"
import "../../src/formats/esm"
import "../../src/formid"
import "../../src/gamedb"
import "../../src/mods"

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
		refr_cell: esm.Form_ID,
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
	testing.expect_value(t, seen.refr_cell, esm.Form_ID(0x0000_00AA)) // the CELL's formID
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
test_esm_xloc :: proc(t: ^testing.T) {
	// A REFR with an XLOC lock (20 bytes: level u8 @0, key formID @4). decode_xloc reads level + key;
	// a REFR without XLOC decodes ok=false (Skyrim omits XLOC on unlocked refs = not locked).
	body := make([dynamic]u8, 0, 64);defer delete(body)
	field(&body, "NAME", u32_bytes(0x0001_2345))
	xloc: [20]u8
	xloc[0] = 0x32 // lock level = 50 (Adept)
	put_u32(xloc[:], 4, 0x0000_0A0B) // key formID
	field(&body, "XLOC", xloc[:])

	rec := esm.Record{type = "REFR", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok, "split REFR fields")
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	lk, lok := esm.decode_xloc(fl)
	testing.expect(t, lok, "decode XLOC")
	testing.expect_value(t, lk.level, u8(0x32))
	testing.expect_value(t, lk.key, esm.Form_ID(0x0000_0A0B))

	// An unlocked REFR (no XLOC) → ok=false.
	body2 := make([dynamic]u8, 0, 16);defer delete(body2)
	field(&body2, "NAME", u32_bytes(0x0001_2345))
	rec2 := esm.Record{type = "REFR", data = body2[:]}
	fl2, backing2, ok2 := esm.fields(rec2)
	testing.expect(t, ok2)
	defer delete(fl2)
	defer if backing2 != nil {delete(backing2)}
	_, lok2 := esm.decode_xloc(fl2)
	testing.expect(t, !lok2, "no XLOC ⇒ not locked")
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
		refr_world, refr_cell:  esm.Form_ID,
		cell_world:             esm.Form_ID,
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
	testing.expect_value(t, seen.cell_world, esm.Form_ID(0x0000_0099)) // CELL knows its WRLD
	testing.expect_value(t, seen.refr_world, esm.Form_ID(0x0000_0099)) // REFR knows its WRLD
	testing.expect_value(t, seen.refr_cell, esm.Form_ID(0x0000_00CC)) // REFR knows its CELL
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
	testing.expect_value(t, wfid, gamedb.Form_ID(0x0000_0099))

	cells := gamedb.cells_of(&db, wfid)
	testing.expect_value(t, len(cells), 1)

	cid, cok := gamedb.cell_at(&db, wfid, 3, -2) // the CELL's XCLC grid
	testing.expect(t, cok, "cell_at (3,-2)")
	testing.expect_value(t, cid, gamedb.Form_ID(0x0000_00CC))

	miss, mok := gamedb.cell_at(&db, wfid, 99, 99) // a hole
	_ = miss
	testing.expect(t, !mok, "cell_at hole misses")

	testing.expect_value(t, len(gamedb.refs_of(&db, cid)), 1) // exterior REFR kept
}

@(test)
test_esm_load_order :: proc(t: ^testing.T) {
	// Scrambled input → Skyrim load order: a topo sort over the master graph (every plugin
	// after all its masters), ties broken by Bethesda's official sequence. Reproduces the
	// canonical Skyrim/Update/Dawnguard/HearthFires/Dragonborn order from any input order.
	names := []string{"Dragonborn.esm", "HearthFires.esm", "Skyrim.esm", "Dawnguard.esm", "Update.esm"}
	masters := [][]string {
		{"Skyrim.esm", "Update.esm"}, // Dragonborn
		{"Skyrim.esm"}, // HearthFires
		{}, // Skyrim
		{"Skyrim.esm", "Update.esm"}, // Dawnguard
		{"Skyrim.esm"}, // Update
	}
	perm := esm.load_order(names, masters, context.allocator)
	defer delete(perm)
	want := []string{"Skyrim.esm", "Update.esm", "Dawnguard.esm", "HearthFires.esm", "Dragonborn.esm"}
	testing.expect_value(t, len(perm), len(want))
	for w, i in want {
		testing.expect_value(t, names[perm[i]], w)
	}
}

@(test)
test_esm_load_order_rank :: proc(t: ^testing.T) {
	// Among non-official plugins, the caller's rank (the mod-list priority) breaks ties — so the
	// derived plugin order follows the mod order instead of falling back to alphabetical.
	names := []string{"Alpha.esp", "Bravo.esp"}
	masters := [][]string{{}, {}}
	rank := make(map[string]int, 2, context.temp_allocator)
	rank["bravo.esp"] = 0 // mod list puts Bravo above Alpha (reverse of alphabetical)
	rank["alpha.esp"] = 1
	perm := esm.load_order(names, masters, context.allocator, rank)
	defer delete(perm)
	testing.expect_value(t, names[perm[0]], "Bravo.esp")
	testing.expect_value(t, names[perm[1]], "Alpha.esp")
}

@(test)
test_form_map_remap :: proc(t: ^testing.T) {
	// A Form_Map for a plugin at global index 4 whose masters are Skyrim(0) and Update(1):
	// master refs pass through, self refs (local high byte 2 == len(masters)) jump to 4.
	fm: esm.Form_Map
	for b in 0 ..< 256 {fm.slot[b] = u32(b)}
	fm.slot[0] = 0x00 // master 0 → global slot 0
	fm.slot[1] = 0x01 // master 1 → global slot 1
	fm.slot[2] = 0x04 // self    → global slot 4
	// remap packs (slot<<32) | (local & 0x00FFFFFF).
	testing.expect_value(t, esm.remap_form(&fm, 0x0000_ABCD), esm.Form_ID(0x0000_0000_0000_ABCD))
	testing.expect_value(t, esm.remap_form(&fm, 0x0100_1234), esm.Form_ID(0x0000_0001_0000_1234))
	testing.expect_value(t, esm.remap_form(&fm, 0x0200_5678), esm.Form_ID(0x0000_0004_0000_5678)) // self → slot 4
	testing.expect_value(t, esm.remap_form(nil, 0x0200_5678), esm.Form_ID(0x0000_0000_0200_5678)) // nil = raw passthrough
}

@(test)
test_gamedb_multimaster :: proc(t: ^testing.T) {
	// Two-plugin load: a master defines STAT 0x300 + cell 0xAA; an addon (master = the first)
	// OVERRIDES that STAT's mesh, ADDS its own STAT (local self id) and a REFR into the master's
	// cell pointing at it. Proves FormID remap into global space + last-wins override + the
	// cell gaining the addon's ref.
	a := build_master_plugin();defer delete(a)
	b := build_addon_plugin();defer delete(b)

	inputs := []gamedb.Plugin_Input{{name = "Skyrim.esm", data = a}, {name = "Update.esm", data = b}}
	order := gamedb.resolve_load_order(inputs, context.allocator)
	defer delete(order, context.allocator)
	testing.expect_value(t, len(order), 2)
	testing.expect_value(t, order[0].name, "Skyrim.esm")
	testing.expect_value(t, order[1].name, "Update.esm")

	db := gamedb.build_plugins(order)
	defer gamedb.destroy(&db)

	// Master STAT overridden by the addon (last wins).
	m1, ok1 := gamedb.model_of(&db, 0x0000_0300)
	testing.expect(t, ok1, "master STAT present")
	testing.expect_value(t, m1, "rock_fixed.nif")

	// The addon's own STAT lives at its GLOBAL formID: slot 1 (its load index) << 32 | local 0x000400.
	m2, ok2 := gamedb.model_of(&db, 0x0000_0001_0000_0400)
	testing.expect(t, ok2, "addon STAT present at global id")
	testing.expect_value(t, m2, "addon.nif")

	// The master's cell now holds BOTH its own REFR and the addon's added REFR.
	refs := gamedb.refs_of(&db, 0x0000_00AA)
	testing.expect_value(t, len(refs), 2)

	// The addon REFR is indexed at its global id (slot 1, local 0x010001) and its NAME remapped
	// to the addon base (slot 1, local 0x000400).
	r, rok := gamedb.ref_by_formid(&db, 0x0000_0001_0001_0001)
	testing.expect(t, rok, "addon REFR indexed at global id")
	testing.expect_value(t, r.base, gamedb.Form_ID(0x0000_0001_0000_0400))
}

@(test)
test_gamedb_stable_slots :: proc(t: ^testing.T) {
	// The form-table's slot_of stamps a plugin's IDENTITY slot, not its load-order index. Same setup
	// as test_gamedb_multimaster, but Update.esm is interned to stable slot 0x10 — so its own STAT
	// lands at 0x10<<32|0x400 (NOT load index 1<<32), while Skyrim.esm (pinned 0) keeps its forms at
	// slot 0 (the hardcoded-ref invariant: raw ids like 0x00000300 still resolve).
	a := build_master_plugin();defer delete(a)
	b := build_addon_plugin();defer delete(b)
	inputs := []gamedb.Plugin_Input{{name = "Skyrim.esm", data = a}, {name = "Update.esm", data = b}}

	ft: mods.Form_Table
	mods.formtable_init(&ft)
	defer mods.formtable_destroy(&ft)
	mods.formtable_assign_official(&ft, "Skyrim.esm", 0)
	upd := mods.formtable_intern(&ft, "Update.esm", "uuid-upd") // → 0x10

	slot_of := make(map[string]u32, 2, context.temp_allocator)
	slot_of["skyrim.esm"] = 0
	slot_of["update.esm"] = upd

	order := gamedb.resolve_load_order(inputs, context.allocator, slot_of)
	defer delete(order, context.allocator)
	db := gamedb.build_plugins(order)
	defer gamedb.destroy(&db)

	m, ok := gamedb.model_of(&db, (gamedb.Form_ID(upd) << 32) | 0x0000_0400)
	testing.expect(t, ok, "addon STAT lives at the STABLE slot 0x10, not the load index")
	testing.expect_value(t, m, "addon.nif")
	_, mok := gamedb.model_of(&db, 0x0000_0300) // Skyrim.esm slot 0 → raw id unchanged
	testing.expect(t, mok, "Skyrim.esm forms keep slot 0 (raw-ref invariant)")
}

@(test)
test_gamedb_reorder_keeps_slot :: proc(t: ^testing.T) {
	// The headline claim, headless: installing another mod + reordering does NOT renumber an existing
	// plugin's forms. Update.esm keeps slot 0x10 even after a NEW plugin is interned first — because
	// the slot comes from the persisted, monotonic form-table, not the load order. So the same save
	// still points at the same forms (cf. the reorder-breaks-saves bug this closes).
	a := build_master_plugin();defer delete(a)
	b := build_addon_plugin();defer delete(b)

	ft: mods.Form_Table
	mods.formtable_init(&ft)
	defer mods.formtable_destroy(&ft)
	mods.formtable_assign_official(&ft, "Skyrim.esm", 0)
	upd := mods.formtable_intern(&ft, "Update.esm", "uuid-upd") // 0x10
	mods.formtable_intern(&ft, "NewMod.esp", "uuid-new") // 0x11 — a later install, does NOT touch Update
	testing.expect(t, mods.formtable_intern(&ft, "Update.esm", "uuid-upd") == upd, "Update.esm keeps its slot")

	slot_of := make(map[string]u32, 2, context.temp_allocator)
	slot_of["skyrim.esm"] = 0
	slot_of["update.esm"] = upd

	inputs := []gamedb.Plugin_Input{{name = "Skyrim.esm", data = a}, {name = "Update.esm", data = b}}
	order := gamedb.resolve_load_order(inputs, context.allocator, slot_of)
	defer delete(order, context.allocator)
	db := gamedb.build_plugins(order)
	defer gamedb.destroy(&db)

	m, ok := gamedb.model_of(&db, (gamedb.Form_ID(upd) << 32) | 0x0000_0400)
	testing.expect(t, ok, "Update's addon STAT is STILL at slot 0x10 after the new install")
	testing.expect_value(t, m, "addon.nif")
}

@(test)
test_esm_full_xesp_fields :: proc(t: ^testing.T) {
	// FULL inline name + XESP enable-parent (parent formID + flags; bit0 = opposite).
	body := make([dynamic]u8, 0, 48);defer delete(body)
	field(&body, "FULL", transmute([]u8)string("Iron Sword\x00"))
	xesp: [8]u8
	put_u32(xesp[:], 0, 0x0001_0010)
	put_u32(xesp[:], 4, esm.XESP_OPPOSITE)
	field(&body, "XESP", xesp[:])

	rec := esm.Record{type = "REFR", data = body[:]}
	fl, backing, ok := esm.fields(rec)
	testing.expect(t, ok, "split fields")
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	testing.expect_value(t, esm.full_name(fl), "Iron Sword")
	_, sok := esm.full_string_id(fl) // FULL present ⇒ readable as a u32 id (localized path)
	testing.expect(t, sok, "full_string_id reads the u32")

	ep, eok := esm.refr_enable_parent(fl)
	testing.expect(t, eok, "decode XESP")
	testing.expect_value(t, ep.parent, u32(0x0001_0010))
	testing.expect(t, ep.opposite, "XESP opposite flag set")
}

@(test)
test_gamedb_names_inline :: proc(t: ^testing.T) {
	// Non-localized plugin: FULL is inline text. name_of resolves a base's own name, a ref
	// with no override → its base's name, and a ref WITH a FULL override → the override.
	data := build_named_plugin()
	defer delete(data)
	db := gamedb.build(data)
	defer gamedb.destroy(&db)

	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0300), "Iron Sword") // base's own FULL
	testing.expect_value(t, gamedb.name_of(&db, 0x0001_0000), "Iron Sword") // ref → base
	testing.expect_value(t, gamedb.name_of(&db, 0x0001_0005), "Unique Blade") // ref FULL override
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_9999), "") // unknown form
}

@(test)
test_gamedb_cell_full_and_locks :: proc(t: ^testing.T) {
	// A named interior CELL (FULL "Test Shop") + a locked REFR (XLOC) + an unlocked REFR (no XLOC).
	// name_of resolves the CELL's FULL (so a load door shows a real place name); lock_of reports the
	// locked ref and its remapped key, and reports the unlocked ref as not locked.
	data := build_lock_plugin()
	defer delete(data)
	db := gamedb.build(data)
	defer gamedb.destroy(&db)

	testing.expect_value(t, gamedb.name_of(&db, 0x0000_00AA), "Test Shop") // CELL FULL indexed

	lk, lok := gamedb.lock_of(&db, 0x0001_0000)
	testing.expect(t, lok, "locked REFR has a baseline lock")
	testing.expect_value(t, lk.level, u8(0x32))
	testing.expect_value(t, lk.key, gamedb.Form_ID(0x0000_0A0B)) // key remapped into global space

	_, uok := gamedb.lock_of(&db, 0x0001_0001)
	testing.expect(t, !uok, "unlocked REFR has no baseline lock")
}

@(test)
test_gamedb_localized_names :: proc(t: ^testing.T) {
	// Localized plugin: FULL is a u32 string id resolved via the STRINGS table. Drive
	// build_plugins directly with a hand-made Loaded_Plugin (localized + strings bytes).
	data := build_localized_plugin(5) // STAT 0x300 FULL = string id 5
	defer delete(data)

	// STRINGS blob: id 5 -> "Dragonbone Sword".
	block: [dynamic]u8;defer delete(block)
	append(&block, ..transmute([]u8)string("Dragonbone Sword\x00"))
	sblob := make([dynamic]u8, 0, 64);defer delete(sblob)
	put_dyn_u32(&sblob, 1) // count
	put_dyn_u32(&sblob, u32(len(block))) // dataSize
	put_dyn_u32(&sblob, 5) // stringID
	put_dyn_u32(&sblob, 0) // offset
	append(&sblob, ..block[:])

	lp := gamedb.Loaded_Plugin {
		data         = data,
		strings_data = sblob[:],
		localized    = true,
	}
	db := gamedb.build_plugins({lp})
	defer gamedb.destroy(&db)
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0300), "Dragonbone Sword")
}

@(test)
test_gamedb_enable_parent :: proc(t: ^testing.T) {
	// XESP enable-parent gating: a child of a DISABLED parent is effectively disabled (culled)
	// unless it flips the state with the opposite flag. A ref with no parent follows its own flag.
	data := build_enable_parent_plugin()
	defer delete(data)
	db := gamedb.build(data)
	defer gamedb.destroy(&db)

	parent, _ := gamedb.ref_by_formid(&db, 0x0001_0010)
	child, _ := gamedb.ref_by_formid(&db, 0x0001_0011)
	child_opp, _ := gamedb.ref_by_formid(&db, 0x0001_0012)
	lone, _ := gamedb.ref_by_formid(&db, 0x0001_0013)

	testing.expect(t, gamedb.ref_effective_disabled(&db, parent), "parent is initially disabled")
	testing.expect(t, gamedb.ref_effective_disabled(&db, child), "child of a disabled parent is culled")
	testing.expect(t, !gamedb.ref_effective_disabled(&db, child_opp), "opposite child shows when parent is off")
	testing.expect(t, !gamedb.ref_effective_disabled(&db, lone), "unparented enabled ref shows")
	testing.expect_value(t, child.enable_parent, gamedb.Form_ID(0x0001_0010))
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

// build_lock_plugin: like build_plugin, but the interior CELL 0xAA carries a FULL ("Test Shop") and
// holds two REFRs — 0x00010000 with an XLOC lock (level 50, key 0x0A0B) and 0x00010001 with none.
// Drives the CELL-FULL + XLOC decode/index path.
@(private = "file")
build_lock_plugin :: proc() -> []u8 {
	tes4_body := make([dynamic]u8, 0, 32);defer delete(tes4_body)
	hedr: [12]u8
	put_f32(hedr[:], 0, 1.7)
	put_u32(hedr[:], 8, 0x0000_0042)
	field(&tes4_body, "HEDR", hedr[:])

	// CELL 0xAA: EDID + FULL (inline) + interior DATA.
	cell_body := make([dynamic]u8, 0, 48);defer delete(cell_body)
	field(&cell_body, "EDID", transmute([]u8)string("TestShopInterior\x00"))
	field(&cell_body, "FULL", transmute([]u8)string("Test Shop\x00"))
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})

	// REFR 0x00010000: NAME + DATA + XLOC (locked).
	locked_body := make([dynamic]u8, 0, 64);defer delete(locked_body)
	field(&locked_body, "NAME", u32_bytes(0x0001_2345))
	ldata: [24]u8
	field(&locked_body, "DATA", ldata[:])
	xloc: [20]u8
	xloc[0] = 0x32
	put_u32(xloc[:], 4, 0x0000_0A0B)
	field(&locked_body, "XLOC", xloc[:])

	// REFR 0x00010001: NAME + DATA (unlocked, no XLOC).
	open_body := make([dynamic]u8, 0, 48);defer delete(open_body)
	field(&open_body, "NAME", u32_bytes(0x0001_2345))
	odata: [24]u8
	field(&open_body, "DATA", odata[:])

	out := make([dynamic]u8, 0, 320)
	record(&out, "TES4", 0, 0, tes4_body[:])

	// Cell-children GRUP(6), label = CELL formID, holds both REFRs.
	children := make([dynamic]u8, 0, 128);defer delete(children)
	record(&children, "REFR", 0, 0x0001_0000, locked_body[:])
	record(&children, "REFR", 0, 0x0001_0001, open_body[:])
	cc_grup := make([dynamic]u8, 0, 160);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, children[:])

	cell_group_content := make([dynamic]u8, 0, 192);defer delete(cell_group_content)
	record(&cell_group_content, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_group_content, ..cc_grup[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_group_content[:])
	return out[:]
}

// build_master_plugin: a no-master plugin (like Skyrim.esm) — TES4 + a top STAT GRUP with
// STAT 0x00000300 (MODL "rock.nif") + a top CELL GRUP with interior CELL 0xAA → REFR 0x00010000
// referencing that STAT.
@(private = "file")
build_master_plugin :: proc() -> []u8 {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	stat_body := make([dynamic]u8, 0, 32);defer delete(stat_body)
	field(&stat_body, "MODL", transmute([]u8)string("rock.nif\x00"))
	stat_content := make([dynamic]u8, 0, 64);defer delete(stat_content)
	record(&stat_content, "STAT", 0, 0x0000_0300, stat_body[:])

	cell_body := make([dynamic]u8, 0, 32);defer delete(cell_body)
	field(&cell_body, "EDID", transmute([]u8)string("TestCell\x00"))
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})
	refr_body := make([dynamic]u8, 0, 48);defer delete(refr_body)
	field(&refr_body, "NAME", u32_bytes(0x0000_0300))
	rdata: [24]u8;field(&refr_body, "DATA", rdata[:])
	cc := make([dynamic]u8, 0, 64);defer delete(cc)
	record(&cc, "REFR", 0, 0x0001_0000, refr_body[:])
	cc_grup := make([dynamic]u8, 0, 96);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, cc[:])
	cell_grp := make([dynamic]u8, 0, 128);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_grp, ..cc_grup[:])

	out := make([dynamic]u8, 0, 256)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("STAT"), 0, stat_content[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])
	return out[:]
}

// build_addon_plugin: a plugin mastered on the first (TES4 MAST "Skyrim.esm"). It OVERRIDES
// STAT 0x300 (local high byte 0 = master) with a new mesh, ADDS STAT 0x01000400 (local high
// byte 1 = self) and a REFR 0x01010001 under the master's cell 0xAA pointing at the new STAT.
@(private = "file")
build_addon_plugin :: proc() -> []u8 {
	tes4 := make([dynamic]u8, 0, 48);defer delete(tes4)
	field(&tes4, "MAST", transmute([]u8)string("Skyrim.esm\x00"))
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0100_0800)
	field(&tes4, "HEDR", hedr[:])

	s1 := make([dynamic]u8, 0, 32);defer delete(s1)
	field(&s1, "MODL", transmute([]u8)string("rock_fixed.nif\x00"))
	s2 := make([dynamic]u8, 0, 32);defer delete(s2)
	field(&s2, "MODL", transmute([]u8)string("addon.nif\x00"))
	stat_content := make([dynamic]u8, 0, 128);defer delete(stat_content)
	record(&stat_content, "STAT", 0, 0x0000_0300, s1[:]) // local hi 0 = master STAT (override)
	record(&stat_content, "STAT", 0, 0x0100_0400, s2[:]) // local hi 1 = self (new)

	cell_body := make([dynamic]u8, 0, 32);defer delete(cell_body)
	field(&cell_body, "EDID", transmute([]u8)string("TestCell\x00"))
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})
	refr_body := make([dynamic]u8, 0, 48);defer delete(refr_body)
	field(&refr_body, "NAME", u32_bytes(0x0100_0400)) // local self base
	rdata: [24]u8;field(&refr_body, "DATA", rdata[:])
	cc := make([dynamic]u8, 0, 64);defer delete(cc)
	record(&cc, "REFR", 0, 0x0101_0001, refr_body[:]) // local self refr
	cc_grup := make([dynamic]u8, 0, 96);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, cc[:]) // label = master cell (local hi 0)
	cell_grp := make([dynamic]u8, 0, 128);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_grp, ..cc_grup[:])

	out := make([dynamic]u8, 0, 256)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("STAT"), 0, stat_content[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])
	return out[:]
}

// build_named_plugin: a NON-localized plugin — TES4 + STAT 0x300 (MODL + FULL "Iron Sword") +
// interior CELL 0xAA → REFR 0x00010000 (base 0x300, no FULL) + REFR 0x00010005 (base 0x300,
// FULL override "Unique Blade"). Exercises name_of's base/ref/override resolution.
@(private = "file")
build_named_plugin :: proc() -> []u8 {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	stat_body := make([dynamic]u8, 0, 48);defer delete(stat_body)
	field(&stat_body, "MODL", transmute([]u8)string("sword.nif\x00"))
	field(&stat_body, "FULL", transmute([]u8)string("Iron Sword\x00"))
	stat_content := make([dynamic]u8, 0, 64);defer delete(stat_content)
	record(&stat_content, "STAT", 0, 0x0000_0300, stat_body[:])

	cell_body := make([dynamic]u8, 0, 32);defer delete(cell_body)
	field(&cell_body, "EDID", transmute([]u8)string("TestCell\x00"))
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})

	r1 := make([dynamic]u8, 0, 48);defer delete(r1)
	field(&r1, "NAME", u32_bytes(0x0000_0300))
	rdata: [24]u8;field(&r1, "DATA", rdata[:])
	r2 := make([dynamic]u8, 0, 48);defer delete(r2)
	field(&r2, "NAME", u32_bytes(0x0000_0300))
	field(&r2, "DATA", rdata[:])
	field(&r2, "FULL", transmute([]u8)string("Unique Blade\x00"))

	cc := make([dynamic]u8, 0, 128);defer delete(cc)
	record(&cc, "REFR", 0, 0x0001_0000, r1[:])
	record(&cc, "REFR", 0, 0x0001_0005, r2[:])
	cc_grup := make([dynamic]u8, 0, 160);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, cc[:])
	cell_grp := make([dynamic]u8, 0, 192);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_grp, ..cc_grup[:])

	out := make([dynamic]u8, 0, 320)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("STAT"), 0, stat_content[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])
	return out[:]
}

// build_localized_plugin: STAT 0x300 whose FULL is a u32 STRINGS id (localization is signalled
// via the Loaded_Plugin, not the header, so build_plugins resolves it through the strings table).
@(private = "file")
build_localized_plugin :: proc(sid: u32) -> []u8 {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	stat_body := make([dynamic]u8, 0, 48);defer delete(stat_body)
	field(&stat_body, "MODL", transmute([]u8)string("sword.nif\x00"))
	field(&stat_body, "FULL", u32_bytes(sid))
	stat_content := make([dynamic]u8, 0, 64);defer delete(stat_content)
	record(&stat_content, "STAT", 0, 0x0000_0300, stat_body[:])

	out := make([dynamic]u8, 0, 128)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("STAT"), 0, stat_content[:])
	return out[:]
}

// build_enable_parent_plugin: interior CELL 0xAA with a DISABLED parent REFR (0x00010010) and
// three children referencing STAT 0x300 — a plain child (0x00010011, gated off with the parent),
// an opposite child (0x00010012, shown when the parent is off), and a lone unparented REFR
// (0x00010013). Exercises ref_effective_disabled.
@(private = "file")
build_enable_parent_plugin :: proc() -> []u8 {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	stat_body := make([dynamic]u8, 0, 32);defer delete(stat_body)
	field(&stat_body, "MODL", transmute([]u8)string("rock.nif\x00"))
	stat_content := make([dynamic]u8, 0, 64);defer delete(stat_content)
	record(&stat_content, "STAT", 0, 0x0000_0300, stat_body[:])

	cell_body := make([dynamic]u8, 0, 32);defer delete(cell_body)
	field(&cell_body, "EDID", transmute([]u8)string("TestCell\x00"))
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})

	rdata: [24]u8
	// Parent (initially disabled).
	rp := make([dynamic]u8, 0, 48);defer delete(rp)
	field(&rp, "NAME", u32_bytes(0x0000_0300));field(&rp, "DATA", rdata[:])
	// Child gated by the parent (opposite off).
	rc := make([dynamic]u8, 0, 48);defer delete(rc)
	field(&rc, "NAME", u32_bytes(0x0000_0300));field(&rc, "DATA", rdata[:])
	xc: [8]u8;put_u32(xc[:], 0, 0x0001_0010);put_u32(xc[:], 4, 0);field(&rc, "XESP", xc[:])
	// Child with opposite flag (shown when parent off).
	ro := make([dynamic]u8, 0, 48);defer delete(ro)
	field(&ro, "NAME", u32_bytes(0x0000_0300));field(&ro, "DATA", rdata[:])
	xo: [8]u8;put_u32(xo[:], 0, 0x0001_0010);put_u32(xo[:], 4, esm.XESP_OPPOSITE);field(&ro, "XESP", xo[:])
	// Lone unparented ref.
	rl := make([dynamic]u8, 0, 48);defer delete(rl)
	field(&rl, "NAME", u32_bytes(0x0000_0300));field(&rl, "DATA", rdata[:])

	cc := make([dynamic]u8, 0, 256);defer delete(cc)
	record(&cc, "REFR", gamedb.REFR_INITIALLY_DISABLED, 0x0001_0010, rp[:])
	record(&cc, "REFR", 0, 0x0001_0011, rc[:])
	record(&cc, "REFR", 0, 0x0001_0012, ro[:])
	record(&cc, "REFR", 0, 0x0001_0013, rl[:])
	cc_grup := make([dynamic]u8, 0, 320);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, cc[:])
	cell_grp := make([dynamic]u8, 0, 384);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_grp, ..cc_grup[:])

	out := make([dynamic]u8, 0, 512)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("STAT"), 0, stat_content[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])
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

// gamedb classifies QUST/GLOB/FACT records into Form_Kind (the form→class dispatch decoder). Build a
// plugin with one of each as a top-level group and assert the kinds; unknown ids + nil DB → Unknown.
@(test)
test_gamedb_form_kinds :: proc(t: ^testing.T) {
	tes4_body := make([dynamic]u8, 0, 32)
	defer delete(tes4_body)
	hedr: [12]u8
	put_f32(hedr[:], 0, 1.7)
	put_u32(hedr[:], 8, 0x0000_00FF)
	field(&tes4_body, "HEDR", hedr[:])

	out := make([dynamic]u8, 0, 256)
	defer delete(out)
	record(&out, "TES4", 0, 0, tes4_body[:])
	add_top_record(&out, "QUST", 0x0000_00C0)
	add_top_record(&out, "GLOB", 0x0000_00C1)
	add_top_record(&out, "FACT", 0x0000_00C2)
	// base-object / form-subtype records → their Papyrus base class (chain {Class, Form}).
	add_top_record(&out, "NPC_", 0x0000_00D0)
	add_top_record(&out, "WEAP", 0x0000_00D1)
	add_top_record(&out, "ALCH", 0x0000_00D2)
	add_top_record(&out, "KYWD", 0x0000_00D3)

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00C0), gamedb.Form_Kind.Quest)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00C1), gamedb.Form_Kind.Global)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00C2), gamedb.Form_Kind.Faction)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00D0), gamedb.Form_Kind.ActorBase)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00D1), gamedb.Form_Kind.Weapon)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00D2), gamedb.Form_Kind.Potion)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00D3), gamedb.Form_Kind.Keyword)
	testing.expect_value(t, gamedb.class_name(gamedb.Form_Kind.Weapon), "Weapon")
	testing.expect_value(t, gamedb.class_name(gamedb.Form_Kind.Unknown), "ObjectReference")
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_00FF), gamedb.Form_Kind.Unknown) // a REFR/base id
	testing.expect_value(t, gamedb.form_kind(nil, 0x0000_00C0), gamedb.Form_Kind.Unknown) // nil DB safe
}

// gamedb decodes LSCR (LoadScreen) DESC into the loading-tip pool, skipping the NNAM 3D model. Build a
// non-localized plugin with one LSCR (NNAM + inline DESC) and assert the tip lands in load_tips.
@(test)
test_gamedb_load_tips :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	lscr_body := make([dynamic]u8, 0, 64);defer delete(lscr_body)
	field(&lscr_body, "NNAM", u32_bytes(0x0000_0111)) // 3D model form — must be skipped
	field(&lscr_body, "DESC", transmute([]u8)string("Press Tab to open your inventory.\x00"))
	lscr_content := make([dynamic]u8, 0, 96);defer delete(lscr_content)
	record(&lscr_content, "LSCR", 0, 0x0000_0500, lscr_body[:])

	out := make([dynamic]u8, 0, 160);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("LSCR"), 0, lscr_content[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	tips := gamedb.load_tips(&db)
	testing.expect_value(t, len(tips), 1)
	testing.expect_value(t, tips[0], "Press Tab to open your inventory.")
}

// Item value/weight decode (4a item 2): each carriable base-form's DATA/ENIT layout — WEAP/ARMO/…
// {value@0, weight@4}; BOOK {value@8, weight@12}; AMMO {value@12, weightless}; ALCH {weight in
// DATA, value in ENIT}. Also: a placed REFR resolves its base's value/weight, and a non-item is
// value-less. Byte layouts validated against the real Skyrim.esm via `esmdump --items`.
@(test)
test_gamedb_item_value_weight :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// WEAP 0x100: DATA[10] value 25 @0, weight 9.0 @4, damage @8.
	weap := make([dynamic]u8, 0, 32);defer delete(weap)
	wd: [10]u8;put_u32(wd[:], 0, 25);put_f32(wd[:], 4, 9.0)
	field(&weap, "DATA", wd[:])
	// BOOK 0x101: DATA[16] value 730 @8, weight 1.0 @12 (flags/type/teaches precede).
	book := make([dynamic]u8, 0, 32);defer delete(book)
	bd: [16]u8;put_u32(bd[:], 8, 730);put_f32(bd[:], 12, 1.0)
	field(&book, "DATA", bd[:])
	// AMMO 0x102: DATA[16] value 5 @12, no weight.
	ammo := make([dynamic]u8, 0, 32);defer delete(ammo)
	ad: [16]u8;put_u32(ad[:], 12, 5)
	field(&ammo, "DATA", ad[:])
	// ALCH 0x103: weight 0.5 in DATA, value 10 in ENIT[0].
	alch := make([dynamic]u8, 0, 32);defer delete(alch)
	dd: [4]u8;put_f32(dd[:], 0, 0.5);field(&alch, "DATA", dd[:])
	ed: [20]u8;put_u32(ed[:], 0, 10);field(&alch, "ENIT", ed[:])

	// A cell with a REFR (0x200) whose base is the WEAP — for ref→base value resolution.
	cell_body := make([dynamic]u8, 0, 16);defer delete(cell_body)
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})
	refr := make([dynamic]u8, 0, 32);defer delete(refr)
	field(&refr, "NAME", u32_bytes(0x0000_0100)) // base = the WEAP
	rdata: [24]u8;field(&refr, "DATA", rdata[:])
	cc := make([dynamic]u8, 0, 48);defer delete(cc)
	record(&cc, "REFR", 0, 0x0000_0200, refr[:])
	cc_grup := make([dynamic]u8, 0, 64);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, cc[:])
	cell_grp := make([dynamic]u8, 0, 96);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_grp, ..cc_grup[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	item_grp :: proc(out: ^[dynamic]u8, sig: string, formid: u32, body: []u8) {
		c := make([dynamic]u8, 0, 64);defer delete(c)
		record(&c, sig, 0, formid, body)
		group(out, transmute([]u8)sig, 0, c[:])
	}
	item_grp(&out, "WEAP", 0x0000_0100, weap[:])
	item_grp(&out, "BOOK", 0x0000_0101, book[:])
	item_grp(&out, "AMMO", 0x0000_0102, ammo[:])
	item_grp(&out, "ALCH", 0x0000_0103, alch[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	expect_vw :: proc(t: ^testing.T, db: ^gamedb.DB, form: gamedb.Form_ID, ev: i32, ew: f32) {
		v, vok := gamedb.value_of(db, form)
		w, wok := gamedb.weight_of(db, form)
		testing.expect(t, vok && wok, "value/weight present")
		testing.expect_value(t, v, ev)
		testing.expect_value(t, w, ew)
	}
	expect_vw(t, &db, 0x0000_0100, 25, 9.0)  // WEAP
	expect_vw(t, &db, 0x0000_0101, 730, 1.0) // BOOK (offset-8 value)
	expect_vw(t, &db, 0x0000_0102, 5, 0.0)   // AMMO (weightless)
	expect_vw(t, &db, 0x0000_0103, 10, 0.5)  // ALCH (value from ENIT)
	// Classification still applies to item bases now that they also hit is_base_type.
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_0100), gamedb.Form_Kind.Weapon)
	testing.expect_value(t, gamedb.form_kind(&db, 0x0000_0103), gamedb.Form_Kind.Potion)
	// A placed REFR resolves its base's value/weight.
	expect_vw(t, &db, 0x0000_0200, 25, 9.0)
	// A non-item form has no value/weight.
	_, vok := gamedb.value_of(&db, 0x0000_00AA) // the CELL
	testing.expect(t, !vok, "cell is not a valued item")
}

// CONT inventory decode (4a item 4): a container's CNTO entries {item formID, count} index into a
// baseline inventory, item formIDs remapped to global space; a placed REFR resolves its base CONT's
// contents; a non-container has none. Validated against the real game via `esmdump --contents`.
@(test)
test_gamedb_container_contents :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// CONT 0x300: MODL + two CNTO entries — 5x item 0x100, 1x item 0x101.
	cont := make([dynamic]u8, 0, 48);defer delete(cont)
	field(&cont, "MODL", transmute([]u8)string("chest.nif\x00"))
	c0: [8]u8;put_u32(c0[:], 0, 0x0000_0100);put_u32(c0[:], 4, 5)
	field(&cont, "CNTO", c0[:])
	c1: [8]u8;put_u32(c1[:], 0, 0x0000_0101);put_u32(c1[:], 4, 1)
	field(&cont, "CNTO", c1[:])
	cont_grp := make([dynamic]u8, 0, 96);defer delete(cont_grp)
	record(&cont_grp, "CONT", 0, 0x0000_0300, cont[:])

	// A cell with a REFR (0x400) whose base is the CONT — for ref→base contents resolution.
	cell_body := make([dynamic]u8, 0, 16);defer delete(cell_body)
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})
	refr := make([dynamic]u8, 0, 32);defer delete(refr)
	field(&refr, "NAME", u32_bytes(0x0000_0300)) // base = the CONT
	rdata: [24]u8;field(&refr, "DATA", rdata[:])
	cc := make([dynamic]u8, 0, 48);defer delete(cc)
	record(&cc, "REFR", 0, 0x0000_0400, refr[:])
	cc_grup := make([dynamic]u8, 0, 64);defer delete(cc_grup)
	group(&cc_grup, u32_bytes(0x0000_00AA), 6, cc[:])
	cell_grp := make([dynamic]u8, 0, 96);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_00AA, cell_body[:])
	append(&cell_grp, ..cc_grup[:])

	out := make([dynamic]u8, 0, 320);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("CONT"), 0, cont_grp[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	entries, ok := gamedb.contents_of(&db, 0x0000_0300)
	testing.expect(t, ok, "CONT has contents")
	testing.expect_value(t, len(entries), 2)
	testing.expect_value(t, entries[0].item, gamedb.Form_ID(0x0000_0100))
	testing.expect_value(t, entries[0].count, i32(5))
	testing.expect_value(t, entries[1].item, gamedb.Form_ID(0x0000_0101))
	testing.expect_value(t, entries[1].count, i32(1))
	// A placed container REFR resolves its base's inventory.
	rentries, rok := gamedb.contents_of(&db, 0x0000_0400)
	testing.expect(t, rok && len(rentries) == 2, "REFR resolves base contents")
	// A non-container form has none.
	_, nok := gamedb.contents_of(&db, 0x0000_00AA) // the CELL
	testing.expect(t, !nok, "cell has no contents")
}

// FLST form-list decode (4a): an FLST's ordered LNAM members index as a remapped Form_ID slice, in
// declaration order; a non-list form has none. Validated against the real game via `esmdump --flst`.
@(test)
test_gamedb_form_list :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// FLST 0x500: three ordered members (order is significant, not sorted).
	flst := make([dynamic]u8, 0, 48);defer delete(flst)
	field(&flst, "EDID", transmute([]u8)string("TestVoiceTypes\x00"))
	field(&flst, "LNAM", u32_bytes(0x0000_0202))
	field(&flst, "LNAM", u32_bytes(0x0000_0200))
	field(&flst, "LNAM", u32_bytes(0x0000_0201))
	flst_grp := make([dynamic]u8, 0, 96);defer delete(flst_grp)
	record(&flst_grp, "FLST", 0, 0x0000_0500, flst[:])

	out := make([dynamic]u8, 0, 256);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("FLST"), 0, flst_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	members, ok := gamedb.form_list_of(&db, 0x0000_0500)
	testing.expect(t, ok, "FLST has members")
	testing.expect_value(t, len(members), 3)
	// Order preserved verbatim (no sorting).
	testing.expect_value(t, members[0], gamedb.Form_ID(0x0000_0202))
	testing.expect_value(t, members[1], gamedb.Form_ID(0x0000_0200))
	testing.expect_value(t, members[2], gamedb.Form_ID(0x0000_0201))
	// A non-list form has none.
	_, nok := gamedb.form_list_of(&db, 0x0000_0999)
	testing.expect(t, !nok, "unknown form has no member list")
}

// LVLI leveled-list decode (4a, decode-only): LVLD chance-none + LVLF flags + each 12-byte LVLO
// {level, form, count} with the form remapped; entry order preserved; no rolling. Validated against
// the real game via `esmdump --lvli` (LVLO stride confirmed 12 bytes on LItemBlacksmithWeapon75).
@(test)
test_gamedb_leveled_list :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// LVLI 0x600: chance-none 25, flags 0x03, two 12-byte LVLO entries.
	lvli := make([dynamic]u8, 0, 64);defer delete(lvli)
	field(&lvli, "EDID", transmute([]u8)string("LItemTest\x00"))
	field(&lvli, "LVLD", []u8{25})
	field(&lvli, "LVLF", []u8{esm.LVLI_CALC_FROM_ALL_LEVELS | esm.LVLI_CALC_FOR_EACH})
	field(&lvli, "LLCT", []u8{2})
	// LVLO: level u16@0, pad u16@2, formID u32@4, count u16@8, pad u16@10.
	e0: [12]u8;put_u16(e0[:], 0, 1);put_u32(e0[:], 4, 0x0000_0310);put_u16(e0[:], 8, 1)
	field(&lvli, "LVLO", e0[:])
	e1: [12]u8;put_u16(e1[:], 0, 10);put_u32(e1[:], 4, 0x0000_0311);put_u16(e1[:], 8, 3)
	field(&lvli, "LVLO", e1[:])
	lvli_grp := make([dynamic]u8, 0, 128);defer delete(lvli_grp)
	record(&lvli_grp, "LVLI", 0, 0x0000_0600, lvli[:])

	out := make([dynamic]u8, 0, 320);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("LVLI"), 0, lvli_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	ll, ok := gamedb.leveled_list_of(&db, 0x0000_0600)
	testing.expect(t, ok, "LVLI decoded")
	testing.expect_value(t, ll.chance_none, u8(25))
	testing.expect_value(t, ll.flags, u8(0x03))
	testing.expect_value(t, len(ll.entries), 2)
	testing.expect_value(t, ll.entries[0].level, u16(1))
	testing.expect_value(t, ll.entries[0].form, gamedb.Form_ID(0x0000_0310))
	testing.expect_value(t, ll.entries[0].count, u16(1))
	testing.expect_value(t, ll.entries[1].level, u16(10))
	testing.expect_value(t, ll.entries[1].form, gamedb.Form_ID(0x0000_0311))
	testing.expect_value(t, ll.entries[1].count, u16(3))
	// A non-list form has none.
	_, nok := gamedb.leveled_list_of(&db, 0x0000_0999)
	testing.expect(t, !nok, "unknown form is not a leveled list")
}

// GLOB FLTV baseline decode (4a, Tier-3 gap): a global's FNAM type + FLTV value index into
// global_values as f32; a non-global form has none. Validated against the real game via
// `esmdump --glob` (GameHour 0x00000038 = 8.0).
@(test)
test_gamedb_global_value :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// GLOB 0x700: float type, value 8.0.
	glob := make([dynamic]u8, 0, 32);defer delete(glob)
	field(&glob, "EDID", transmute([]u8)string("TestGameHour\x00"))
	field(&glob, "FNAM", []u8{'f'})
	fltv: [4]u8;put_f32(fltv[:], 0, 8.0)
	field(&glob, "FLTV", fltv[:])
	glob_grp := make([dynamic]u8, 0, 64);defer delete(glob_grp)
	record(&glob_grp, "GLOB", 0, 0x0000_0700, glob[:])

	out := make([dynamic]u8, 0, 256);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("GLOB"), 0, glob_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	v, ok := gamedb.global_value(&db, 0x0000_0700)
	testing.expect(t, ok, "GLOB baseline decoded")
	testing.expect_value(t, v, f32(8.0))
	// A non-global form has none.
	_, nok := gamedb.global_value(&db, 0x0000_0999)
	testing.expect(t, !nok, "unknown form has no global value")
}

// GMST typed decode: the editor-id prefix ('f' 'i' 'b' 's') picks the value type, DATA carries it.
// Settings are keyed by lower-cased name, and the numeric kinds coerce between each other the way
// the engine reads them. Validated against the real game via `esmdump --gmst` (Skyrim.esm: 1,584
// settings — 558 float, 96 int, 1 bool, 929 string; fJumpHeightMin = 76, iDaysToRespawnVendor = 2).
// This plugin is NOT localized, so a string setting carries its text inline (the mod-ESP path).
@(test)
test_gamedb_game_setting :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	gmst_grp := make([dynamic]u8, 0, 256);defer delete(gmst_grp)

	fset := make([dynamic]u8, 0, 32);defer delete(fset)
	field(&fset, "EDID", transmute([]u8)string("fTestJumpHeight\x00"))
	fdata: [4]u8;put_f32(fdata[:], 0, 76.0)
	field(&fset, "DATA", fdata[:])
	record(&gmst_grp, "GMST", 0, 0x0000_0710, fset[:])

	iset := make([dynamic]u8, 0, 32);defer delete(iset)
	field(&iset, "EDID", transmute([]u8)string("iTestRespawnDays\x00"))
	idata: [4]u8;put_u32(idata[:], 0, 2)
	field(&iset, "DATA", idata[:])
	record(&gmst_grp, "GMST", 0, 0x0000_0711, iset[:])

	bset := make([dynamic]u8, 0, 32);defer delete(bset)
	field(&bset, "EDID", transmute([]u8)string("bTestEnabled\x00"))
	bdata: [4]u8;put_u32(bdata[:], 0, 1)
	field(&bset, "DATA", bdata[:])
	record(&gmst_grp, "GMST", 0, 0x0000_0712, bset[:])

	sset := make([dynamic]u8, 0, 32);defer delete(sset)
	field(&sset, "EDID", transmute([]u8)string("sTestLabel\x00"))
	field(&sset, "DATA", transmute([]u8)string("ARMOR RATING\x00"))
	record(&gmst_grp, "GMST", 0, 0x0000_0713, sset[:])

	// A later record with the SAME name overrides the earlier one — the path a mod takes to retune
	// a setting. The previous string value has to be freed, so this branch is where a leak lives.
	sover := make([dynamic]u8, 0, 32);defer delete(sover)
	field(&sover, "EDID", transmute([]u8)string("sTestLabel\x00"))
	field(&sover, "DATA", transmute([]u8)string("ARMOUR RATING\x00"))
	record(&gmst_grp, "GMST", 0, 0x0000_0714, sover[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("GMST"), 0, gmst_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	testing.expect_value(t, len(db.settings), 4)
	testing.expect_value(t, gamedb.setting_float(&db, "fTestJumpHeight"), f32(76.0))
	testing.expect_value(t, gamedb.setting_int(&db, "iTestRespawnDays"), i32(2))
	testing.expect_value(t, gamedb.setting_bool(&db, "bTestEnabled"), true)
	testing.expect_value(t, gamedb.setting_string(&db, "sTestLabel"), "ARMOUR RATING") // last wins

	// Names are case-insensitive — scripts spell them however they like.
	testing.expect_value(t, gamedb.setting_float(&db, "FTESTJUMPHEIGHT"), f32(76.0))

	// The numeric kinds coerce between each other; a float truncates toward zero on an int read.
	testing.expect_value(t, gamedb.setting_float(&db, "iTestRespawnDays"), f32(2.0))
	testing.expect_value(t, gamedb.setting_int(&db, "fTestJumpHeight"), i32(76))
	testing.expect_value(t, gamedb.setting_float(&db, "bTestEnabled"), f32(1.0))

	// An unknown name, and a kind mismatch on the string reader, both fall back to the default.
	testing.expect_value(t, gamedb.setting_float(&db, "fNoSuchSetting", 3.5), f32(3.5))
	testing.expect_value(t, gamedb.setting_string(&db, "fTestJumpHeight", "fallback"), "fallback")
	testing.expect_value(t, gamedb.setting_bool(&db, "bNoSuchSetting", true), true)
}

// MESG decode: DNAM flags, FULL title, DESC body, ITXT buttons in record order, QNAM owner quest.
// The two text fields sit in DIFFERENT string tables — DESC in DLSTRINGS, FULL and ITXT in plain
// STRINGS. Validated against the real game via `esmdump --mesg` (571 records: 384 message box /
// 187 notification, 354 titled, 121 buttons; PlayerWerewolfCureAreYouSure = "Werewolf Cure" with
// Yes / No). This plugin is NOT localized, so every text field is inline (the mod-ESP path).
@(test)
test_gamedb_message :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	mesg_grp := make([dynamic]u8, 0, 256);defer delete(mesg_grp)

	// 0x720: a message box with two buttons and an owning quest — the Werewolf Cure shape.
	box := make([dynamic]u8, 0, 128);defer delete(box)
	field(&box, "EDID", transmute([]u8)string("TestCureAreYouSure\x00"))
	field(&box, "DESC", transmute([]u8)string("Cure your lycanthropy forever?\x00"))
	field(&box, "FULL", transmute([]u8)string("Werewolf Cure\x00"))
	inam: [4]u8
	field(&box, "INAM", inam[:]) // icon slot; always 0 in Skyrim, and skipped by the decoder
	dnam: [4]u8;put_u32(dnam[:], 0, 1) // bit 0 = message box
	field(&box, "DNAM", dnam[:])
	qnam: [4]u8;put_u32(qnam[:], 0, 0x0000_0900)
	field(&box, "QNAM", qnam[:])
	field(&box, "ITXT", transmute([]u8)string("Yes\x00"))
	field(&box, "ITXT", transmute([]u8)string("No\x00"))
	record(&mesg_grp, "MESG", 0, 0x0000_0720, box[:])

	// 0x721: a corner notification — no buttons, no title, a display time, flags bit 0 clear.
	note := make([dynamic]u8, 0, 64);defer delete(note)
	field(&note, "EDID", transmute([]u8)string("TestNotify\x00"))
	field(&note, "DESC", transmute([]u8)string("Your stamina is low.\x00"))
	ndnam: [4]u8;put_u32(ndnam[:], 0, 2) // bit 1 = auto display, bit 0 clear = notification
	field(&note, "DNAM", ndnam[:])
	tnam: [4]u8;put_u32(tnam[:], 0, 10)
	field(&note, "TNAM", tnam[:])
	record(&mesg_grp, "MESG", 0, 0x0000_0721, note[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("MESG"), 0, mesg_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	m, ok := gamedb.message_of(&db, 0x0000_0720)
	testing.expect(t, ok, "MESG box decoded")
	testing.expect_value(t, m.title, "Werewolf Cure")
	testing.expect_value(t, m.body, "Cure your lycanthropy forever?")
	testing.expect_value(t, m.message_box, true)
	testing.expect_value(t, m.auto_display, false)
	testing.expect_value(t, m.quest, gamedb.Form_ID(0x0000_0900))
	testing.expect_value(t, len(m.buttons), 2)
	// Record order IS the return value of Message.Show, so the order has to survive.
	testing.expect_value(t, m.buttons[0], "Yes")
	testing.expect_value(t, m.buttons[1], "No")

	n, nok := gamedb.message_of(&db, 0x0000_0721)
	testing.expect(t, nok, "MESG notification decoded")
	testing.expect_value(t, n.message_box, false)
	testing.expect_value(t, n.auto_display, true)
	testing.expect_value(t, n.title, "")
	testing.expect_value(t, n.body, "Your stamina is low.")
	testing.expect_value(t, n.display_time, u32(10))
	testing.expect_value(t, len(n.buttons), 0)
	testing.expect_value(t, n.quest, gamedb.Form_ID(0))

	// A form that is not a MESG has no message.
	_, bad := gamedb.message_of(&db, 0x0000_0999)
	testing.expect(t, !bad, "unknown form has no message")
}

// PERK + AVIF perk-tree decode. Two halves: a PERK's identity and NNAM rank chain, and the
// constellation nodes that trail an AVIF's actor-value identity. Validated against the real game
// via `esmdump --perk` (375 perks / 347 playable / 42 hidden; 18 skills, 198 nodes, 195
// connections; AVOneHanded's trunk is Armsman at 5 ranks branching to Bladesman, Hack and Slash,
// Bone Breaker, Fighting Stance and Dual Flurry).
@(test)
test_gamedb_perk :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// Three PERKs forming one rank chain: A -> B -> C. Every record reports num_ranks = 1, which is
	// how the base game authors Armsman — the chain length is the real answer, not that field.
	perk_grp := make([dynamic]u8, 0, 256);defer delete(perk_grp)
	add_perk :: proc(grp: ^[dynamic]u8, formid: u32, edid, name: string, next: u32, playable, hidden: u8) {
		p := make([dynamic]u8, 0, 128);defer delete(p)
		field(&p, "EDID", transmute([]u8)strings.concatenate({edid, "\x00"}, context.temp_allocator))
		field(&p, "FULL", transmute([]u8)strings.concatenate({name, "\x00"}, context.temp_allocator))
		field(&p, "DESC", transmute([]u8)string("Swing harder.\x00"))
		field(&p, "DATA", []u8{0, 0, 1, playable, hidden}) // trait, min level, ranks, playable, hidden
		if next != 0 {
			n: [4]u8;put_u32(n[:], 0, next)
			field(&p, "NNAM", n[:])
		}
		// One entry, to prove the header DATA is taken from BEFORE the first PRKE and the 3-byte
		// entry DATA that follows is not mistaken for it.
		field(&p, "PRKE", []u8{0, 1, 0})
		field(&p, "DATA", []u8{0, 0, 0})
		field(&p, "PRKF", {})
		record(grp, "PERK", 0, formid, p[:])
	}
	add_perk(&perk_grp, 0x0000_0A01, "TestArmsman00", "Armsman", 0x0000_0A02, 1, 0)
	add_perk(&perk_grp, 0x0000_0A02, "TestArmsman20", "Armsman", 0x0000_0A03, 1, 0)
	add_perk(&perk_grp, 0x0000_0A03, "TestArmsman40", "Armsman", 0, 1, 0)
	add_perk(&perk_grp, 0x0000_0A04, "TestHelperPerk", "Helper", 0, 0, 1)

	// An AVIF skill carrying a three-node tree: a root plus two perks. The root's grid/position are
	// deliberately junk here, the way the Creation Kit leaves them, and must be zeroed on decode.
	avif := make([dynamic]u8, 0, 256);defer delete(avif)
	field(&avif, "EDID", transmute([]u8)string("AVTestSkill\x00"))
	field(&avif, "DESC", transmute([]u8)string("A test skill.\x00"))
	cn: [4]u8;put_u32(cn[:], 0, 7)
	field(&avif, "CNAM", cn[:]) // the record's OWN CNAM — must NOT become a node connection
	node :: proc(b: ^[dynamic]u8, perk, gx, gy: u32, h, v: f32, conns: []u32, index: u32) {
		t4: [4]u8
		put_u32(t4[:], 0, perk);field(b, "PNAM", t4[:])
		put_u32(t4[:], 0, 1);field(b, "FNAM", t4[:])
		put_u32(t4[:], 0, gx);field(b, "XNAM", t4[:])
		put_u32(t4[:], 0, gy);field(b, "YNAM", t4[:])
		put_f32(t4[:], 0, h);field(b, "HNAM", t4[:])
		put_f32(t4[:], 0, v);field(b, "VNAM", t4[:])
		put_u32(t4[:], 0, 0x0000_0B00);field(b, "SNAM", t4[:])
		for c in conns {
			put_u32(t4[:], 0, c);field(b, "CNAM", t4[:])
		}
		put_u32(t4[:], 0, index);field(b, "INAM", t4[:])
	}
	node(&avif, 0, 0xDEAD, 0xBEEF, 99, 99, {2}, 0) // root: junk placement, connects to node 2
	node(&avif, 0x0000_0A01, 2, 0, 0.187, -0.04, {5}, 2)
	node(&avif, 0x0000_0A04, 1, 1, -0.153, 0.52, {}, 5)
	avif_grp := make([dynamic]u8, 0, 512);defer delete(avif_grp)
	record(&avif_grp, "AVIF", 0, 0x0000_0B00, avif[:])

	out := make([dynamic]u8, 0, 1024);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("PERK"), 0, perk_grp[:])
	group(&out, transmute([]u8)string("AVIF"), 0, avif_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	testing.expect_value(t, len(db.perks), 4)
	p, ok := gamedb.perk_of(&db, 0x0000_0A01)
	testing.expect(t, ok, "PERK decoded")
	testing.expect_value(t, p.name, "Armsman")
	testing.expect_value(t, p.description, "Swing harder.")
	testing.expect_value(t, p.playable, true)
	testing.expect_value(t, p.hidden, false)
	testing.expect_value(t, p.next_rank, gamedb.Form_ID(0x0000_0A02))
	testing.expect_value(t, p.num_ranks, u8(1)) // as authored — and wrong, which is the point

	// The chain is the real rank count, and it shortens as you walk down it.
	testing.expect_value(t, gamedb.perk_ranks(&db, 0x0000_0A01), 3)
	testing.expect_value(t, gamedb.perk_ranks(&db, 0x0000_0A02), 2)
	testing.expect_value(t, gamedb.perk_ranks(&db, 0x0000_0A03), 1)
	testing.expect_value(t, gamedb.perk_ranks(&db, 0x0000_0A04), 1) // outside any chain
	testing.expect_value(t, gamedb.perk_ranks(&db, 0x0000_0FFF), 0) // unknown form

	hp, hok := gamedb.perk_of(&db, 0x0000_0A04)
	testing.expect(t, hok, "helper PERK decoded")
	testing.expect_value(t, hp.playable, false)
	testing.expect_value(t, hp.hidden, true)
	testing.expect_value(t, hp.next_rank, gamedb.Form_ID(0))

	tree := gamedb.perk_tree_of(&db, 0x0000_0B00)
	testing.expect_value(t, len(tree), 3)
	// The root keeps its connections but loses the junk placement.
	testing.expect_value(t, tree[0].perk, gamedb.Form_ID(0))
	testing.expect_value(t, tree[0].grid, [2]u32{0, 0})
	testing.expect_value(t, tree[0].pos, [2]f32{0, 0})
	testing.expect_value(t, len(tree[0].connections), 1)
	testing.expect_value(t, tree[0].connections[0], u32(2))
	// A real node keeps everything, and the record's own CNAM stayed out of it.
	testing.expect_value(t, tree[1].perk, gamedb.Form_ID(0x0000_0A01))
	testing.expect_value(t, tree[1].index, u32(2))
	testing.expect_value(t, tree[1].grid, [2]u32{2, 0})
	testing.expect_value(t, tree[1].pos, [2]f32{0.187, -0.04})
	testing.expect_value(t, len(tree[1].connections), 1)
	testing.expect_value(t, tree[1].connections[0], u32(5))
	// A leaf has no connections.
	testing.expect_value(t, tree[2].perk, gamedb.Form_ID(0x0000_0A04))
	testing.expect_value(t, tree[2].index, u32(5))
	testing.expect_value(t, len(tree[2].connections), 0)

	// An actor value that is not a skill carries no tree.
	testing.expect_value(t, len(gamedb.perk_tree_of(&db, 0x0000_0FFF)), 0)
}

// COBJ decode: CNTO ingredients, CNAM result, NAM1 yield, BNAM workbench, plus the by-bench
// grouping a crafting menu reads. Validated against the real game via `esmdump --cobj` (601
// recipes, 952 ingredient entries, 7 workbench keywords partitioning them exactly; Elsweyr Fondue
// = Eidar Cheese Wheel + Moon Sugar + Ale, Solid Dwemer Metal smelts to 5 Dwarven Ingots).
@(test)
test_gamedb_recipe :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	FORGE :: u32(0x0000_0C01)
	SMELTER :: u32(0x0000_0C02)

	cnto :: proc(b: ^[dynamic]u8, item: u32, count: i32) {
		e: [8]u8;put_u32(e[:], 0, item);put_u32(e[:], 4, transmute(u32)count)
		field(b, "CNTO", e[:])
	}
	add_cobj :: proc(grp: ^[dynamic]u8, formid: u32, edid: string, ings: [][2]u32, result: u32, bench: u32, qty: u16) {
		r := make([dynamic]u8, 0, 128);defer delete(r)
		field(&r, "EDID", transmute([]u8)strings.concatenate({edid, "\x00"}, context.temp_allocator))
		t4: [4]u8
		put_u32(t4[:], 0, u32(len(ings)));field(&r, "COCT", t4[:])
		for ing in ings {cnto(&r, ing[0], i32(ing[1]))}
		field(&r, "CTDA", make([]u8, 32, context.temp_allocator)) // a condition we deliberately skip
		if result != 0 {
			put_u32(t4[:], 0, result);field(&r, "CNAM", t4[:])
		}
		put_u32(t4[:], 0, bench);field(&r, "BNAM", t4[:])
		field(&r, "NAM1", []u8{u8(qty), u8(qty >> 8)})
		record(grp, "COBJ", 0, formid, r[:])
	}

	grp := make([dynamic]u8, 0, 512);defer delete(grp)
	add_cobj(&grp, 0x0000_0D01, "RecipeSteelIngot", {{0x0000_0E01, 1}, {0x0000_0E02, 1}}, 0x0000_0F01, FORGE, 1)
	add_cobj(&grp, 0x0000_0D02, "RecipeDwarvenIngot", {{0x0000_0E03, 1}}, 0x0000_0F02, SMELTER, 5)
	add_cobj(&grp, 0x0000_0D03, "RecipeBroken", {{0x0000_0E01, 2}}, 0, FORGE, 1) // no CNAM: makes nothing
	add_cobj(&grp, 0x0000_0D04, "RecipeFree", {}, 0x0000_0F03, FORGE, 1) // no ingredients

	out := make([dynamic]u8, 0, 1024);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("COBJ"), 0, grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	testing.expect_value(t, len(db.recipes), 4)
	r, ok := gamedb.recipe_of(&db, 0x0000_0D01)
	testing.expect(t, ok, "COBJ decoded")
	testing.expect_value(t, r.result, gamedb.Form_ID(0x0000_0F01))
	testing.expect_value(t, r.bench, gamedb.Form_ID(FORGE))
	testing.expect_value(t, r.quantity, u16(1))
	testing.expect_value(t, len(r.ingredients), 2)
	testing.expect_value(t, r.ingredients[0].item, gamedb.Form_ID(0x0000_0E01))
	testing.expect_value(t, r.ingredients[0].count, i32(1))

	// A yield above one survives, which is how the smelter works.
	d, dok := gamedb.recipe_of(&db, 0x0000_0D02)
	testing.expect(t, dok, "smelter recipe decoded")
	testing.expect_value(t, d.quantity, u16(5))

	// Both absences are real vanilla data, not decode failures.
	b, bok := gamedb.recipe_of(&db, 0x0000_0D03)
	testing.expect(t, bok, "resultless recipe still indexed")
	testing.expect_value(t, b.result, gamedb.Form_ID(0))
	f, fok := gamedb.recipe_of(&db, 0x0000_0D04)
	testing.expect(t, fok, "ingredientless recipe still indexed")
	testing.expect_value(t, len(f.ingredients), 0)

	// The by-bench grouping is what a crafting menu opens with.
	testing.expect_value(t, len(gamedb.recipes_for_bench(&db, gamedb.Form_ID(FORGE))), 3)
	testing.expect_value(t, len(gamedb.recipes_for_bench(&db, gamedb.Form_ID(SMELTER))), 1)
	testing.expect_value(t, len(gamedb.recipes_for_bench(&db, 0x0000_0FFF)), 0) // unused keyword

	_, bad := gamedb.recipe_of(&db, 0x0000_0FFF)
	testing.expect(t, !bad, "unknown form is not a recipe")
}

// A later plugin overriding a COBJ can MOVE it to another workbench. The old bench must drop it,
// or the recipe shows on both. This is the one place the by-bench index is hand-maintained.
@(test)
test_gamedb_recipe_bench_override :: proc(t: ^testing.T) {
	FORGE :: u32(0x0000_0C01)
	SMELTER :: u32(0x0000_0C02)

	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	cobj :: proc(grp: ^[dynamic]u8, formid, bench, result: u32) {
		r := make([dynamic]u8, 0, 64);defer delete(r)
		field(&r, "EDID", transmute([]u8)string("RecipeMoved\x00"))
		t4: [4]u8
		put_u32(t4[:], 0, 1);field(&r, "COCT", t4[:])
		e: [8]u8;put_u32(e[:], 0, 0x0000_0E01);put_u32(e[:], 4, 1)
		field(&r, "CNTO", e[:])
		put_u32(t4[:], 0, result);field(&r, "CNAM", t4[:])
		put_u32(t4[:], 0, bench);field(&r, "BNAM", t4[:])
		field(&r, "NAM1", []u8{1, 0})
		record(grp, "COBJ", 0, formid, r[:])
	}
	grp := make([dynamic]u8, 0, 256);defer delete(grp)
	cobj(&grp, 0x0000_0D01, FORGE, 0x0000_0F01)   // first: on the forge
	cobj(&grp, 0x0000_0D01, SMELTER, 0x0000_0F09) // same form, moved to the smelter

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("COBJ"), 0, grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	testing.expect_value(t, len(db.recipes), 1)
	r, _ := gamedb.recipe_of(&db, 0x0000_0D01)
	testing.expect_value(t, r.bench, gamedb.Form_ID(SMELTER))
	testing.expect_value(t, r.result, gamedb.Form_ID(0x0000_0F09))
	// The old bench let go, and the new one holds exactly one copy.
	testing.expect_value(t, len(gamedb.recipes_for_bench(&db, gamedb.Form_ID(FORGE))), 0)
	testing.expect_value(t, len(gamedb.recipes_for_bench(&db, gamedb.Form_ID(SMELTER))), 1)
}

// NPC_ base decode (4a item 5): ACBS stats + DNAM attributes/skills + linked race/class/voice/outfit
// forms (remapped) + SPLO spells + PKID packages + CNTO inventory + FULL name. Validated against the
// real Player 0x00000007 via `esmdump --npc` (flags 0x30, level 1, offsets 50/50/50, base 100s).
@(test)
test_gamedb_actor_base :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// NPC_ 0x800: a mini-player. ACBS (24B) + DNAM (42B) + links + 2 spells + 1 package + 2 items.
	npc := make([dynamic]u8, 0, 128);defer delete(npc)
	field(&npc, "EDID", transmute([]u8)string("TestActor\x00"))
	acbs: [24]u8
	put_u32(acbs[:], 0, esm.ACBS_ESSENTIAL | esm.ACBS_UNIQUE) // flags 0x22
	put_u16(acbs[:], 4, 50) // magicka offset
	put_u16(acbs[:], 6, 50) // stamina offset
	put_u16(acbs[:], 8, 5) // level
	put_u16(acbs[:], 10, 1) // calc min
	put_u16(acbs[:], 12, 50) // calc max
	put_u16(acbs[:], 14, 100) // speed mult
	put_u16(acbs[:], 20, 50) // health offset
	field(&npc, "ACBS", acbs[:])
	dnam: [42]u8
	dnam[0] = 20;dnam[1] = 25;dnam[2] = 15 // first three skill values
	put_u16(dnam[:], 36, 120) // base health
	put_u16(dnam[:], 38, 110) // base magicka
	put_u16(dnam[:], 40, 90) // base stamina
	field(&npc, "DNAM", dnam[:])
	field(&npc, "RNAM", u32_bytes(0x0000_0900)) // race
	field(&npc, "CNAM", u32_bytes(0x0000_0901)) // class
	field(&npc, "VTCK", u32_bytes(0x0000_0902)) // voice
	field(&npc, "DOFT", u32_bytes(0x0000_0903)) // outfit
	field(&npc, "SPLO", u32_bytes(0x0000_0910))
	field(&npc, "SPLO", u32_bytes(0x0000_0911))
	field(&npc, "PKID", u32_bytes(0x0000_0920))
	inv0: [8]u8;put_u32(inv0[:], 0, 0x0000_0930);put_u32(inv0[:], 4, 3)
	field(&npc, "CNTO", inv0[:])
	inv1: [8]u8;put_u32(inv1[:], 0, 0x0000_0931);put_u32(inv1[:], 4, 1)
	field(&npc, "CNTO", inv1[:])
	field(&npc, "FULL", transmute([]u8)string("Test Hero\x00")) // inline name (non-localized)
	npc_grp := make([dynamic]u8, 0, 256);defer delete(npc_grp)
	record(&npc_grp, "NPC_", 0, 0x0000_0800, npc[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("NPC_"), 0, npc_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	a, ok := gamedb.actor_base(&db, 0x0000_0800)
	testing.expect(t, ok, "NPC_ decoded")
	testing.expect_value(t, a.flags, u32(esm.ACBS_ESSENTIAL | esm.ACBS_UNIQUE))
	testing.expect_value(t, a.level, u16(5))
	testing.expect_value(t, a.calc_min, u16(1))
	testing.expect_value(t, a.calc_max, u16(50))
	testing.expect_value(t, a.speed_mult, u16(100))
	testing.expect_value(t, a.health_off, i16(50))
	testing.expect_value(t, a.magicka_off, i16(50))
	testing.expect_value(t, a.stamina_off, i16(50))
	testing.expect_value(t, a.base_health, u16(120))
	testing.expect_value(t, a.base_magicka, u16(110))
	testing.expect_value(t, a.base_stamina, u16(90))
	testing.expect_value(t, a.skills[0], u8(20))
	testing.expect_value(t, a.skills[1], u8(25))
	testing.expect_value(t, a.race, gamedb.Form_ID(0x0000_0900))
	testing.expect_value(t, a.class, gamedb.Form_ID(0x0000_0901))
	testing.expect_value(t, a.voice, gamedb.Form_ID(0x0000_0902))
	testing.expect_value(t, a.outfit, gamedb.Form_ID(0x0000_0903))
	testing.expect_value(t, len(a.spells), 2)
	testing.expect_value(t, a.spells[0], gamedb.Form_ID(0x0000_0910))
	testing.expect_value(t, a.spells[1], gamedb.Form_ID(0x0000_0911))
	testing.expect_value(t, len(a.packages), 1)
	testing.expect_value(t, a.packages[0], gamedb.Form_ID(0x0000_0920))
	testing.expect_value(t, len(a.inventory), 2)
	testing.expect_value(t, a.inventory[0].item, gamedb.Form_ID(0x0000_0930))
	testing.expect_value(t, a.inventory[0].count, i32(3))
	// FULL name is indexed into db.names (NPC_ is not is_base_type — index_npc does it).
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0800), "Test Hero")
	// A non-NPC form has no actor base.
	_, nok := gamedb.actor_base(&db, 0x0000_0999)
	testing.expect(t, !nok, "unknown form is not an actor")
	// No plugin holds the player ref; the DB makes it on NPC_ 0x7.
	player, pok := gamedb.ref_by_formid(&db, formid.PLAYER)
	testing.expect(t, pok && player.base == formid.PLAYER_BASE, "player ref missing")
}

// ACHR placement decode (4a item 5): an actor placement lands in actor_refs (NOT the static cell_refs),
// its base resolving to the placed NPC_ and its transform decoding like a REFR.
@(test)
test_gamedb_actor_placement :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// Minimal NPC_ base 0x0A00 (just enough to exist).
	npc := make([dynamic]u8, 0, 32);defer delete(npc)
	field(&npc, "EDID", transmute([]u8)string("Guard\x00"))
	npc_grp := make([dynamic]u8, 0, 64);defer delete(npc_grp)
	record(&npc_grp, "NPC_", 0, 0x0000_0A00, npc[:])

	// A cell with an ACHR (0x0A10) placing the NPC_.
	cell_body := make([dynamic]u8, 0, 16);defer delete(cell_body)
	field(&cell_body, "DATA", []u8{esm.CELL_INTERIOR})
	achr := make([dynamic]u8, 0, 48);defer delete(achr)
	field(&achr, "NAME", u32_bytes(0x0000_0A00)) // base = the NPC_
	adata: [24]u8;put_f32(adata[:], 0, 12.0);put_f32(adata[:], 4, 34.0);put_f32(adata[:], 8, 56.0)
	field(&achr, "DATA", adata[:])
	ac := make([dynamic]u8, 0, 64);defer delete(ac)
	record(&ac, "ACHR", 0, 0x0000_0A10, achr[:])
	ac_grup := make([dynamic]u8, 0, 96);defer delete(ac_grup)
	group(&ac_grup, u32_bytes(0x0000_0AAA), 6, ac[:])
	cell_grp := make([dynamic]u8, 0, 128);defer delete(cell_grp)
	record(&cell_grp, "CELL", 0, 0x0000_0AAA, cell_body[:])
	append(&cell_grp, ..ac_grup[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("NPC_"), 0, npc_grp[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_grp[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	actors := gamedb.actors_of(&db, 0x0000_0AAA)
	testing.expect_value(t, len(actors), 1)
	testing.expect_value(t, actors[0].form_id, gamedb.Form_ID(0x0000_0A10))
	testing.expect_value(t, actors[0].base, gamedb.Form_ID(0x0000_0A00))
	testing.expect_value(t, actors[0].pos.x, f32(12.0))
	testing.expect_value(t, actors[0].pos.z, f32(56.0))
	// The actor placement is NOT in the static ref list.
	testing.expect_value(t, len(gamedb.refs_of(&db, 0x0000_0AAA)), 0)
}

// add_top_record appends a top-level GRUP (label = the 4-char sig) holding one empty record of that
// signature — enough for form-kind indexing, which keys off the signature + formID only.
@(private = "file")
add_top_record :: proc(out: ^[dynamic]u8, sig: string, formid: u32) {
	content := make([dynamic]u8, 0, 32)
	defer delete(content)
	record(&content, sig, 0, formid, nil)
	group(out, transmute([]u8)sig, 0, content[:])
}

// QUST baseline parse: DNAM "Start Game Enabled" flag + defined stages (INDX + the following QSDT
// "Complete Quest" flag). Stage 10 (not completing), stage 20 (completing).
@(test)
test_gamedb_quest_baseline :: proc(t: ^testing.T) {
	tes4_body := make([dynamic]u8, 0, 32)
	defer delete(tes4_body)
	hedr: [12]u8
	put_f32(hedr[:], 0, 1.7)
	put_u32(hedr[:], 8, 0x0000_00FF)
	field(&tes4_body, "HEDR", hedr[:])

	// QUST body: DNAM(SGE) + stage 10 (QSDT not-complete) + stage 20 (QSDT complete).
	qbody := make([dynamic]u8, 0, 64)
	defer delete(qbody)
	dnam: [12]u8
	dnam[0] = 0x01 // Start Game Enabled
	field(&qbody, "DNAM", dnam[:])
	indx10: [4]u8
	indx10[0] = 10
	field(&qbody, "INDX", indx10[:])
	field(&qbody, "QSDT", []u8{0x00})
	field(&qbody, "CNAM", transmute([]u8)string("Enter the barrow.\x00")) // stage-10 journal log (inline)
	indx20: [4]u8
	indx20[0] = 20
	field(&qbody, "INDX", indx20[:])
	field(&qbody, "QSDT", []u8{0x01}) // Complete Quest
	// stage 20 is silent (no CNAM) — must NOT appear in stage_log.
	qobj5: [2]u8
	qobj5[0] = 5
	field(&qbody, "QOBJ", qobj5[:]) // objective 5
	field(&qbody, "NNAM", transmute([]u8)string("Find the amulet\x00")) // objective-5 display text (inline)
	qobj15: [2]u8
	qobj15[0] = 15
	field(&qbody, "QOBJ", qobj15[:]) // objective 15
	field(&qbody, "NNAM", transmute([]u8)string("Return to Golldir\x00")) // objective-15 display text (inline)

	out := make([dynamic]u8, 0, 256)
	defer delete(out)
	record(&out, "TES4", 0, 0, tes4_body[:])
	qcontent := make([dynamic]u8, 0, 96)
	defer delete(qcontent)
	record(&qcontent, "QUST", 0, 0x0000_00C0, qbody[:])
	group(&out, transmute([]u8)string("QUST"), 0, qcontent[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)
	q := gamedb.Form_ID(0x0000_00C0)
	testing.expect(t, gamedb.quest_start_game_enabled(&db, q), "SGE flag parsed")
	e10, k10 := gamedb.quest_stage_exists(&db, q, 10)
	testing.expect(t, e10 && k10, "stage 10 defined")
	e20, _ := gamedb.quest_stage_exists(&db, q, 20)
	testing.expect(t, e20, "stage 20 defined")
	e99, k99 := gamedb.quest_stage_exists(&db, q, 99)
	testing.expect(t, !e99 && k99, "stage 99 undefined but quest known")
	testing.expect(t, !gamedb.quest_stage_completes(&db, q, 10), "stage 10 does not complete")
	testing.expect(t, gamedb.quest_stage_completes(&db, q, 20), "stage 20 completes the quest")
	// Objectives (QOBJ) parsed.
	qb, qbok := gamedb.quest_baseline_of(&db, q)
	testing.expect(t, qbok, "baseline present")
	testing.expect(t, qb.objectives[5] && qb.objectives[15], "objectives 5,15 defined")
	testing.expect(t, !qb.objectives[7], "objective 7 undefined")
	// Journal DISPLAY text: stage-10 log (CNAM), objective NNAMs; silent stage 20 has no log.
	log10, l10ok := gamedb.quest_stage_log(&db, q, 10)
	testing.expect(t, l10ok && log10 == "Enter the barrow.", "stage 10 log text decoded")
	_, l20ok := gamedb.quest_stage_log(&db, q, 20)
	testing.expect(t, !l20ok, "silent stage 20 has no log entry")
	obj5, o5ok := gamedb.quest_objective_text(&db, q, 5)
	testing.expect(t, o5ok && obj5 == "Find the amulet", "objective 5 display text decoded")
	obj15, o15ok := gamedb.quest_objective_text(&db, q, 15)
	testing.expect(t, o15ok && obj15 == "Return to Golldir", "objective 15 display text decoded")
	// A quest we never parsed → not known (so callers skip validation).
	_, kUnknown := gamedb.quest_stage_exists(&db, 0x0000_0999, 0)
	testing.expect(t, !kUnknown, "unparsed quest has no baseline")
}

@(private = "file")
put_u16 :: proc(b: []u8, off: int, v: u16) {
	endian.put_u16(b[off:off + 2], .Little, v)
}

@(private = "file")
put_u32 :: proc(b: []u8, off: int, v: u32) {
	endian.put_u32(b[off:off + 4], .Little, v)
}

@(private = "file")
put_f32 :: proc(b: []u8, off: int, v: f32) {
	endian.put_u32(b[off:off + 4], .Little, transmute(u32)v)
}

// Keyword tagging + linked references — the baseline behind Form.HasKeyword and GetLinkedRef.
// Two KYWD records supply identities; a WEAP carries both as KSIZ/KWDA; a REFR links to another
// ref on the default (keyword 0) channel and on a keyword channel. Layouts validated against the
// real Skyrim.esm via `esmdump --forms`.
@(test)
test_gamedb_keywords_and_links :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0900)
	field(&tes4, "HEDR", hedr[:])

	// Two keywords. A KYWD has no FULL — its editor id is its name.
	kwds := make([dynamic]u8, 0, 128);defer delete(kwds)
	kw_a := make([dynamic]u8, 0, 32);defer delete(kw_a)
	field(&kw_a, "EDID", transmute([]u8)string("VendorItemWeapon\x00"))
	field(&kw_a, "CNAM", u32_bytes(0x0000_0043))
	record(&kwds, "KYWD", 0, 0x0000_0301, kw_a[:])
	kw_b := make([dynamic]u8, 0, 32);defer delete(kw_b)
	field(&kw_b, "EDID", transmute([]u8)string("WeapTypeMace\x00"))
	record(&kwds, "KYWD", 0, 0x0000_0302, kw_b[:])

	// A weapon tagged with both (KSIZ count + one KWDA holding the pair).
	weap := make([dynamic]u8, 0, 64);defer delete(weap)
	field(&weap, "KSIZ", u32_bytes(2))
	kwda: [8]u8;put_u32(kwda[:], 0, 0x0000_0301);put_u32(kwda[:], 4, 0x0000_0302)
	field(&weap, "KWDA", kwda[:])
	weaps := make([dynamic]u8, 0, 96);defer delete(weaps)
	record(&weaps, "WEAP", 0, 0x0000_0310, weap[:])

	// A REFR with two XLKR links: the default channel (keyword 0) and a keyword channel.
	refr := make([dynamic]u8, 0, 64);defer delete(refr)
	field(&refr, "NAME", u32_bytes(0x0000_0310))
	rdata: [24]u8;field(&refr, "DATA", rdata[:])
	lk0: [8]u8;put_u32(lk0[:], 0, 0);put_u32(lk0[:], 4, 0x0000_0402)
	field(&refr, "XLKR", lk0[:])
	lk1: [8]u8;put_u32(lk1[:], 0, 0x0000_0302);put_u32(lk1[:], 4, 0x0000_0403)
	field(&refr, "XLKR", lk1[:])

	cell_body := make([dynamic]u8, 0, 16);defer delete(cell_body)
	cd: [1]u8 = {esm.CELL_INTERIOR};field(&cell_body, "DATA", cd[:])
	children := make([dynamic]u8, 0, 128);defer delete(children)
	record(&children, "REFR", 0, 0x0000_0401, refr[:])
	cell_content := make([dynamic]u8, 0, 192);defer delete(cell_content)
	record(&cell_content, "CELL", 0, 0x0000_0400, cell_body[:])
	group(&cell_content, u32_bytes(0x0000_0400), 6, children[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("KYWD"), 0, kwds[:])
	group(&out, transmute([]u8)string("WEAP"), 0, weaps[:])
	group(&out, transmute([]u8)string("CELL"), 0, cell_content[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	// Keyword identity resolves both ways, case-insensitively.
	kw, kok := gamedb.keyword_id(&db, "vendoritemweapon")
	testing.expect(t, kok, "keyword resolves by editor id")
	testing.expect_value(t, kw, gamedb.Form_ID(0x0000_0301))
	testing.expect_value(t, gamedb.keyword_editor_id(&db, 0x0000_0302), "WeapTypeMace")

	testing.expect_value(t, len(gamedb.keywords_of(&db, 0x0000_0310)), 2)
	testing.expect(t, gamedb.has_keyword(&db, 0x0000_0310, 0x0000_0301), "weapon carries VendorItemWeapon")
	testing.expect(t, gamedb.has_keyword(&db, 0x0000_0310, 0x0000_0302), "weapon carries WeapTypeMace")
	testing.expect(t, !gamedb.has_keyword(&db, 0x0000_0310, 0x0000_0399), "unknown keyword absent")
	testing.expect(t, !gamedb.has_keyword(nil, 0x0000_0310, 0x0000_0301), "nil DB safe")

	// The default link is keyword 0; a keyword selects its own channel.
	def, dok := gamedb.linked_ref(&db, 0x0000_0401)
	testing.expect(t, dok, "default linked ref")
	testing.expect_value(t, def, gamedb.Form_ID(0x0000_0402))
	tagged, tok := gamedb.linked_ref(&db, 0x0000_0401, 0x0000_0302)
	testing.expect(t, tok, "keyword-channel linked ref")
	testing.expect_value(t, tagged, gamedb.Form_ID(0x0000_0403))
	_, missing := gamedb.linked_ref(&db, 0x0000_0401, 0x0000_0301)
	testing.expect(t, !missing, "no link on an unused keyword channel")
	testing.expect_value(t, len(gamedb.linked_refs_of(&db, 0x0000_0401)), 2)
}

// FACT baseline + NPC_ membership: DATA flags, an XNAM relation, the CRVA crime table, and the
// RNAM/MNAM rank ladder (an ORDERED walk — MNAM titles the preceding RNAM). The NPC_'s SNAM rows
// are the authored memberships IsInFaction answers from before any script joins/leaves. Layouts
// validated against Skyrim.esm (CrimeFactionWhiterun's bounties, the College's rank titles).
@(test)
test_gamedb_faction :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0A00)
	field(&tes4, "HEDR", hedr[:])

	fact := make([dynamic]u8, 0, 128);defer delete(fact)
	field(&fact, "EDID", transmute([]u8)string("TestGuild\x00"))
	field(&fact, "FULL", transmute([]u8)string("Test Guild\x00")) // inline: the plugin isn't localized
	xnam: [12]u8
	put_u32(xnam[:], 0, 0x0000_0502) // the other faction
	put_u32(xnam[:], 4, transmute(u32)i32(-25)) // disposition modifier
	put_u32(xnam[:], 8, u32(esm.Combat_Reaction.Enemy))
	field(&fact, "XNAM", xnam[:])
	field(&fact, "DATA", u32_bytes(esm.FACT_TRACK_CRIME))
	crva: [20]u8
	crva[0] = 1 // arrest
	crva[1] = 0 // attack on detect
	put_u16(crva[:], 2, 1000) // murder
	put_u16(crva[:], 4, 40) // assault
	put_u16(crva[:], 6, 5) // trespass
	put_u16(crva[:], 8, 25) // pickpocket
	put_f32(crva[:], 12, 0.5) // steal multiplier
	put_u16(crva[:], 16, 100) // escape
	put_u16(crva[:], 18, 1000) // werewolf
	field(&fact, "CRVA", crva[:])
	field(&fact, "RNAM", u32_bytes(0))
	field(&fact, "MNAM", transmute([]u8)string("Novice\x00"))
	field(&fact, "RNAM", u32_bytes(1))
	field(&fact, "MNAM", transmute([]u8)string("Master\x00"))
	field(&fact, "FNAM", transmute([]u8)string("Mistress\x00"))
	facts := make([dynamic]u8, 0, 192);defer delete(facts)
	record(&facts, "FACT", 0, 0x0000_0501, fact[:])

	// An NPC_ holding rank 1 in it (SNAM = faction formID + rank i8 + 3 unused).
	npc := make([dynamic]u8, 0, 64);defer delete(npc)
	snam: [8]u8;put_u32(snam[:], 0, 0x0000_0501);snam[4] = 1
	field(&npc, "SNAM", snam[:])
	npcs := make([dynamic]u8, 0, 96);defer delete(npcs)
	record(&npcs, "NPC_", 0, 0x0000_0510, npc[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("FACT"), 0, facts[:])
	group(&out, transmute([]u8)string("NPC_"), 0, npcs[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	f, fok := gamedb.faction_of(&db, 0x0000_0501)
	testing.expect(t, fok, "faction indexed")
	testing.expect_value(t, f.flags, u32(esm.FACT_TRACK_CRIME))
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0501), "Test Guild")

	testing.expect(t, f.has_crime, "crime values present")
	testing.expect_value(t, f.crime.murder, u16(1000))
	testing.expect_value(t, f.crime.assault, u16(40))
	testing.expect_value(t, f.crime.trespass, u16(5))
	testing.expect_value(t, f.crime.pickpocket, u16(25))
	testing.expect_value(t, f.crime.steal_multiplier, f32(0.5))
	testing.expect_value(t, f.crime.werewolf, u16(1000))
	testing.expect(t, f.crime.arrest, "arrests rather than attacking")
	testing.expect(t, !f.crime.attack_on_detect, "does not attack on detect")

	reaction, modifier, rok := gamedb.faction_reaction(&db, 0x0000_0501, 0x0000_0502)
	testing.expect(t, rok, "relation authored")
	testing.expect_value(t, reaction, esm.Combat_Reaction.Enemy)
	testing.expect_value(t, modifier, i32(-25))
	_, _, none := gamedb.faction_reaction(&db, 0x0000_0501, 0x0000_0599)
	testing.expect(t, !none, "no relation to an unrelated faction")

	// Each MNAM/FNAM titles the rank its preceding RNAM opened.
	testing.expect_value(t, len(f.ranks), 2)
	novice, n0 := gamedb.faction_rank_title(&db, 0x0000_0501, 0)
	testing.expect(t, n0, "rank 0 titled")
	testing.expect_value(t, novice, "Novice")
	master, n1 := gamedb.faction_rank_title(&db, 0x0000_0501, 1)
	testing.expect(t, n1, "rank 1 titled")
	testing.expect_value(t, master, "Master")
	mistress, n1f := gamedb.faction_rank_title(&db, 0x0000_0501, 1, female = true)
	testing.expect(t, n1f, "rank 1 female title")
	testing.expect_value(t, mistress, "Mistress")
	// Rank 0 has no female title — fall back to the male column rather than reporting none.
	fallback, n0f := gamedb.faction_rank_title(&db, 0x0000_0501, 0, female = true)
	testing.expect(t, n0f, "female lookup falls back")
	testing.expect_value(t, fallback, "Novice")

	rank, mok := gamedb.actor_faction_rank(&db, 0x0000_0510, 0x0000_0501)
	testing.expect(t, mok, "actor is an authored member")
	testing.expect_value(t, rank, i8(1))
	_, notmember := gamedb.actor_faction_rank(&db, 0x0000_0510, 0x0000_0502)
	testing.expect(t, !notmember, "not a member of the other faction")
}

// The magic records: an MGEF's DATA archetype/actor-value block, a SPEL's SPIT cast parameters +
// its EFID/EFIT effect list, and an ENCH's ENIT. Offsets validated against Skyrim.esm — every
// "…FFAimedArea" MGEF reads cast type Fire_And_Forget / delivery Aimed, paralysis reads archetype
// 21, and Frost Breath decodes as Concentration/Aimed with two effects.
@(test)
test_gamedb_magic :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0B00)
	field(&tes4, "HEDR", hedr[:])

	// Two magic effects: a cheap one and an expensive one (so "costliest" has an answer).
	mgefs := make([dynamic]u8, 0, 512);defer delete(mgefs)
	mgef_data :: proc(base_cost: f32, archetype: esm.Effect_Archetype, primary_av: i32) -> [152]u8 {
		d: [152]u8
		put_u32(d[:], 0, esm.MGEF_DETRIMENTAL)
		put_f32(d[:], 4, base_cost)
		put_u32(d[:], 12, transmute(u32)i32(20)) // magic skill (an AV index — Destruction)
		put_u32(d[:], 16, transmute(u32)esm.AV_NONE)
		put_u32(d[:], 64, u32(archetype))
		put_u32(d[:], 68, transmute(u32)primary_av)
		put_u32(d[:], 80, u32(esm.Cast_Type.Fire_And_Forget))
		put_u32(d[:], 84, u32(esm.Delivery.Aimed))
		return d
	}
	cheap := make([dynamic]u8, 0, 256);defer delete(cheap)
	field(&cheap, "FULL", transmute([]u8)string("Slow\x00"))
	field(&cheap, "DNAM", transmute([]u8)string("Movement is <mag> percent slower.\x00"))
	cd := mgef_data(2, .Peak_Value_Modifier, 53)
	field(&cheap, "DATA", cd[:])
	record(&mgefs, "MGEF", 0, 0x0000_0601, cheap[:])
	dear := make([dynamic]u8, 0, 256);defer delete(dear)
	field(&dear, "FULL", transmute([]u8)string("Frostbite\x00"))
	dd := mgef_data(40, .Dual_Value_Modifier, 24)
	field(&dear, "DATA", dd[:])
	mctda: [32]u8;put_u32(mctda[:], 8, 448)
	field(&dear, "CTDA", mctda[:])
	record(&mgefs, "MGEF", 0, 0x0000_0602, dear[:])

	// A spell applying both, cheap effect first (so the costliest index isn't trivially 0).
	spel := make([dynamic]u8, 0, 128);defer delete(spel)
	field(&spel, "FULL", transmute([]u8)string("Frost Breath\x00"))
	spit: [36]u8
	put_u32(spit[:], 0, 322) // cost
	put_u32(spit[:], 8, u32(esm.Spell_Type.Spell))
	put_f32(spit[:], 12, 0.5) // charge time
	put_u32(spit[:], 16, u32(esm.Cast_Type.Concentration))
	put_u32(spit[:], 20, u32(esm.Delivery.Aimed))
	put_f32(spit[:], 28, 4096) // range
	put_u32(spit[:], 32, 0x0000_0650) // half-cost perk
	field(&spel, "SPIT", spit[:])
	field(&spel, "EFID", u32_bytes(0x0000_0601))
	ef0: [12]u8;put_f32(ef0[:], 0, 50);put_u32(ef0[:], 8, 5)
	field(&spel, "EFIT", ef0[:])
	field(&spel, "EFID", u32_bytes(0x0000_0602))
	ef1: [12]u8;put_f32(ef1[:], 0, 20);put_u32(ef1[:], 8, 1)
	field(&spel, "EFIT", ef1[:])
	ctda: [32]u8;put_u32(ctda[:], 8, 448)
	field(&spel, "CTDA", ctda[:]) // the second effect's condition
	spels := make([dynamic]u8, 0, 192);defer delete(spels)
	record(&spels, "SPEL", 0, 0x0000_0610, spel[:])

	// An enchantment carrying one effect.
	ench := make([dynamic]u8, 0, 128);defer delete(ench)
	enit: [36]u8
	put_u32(enit[:], 0, 3161) // cost
	put_u32(enit[:], 8, u32(esm.Cast_Type.Constant_Effect))
	put_u32(enit[:], 12, 3161) // charge amount
	put_u32(enit[:], 16, u32(esm.Delivery.Self))
	put_u32(enit[:], 20, u32(esm.Enchant_Type.Enchantment))
	put_u32(enit[:], 28, 0x0000_0660) // base enchantment
	field(&ench, "ENIT", enit[:])
	field(&ench, "EFID", u32_bytes(0x0000_0601))
	ef2: [12]u8;put_f32(ef2[:], 0, 15)
	field(&ench, "EFIT", ef2[:])
	enchs := make([dynamic]u8, 0, 192);defer delete(enchs)
	record(&enchs, "ENCH", 0, 0x0000_0620, ench[:])

	out := make([dynamic]u8, 0, 1024);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("MGEF"), 0, mgefs[:])
	group(&out, transmute([]u8)string("SPEL"), 0, spels[:])
	group(&out, transmute([]u8)string("ENCH"), 0, enchs[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	me, meok := gamedb.magic_effect_of(&db, 0x0000_0601)
	testing.expect(t, meok, "magic effect indexed")
	testing.expect_value(t, me.info.archetype, esm.Effect_Archetype.Peak_Value_Modifier)
	testing.expect_value(t, me.info.primary_av, i32(53))
	testing.expect_value(t, me.info.resist_av, esm.AV_NONE)
	testing.expect_value(t, me.info.cast_type, esm.Cast_Type.Fire_And_Forget)
	testing.expect_value(t, me.info.delivery, esm.Delivery.Aimed)
	testing.expect_value(t, me.info.flags, u32(esm.MGEF_DETRIMENTAL))
	testing.expect_value(t, me.description, "Movement is <mag> percent slower.")
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0601), "Slow")

	sp, spok := gamedb.spell_of(&db, 0x0000_0610)
	testing.expect(t, spok, "spell indexed")
	testing.expect(t, !sp.scroll, "a SPEL is not a scroll")
	testing.expect_value(t, sp.info.cost, u32(322))
	testing.expect_value(t, sp.info.type, esm.Spell_Type.Spell)
	testing.expect_value(t, sp.info.cast_type, esm.Cast_Type.Concentration)
	testing.expect_value(t, sp.info.delivery, esm.Delivery.Aimed)
	testing.expect_value(t, sp.info.range, f32(4096))
	testing.expect_value(t, sp.half_cost_perk, gamedb.Form_ID(0x0000_0650))
	testing.expect_value(t, len(sp.effects), 2)
	testing.expect_value(t, sp.effects[0].effect, gamedb.Form_ID(0x0000_0601))
	testing.expect_value(t, sp.effects[0].magnitude, f32(50))
	testing.expect_value(t, sp.effects[0].duration, u32(5))
	testing.expect_value(t, sp.effects[1].effect, gamedb.Form_ID(0x0000_0602))
	testing.expect(t, len(sp.effects[0].conditions) == 0 && len(sp.effects[1].conditions) == 1, "a CTDA belongs to the effect before it")
	dear_me, _ := gamedb.magic_effect_of(&db, 0x0000_0602)
	testing.expect_value(t, len(dear_me.conditions), 1)

	// Effect 1 costs 40 base at magnitude 20 — well past effect 0's 2 base at magnitude 50.
	costliest, cok := gamedb.spell_costliest_effect(&db, 0x0000_0610)
	testing.expect(t, cok, "costliest effect resolves")
	testing.expect_value(t, costliest, 1)
	_, unknown := gamedb.spell_costliest_effect(&db, 0x0000_0699)
	testing.expect(t, !unknown, "unknown spell has no costliest effect")

	e, eok := gamedb.enchantment_of(&db, 0x0000_0620)
	testing.expect(t, eok, "enchantment indexed")
	testing.expect_value(t, e.info.cost, u32(3161))
	testing.expect_value(t, e.info.cast_type, esm.Cast_Type.Constant_Effect)
	testing.expect_value(t, e.info.type, esm.Enchant_Type.Enchantment)
	testing.expect_value(t, e.base_enchantment, gamedb.Form_ID(0x0000_0660))
	testing.expect_value(t, len(e.effects), 1)
	testing.expect_value(t, e.effects[0].magnitude, f32(15))
}

// QUST alias slots: each runs ALST/ALLS → ALED, and the fill subrecords between name HOW the
// quest engine finds the reference. Only a Forced (ALFR) fill resolves statically. Field order
// carries the grouping — an objective's FNAM earlier in the record must not leak into an alias.
// Fill kinds validated against Skyrim.esm (MQ Dragon Rising: Unique_Actor NPCs, Create_Ref
// soldiers, "Player" forced to 0x14).
@(test)
test_gamedb_quest_aliases :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0C00)
	field(&tes4, "HEDR", hedr[:])

	qust := make([dynamic]u8, 0, 256);defer delete(qust)
	dnam: [12]u8;dnam[0] = 0x01 // start game enabled
	field(&qust, "DNAM", dnam[:])
	// An objective FIRST — its FNAM shares the tag with an alias's flags and must not leak in.
	obj: [2]u8;put_u16(obj[:], 0, 10);field(&qust, "QOBJ", obj[:])
	field(&qust, "FNAM", u32_bytes(0xDEAD_BEEF))
	field(&qust, "NNAM", transmute([]u8)string("Find the dragon\x00"))
	field(&qust, "ANAM", u32_bytes(3)) // next alias id

	field(&qust, "ALST", u32_bytes(0)) // alias 0: pinned to a specific ref
	field(&qust, "ALID", transmute([]u8)string("Player\x00"))
	field(&qust, "FNAM", u32_bytes(0x0000_0002))
	field(&qust, "ALFR", u32_bytes(0x0000_0014))
	field(&qust, "ALED", nil)

	field(&qust, "ALST", u32_bytes(1)) // alias 1: a unique actor, filled at quest start
	field(&qust, "ALID", transmute([]u8)string("Balgruuf\x00"))
	field(&qust, "ALUA", u32_bytes(0x0000_0701))
	field(&qust, "ALED", nil)

	field(&qust, "ALLS", u32_bytes(2)) // alias 2: a LOCATION alias with no fill
	field(&qust, "ALID", transmute([]u8)string("Hold\x00"))
	field(&qust, "ALED", nil)

	qusts := make([dynamic]u8, 0, 320);defer delete(qusts)
	record(&qusts, "QUST", 0, 0x0000_0700, qust[:])

	out := make([dynamic]u8, 0, 512);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("QUST"), 0, qusts[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	aliases := gamedb.quest_aliases_of(&db, 0x0000_0700)
	testing.expect_value(t, len(aliases), 3)

	player, pok := gamedb.quest_alias(&db, 0x0000_0700, 0)
	testing.expect(t, pok, "alias 0 defined")
	testing.expect_value(t, player.name, "Player")
	testing.expect_value(t, player.fill, esm.Alias_Fill.Forced)
	testing.expect_value(t, player.target, gamedb.Form_ID(0x0000_0014))
	testing.expect_value(t, player.flags, u32(0x0000_0002)) // its OWN FNAM, not the objective's
	testing.expect(t, !player.location, "a reference alias")

	ref, fok := gamedb.quest_alias_forced_ref(&db, 0x0000_0700, 0)
	testing.expect(t, fok, "forced ref resolves statically")
	testing.expect_value(t, ref, gamedb.Form_ID(0x0000_0014))

	jarl, jok := gamedb.quest_alias(&db, 0x0000_0700, 1)
	testing.expect(t, jok, "alias 1 defined")
	testing.expect_value(t, jarl.fill, esm.Alias_Fill.Unique_Actor)
	testing.expect_value(t, jarl.target, gamedb.Form_ID(0x0000_0701))
	_, notforced := gamedb.quest_alias_forced_ref(&db, 0x0000_0700, 1)
	testing.expect(t, !notforced, "a Unique_Actor fill is filled at runtime, not statically")

	hold, hok := gamedb.quest_alias(&db, 0x0000_0700, 2)
	testing.expect(t, hok, "alias 2 defined")
	testing.expect(t, hold.location, "a location alias")
	testing.expect_value(t, hold.fill, esm.Alias_Fill.None)
	testing.expect_value(t, hold.name, "Hold")

	_, missing := gamedb.quest_alias(&db, 0x0000_0700, 9)
	testing.expect(t, !missing, "undefined alias id")
	testing.expect_value(t, len(gamedb.quest_aliases_of(&db, 0x0000_0799)), 0) // unknown quest
}

// Actor identity: the records an NPC_ links out to. Before these were indexed, Actor_Base's
// race/class/voice/outfit were remapped FormIDs pointing at nothing. Also covers LVLN routing
// into the shared leveled-list table (LVLD/LVLF/LVLO — the same shape as LVLI/LVSP). Layouts
// validated against Skyrim.esm via `esmdump --forms`.
@(test)
test_gamedb_actor_identity :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0D00)
	field(&tes4, "HEDR", hedr[:])

	// RACE 0x801: Conjuration(19) +10, Illusion(21) +5, then the 0xFF terminator.
	race := make([dynamic]u8, 0, 256);defer delete(race)
	field(&race, "FULL", transmute([]u8)string("Breton\x00"))
	rd: [164]u8
	rd[0] = 19;rd[1] = 10
	rd[2] = 21;rd[3] = 5
	rd[4] = esm.RACE_SKILL_NONE
	for i in 5 ..< 14 {rd[i] = esm.RACE_SKILL_NONE if i % 2 == 0 else 0}
	put_f32(rd[:], 16, 1.0);put_f32(rd[:], 20, 0.95) // height M/F
	put_f32(rd[:], 24, 1.0);put_f32(rd[:], 28, 1.0) // weight M/F
	field(&race, "DATA", rd[:])
	races := make([dynamic]u8, 0, 320);defer delete(races)
	record(&races, "RACE", 0, 0x0000_0801, race[:])

	// CLAS 0x802: trains skill 20 to level 75, favours health over stamina.
	clas := make([dynamic]u8, 0, 64);defer delete(clas)
	cd: [36]u8
	cd[4] = 20;cd[5] = 75 // training skill + level
	cd[6] = 3;cd[7] = 1 // first two skill weights
	put_f32(cd[:], 24, 0.1) // bleedout default
	cd[32] = 3;cd[33] = 0;cd[34] = 2 // health / magicka / stamina weights
	field(&clas, "DATA", cd[:])
	clases := make([dynamic]u8, 0, 96);defer delete(clases)
	record(&clases, "CLAS", 0, 0x0000_0802, clas[:])

	// VTYP 0x803: a female voice type.
	vtyp := make([dynamic]u8, 0, 32);defer delete(vtyp)
	vd: [1]u8 = {esm.VTYP_FEMALE | esm.VTYP_ALLOW_DEFAULT_DIALOGUE}
	field(&vtyp, "DNAM", vd[:])
	vtyps := make([dynamic]u8, 0, 64);defer delete(vtyps)
	record(&vtyps, "VTYP", 0, 0x0000_0803, vtyp[:])

	// OTFT 0x804: one INAM packing two items (not one field per item).
	otft := make([dynamic]u8, 0, 32);defer delete(otft)
	od: [8]u8;put_u32(od[:], 0, 0x0000_0810);put_u32(od[:], 4, 0x0000_0811)
	field(&otft, "INAM", od[:])
	otfts := make([dynamic]u8, 0, 64);defer delete(otfts)
	record(&otfts, "OTFT", 0, 0x0000_0804, otft[:])

	// LVLN 0x805: the leveled-list shape, so it must land in leveled_lists.
	lvln := make([dynamic]u8, 0, 64);defer delete(lvln)
	ld: [1]u8 = {10};field(&lvln, "LVLD", ld[:])
	lf: [1]u8 = {esm.LVLI_CALC_FROM_ALL_LEVELS};field(&lvln, "LVLF", lf[:])
	lo: [12]u8;put_u16(lo[:], 0, 5);put_u32(lo[:], 4, 0x0000_0812);put_u16(lo[:], 8, 1)
	field(&lvln, "LVLO", lo[:])
	lvlns := make([dynamic]u8, 0, 96);defer delete(lvlns)
	record(&lvlns, "LVLN", 0, 0x0000_0805, lvln[:])

	// An NPC_ wiring all four links together.
	npc := make([dynamic]u8, 0, 64);defer delete(npc)
	field(&npc, "RNAM", u32_bytes(0x0000_0801))
	field(&npc, "CNAM", u32_bytes(0x0000_0802))
	field(&npc, "VTCK", u32_bytes(0x0000_0803))
	field(&npc, "DOFT", u32_bytes(0x0000_0804))
	npcs := make([dynamic]u8, 0, 96);defer delete(npcs)
	record(&npcs, "NPC_", 0, 0x0000_0820, npc[:])

	out := make([dynamic]u8, 0, 1024);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("RACE"), 0, races[:])
	group(&out, transmute([]u8)string("CLAS"), 0, clases[:])
	group(&out, transmute([]u8)string("VTYP"), 0, vtyps[:])
	group(&out, transmute([]u8)string("OTFT"), 0, otfts[:])
	group(&out, transmute([]u8)string("LVLN"), 0, lvlns[:])
	group(&out, transmute([]u8)string("NPC_"), 0, npcs[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	r, rok := gamedb.race_of(&db, 0x0000_0801)
	testing.expect(t, rok, "race indexed")
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0801), "Breton")
	testing.expect_value(t, r.info.bonus_count, 2) // the 0xFF terminator stops the count
	testing.expect_value(t, r.info.bonuses[0].skill, u8(19))
	testing.expect_value(t, r.info.bonuses[0].bonus, u8(10))
	testing.expect_value(t, r.info.height_female, f32(0.95))

	c, cok := gamedb.class_of(&db, 0x0000_0802)
	testing.expect(t, cok, "class indexed")
	testing.expect_value(t, c.info.training_skill, u8(20))
	testing.expect_value(t, c.info.training_level, u8(75))
	testing.expect_value(t, c.info.health_weight, u8(3))
	testing.expect_value(t, c.info.stamina_weight, u8(2))
	testing.expect_value(t, c.info.bleedout_default, f32(0.1))

	vf, vok := gamedb.voice_type_flags(&db, 0x0000_0803)
	testing.expect(t, vok, "voice type indexed")
	testing.expect(t, vf & esm.VTYP_FEMALE != 0, "a female voice type")

	gear := gamedb.outfit_items(&db, 0x0000_0804)
	testing.expect_value(t, len(gear), 2) // one packed INAM, two items
	testing.expect_value(t, gear[0], gamedb.Form_ID(0x0000_0810))
	testing.expect_value(t, gear[1], gamedb.Form_ID(0x0000_0811))

	// LVLN shares the leveled-list table with LVLI/LVSP.
	ll, llok := gamedb.leveled_list_of(&db, 0x0000_0805)
	testing.expect(t, llok, "LVLN indexed as a leveled list")
	testing.expect_value(t, ll.chance_none, u8(10))
	testing.expect_value(t, len(ll.entries), 1)
	testing.expect_value(t, ll.entries[0].form, gamedb.Form_ID(0x0000_0812))

	// The NPC_'s links now resolve to real records rather than dangling.
	a, aok := gamedb.actor_base(&db, 0x0000_0820)
	testing.expect(t, aok, "actor indexed")
	testing.expect_value(t, a.race, gamedb.Form_ID(0x0000_0801))
	testing.expect_value(t, a.outfit, gamedb.Form_ID(0x0000_0804))
	bonuses, n := gamedb.actor_race_bonuses(&db, 0x0000_0820)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, bonuses[0].bonus, u8(10))
	testing.expect_value(t, len(gamedb.actor_outfit_items(&db, 0x0000_0820)), 2)
}

// AVIF: the actor-value bridge. MGEF/RACE/CLAS cite actor values by ENGINE INDEX while
// worldstate keys its store by lower-case NAME — this joins them. The index comes from four
// formID blocks DERIVED from Skyrim.esm (not file order, not one offset), so the fixture uses
// the real base-game formIDs. Index 21 is the known trap: it's Illusion everywhere in the game,
// but its record is still called AVMysticism.
@(test)
test_gamedb_actor_values :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0E00)
	field(&tes4, "HEDR", hedr[:])

	avifs := make([dynamic]u8, 0, 512);defer delete(avifs)
	add_avif :: proc(out: ^[dynamic]u8, formid: u32, edid: string, full: string) {
		body := make([dynamic]u8, 0, 64)
		defer delete(body)
		field(&body, "EDID", transmute([]u8)edid)
		if full != "" {
			field(&body, "FULL", transmute([]u8)full)
		}
		record(out, "AVIF", 0, formid, body[:])
	}
	add_avif(&avifs, 0x0000_03E8, "AVHealth\x00", "Health\x00") // block 3 → index 24
	add_avif(&avifs, 0x0000_04B0, "AVAggression\x00", "") // block 1 → index 0
	add_avif(&avifs, 0x0000_0458, "AVAlteration\x00", "Alteration\x00") // block 2 → index 18
	add_avif(&avifs, 0x0000_045B, "AVMysticism\x00", "Illusion\x00") // block 2 → index 21
	add_avif(&avifs, 0x0000_05DC, "AVParalysis\x00", "") // block 4 → index 53
	add_avif(&avifs, 0x0000_064A, "AVReflectDamage\x00", "") // block 4 → index 163, the last AV

	out := make([dynamic]u8, 0, 768);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("AVIF"), 0, avifs[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	// Index derivation: each block starts at a different enum position.
	check :: proc(t: ^testing.T, db: ^gamedb.DB, index: i32, form: gamedb.Form_ID) {
		got, ok := gamedb.actor_value_by_index(db, index)
		testing.expect(t, ok, "actor value index resolves")
		testing.expect_value(t, got, form)
	}
	check(t, &db, 0, 0x0000_04B0)
	check(t, &db, 18, 0x0000_0458)
	check(t, &db, 24, 0x0000_03E8)
	check(t, &db, 53, 0x0000_05DC)
	check(t, &db, 163, 0x0000_064A)
	check(t, &db, 21, 0x0000_045B) // AVMysticism is Illusion
	_, missing := gamedb.actor_value_by_index(&db, 37) // 37 VoicePoints has no AVIF record
	testing.expect(t, !missing, "an index with no AVIF record has no form")

	// Display name prefers FULL, else the engine's name.
	disp, _ := gamedb.actor_value_display(&db, 24)
	testing.expect_value(t, disp, "Health")
	fallback, _ := gamedb.actor_value_display(&db, 53)
	testing.expect_value(t, fallback, "Paralysis")

	// Names come from the engine table, any case, and cover indices with no record.
	Case :: struct {name, want: string}
	for c in ([]Case{{"illusion", "Illusion"}, {"variable04", "Variable04"}, {"HEALTH", "Health"}}) {
		got, ok := gamedb.actor_value_name(c.name)
		testing.expect(t, ok && got == c.want, c.name)
	}
	_, unknown := gamedb.actor_value_name("Mysticism")
	testing.expect(t, !unknown, "an AVIF editor id is not a name")
}

// LCTN + WTHR — the last two records that `base_class()` gave a Papyrus class without any data
// behind it. Location covers the parent tree IsChild walks; Weather covers the DATA
// classification, FNAM fog, the VARIABLE-length NAM0 colour table and the per-time imagespaces.
// Colour row indices were read off SkyrimClear_A: Stars is white only at night, Sunlight is warm
// at sunrise/sunset.
@(test)
test_gamedb_location_and_weather :: proc(t: ^testing.T) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0F00)
	field(&tes4, "HEDR", hedr[:])

	// A three-deep location chain: house → town → hold.
	lctns := make([dynamic]u8, 0, 384);defer delete(lctns)
	add_lctn :: proc(out: ^[dynamic]u8, formid: u32, name: string, parent: u32) {
		body := make([dynamic]u8, 0, 64)
		defer delete(body)
		field(&body, "FULL", transmute([]u8)name)
		if parent != 0 {
			field(&body, "PNAM", u32_bytes(parent))
		}
		field(&body, "CNAM", u32_bytes(0x00FF_FF00))
		record(out, "LCTN", 0, formid, body[:])
	}
	add_lctn(&lctns, 0x0000_0901, "Whiterun Hold\x00", 0)
	add_lctn(&lctns, 0x0000_0902, "Whiterun\x00", 0x0000_0901)
	add_lctn(&lctns, 0x0000_0903, "Breezehome\x00", 0x0000_0902)

	// A weather: cloudy, with fog, a full 17-row colour table and 4 imagespaces.
	wthr := make([dynamic]u8, 0, 512);defer delete(wthr)
	wd: [19]u8
	wd[0] = 5 // wind speed
	wd[4] = 128 // sun glare
	wd[11] = esm.WTHR_CLOUDY | esm.WTHR_PERMANENT_AURORA
	field(&wthr, "DATA", wd[:])
	fn: [32]u8
	put_f32(fn[:], 4, 22500) // day far
	put_f32(fn[:], 12, 22500) // night far
	put_f32(fn[:], 24, 0.9) // day max
	field(&wthr, "FNAM", fn[:])
	nam0: [esm.WTHR_COLOR_ROWS_MAX * esm.WTHR_TIMES * 4]u8
	set_color :: proc(b: []u8, row, time: int, c: [4]u8) {
		off := (row * esm.WTHR_TIMES + time) * 4
		for v, i in c {
			b[off + i] = v
		}
	}
	set_color(nam0[:], esm.WTHR_COLOR_SUNLIGHT, 1, {163, 150, 135, 0}) // warm white at noon
	set_color(nam0[:], esm.WTHR_COLOR_SUNLIGHT, 0, {182, 112, 95, 0}) // orange at sunrise
	set_color(nam0[:], esm.WTHR_COLOR_STARS, 3, {255, 255, 255, 0}) // white only at night
	set_color(nam0[:], esm.WTHR_COLOR_AMBIENT, 1, {170, 192, 197, 0})
	field(&wthr, "NAM0", nam0[:])
	imsp: [16]u8
	for i in 0 ..< 4 {put_u32(imsp[:], i * 4, u32(0x0000_0A10 + i))}
	field(&wthr, "IMSP", imsp[:])
	wthrs := make([dynamic]u8, 0, 640);defer delete(wthrs)
	record(&wthrs, "WTHR", 0, 0x0000_0910, wthr[:])

	out := make([dynamic]u8, 0, 1280);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("LCTN"), 0, lctns[:])
	group(&out, transmute([]u8)string("WTHR"), 0, wthrs[:])

	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	// Locations: name, parent link, marker colour, and the tree walk.
	l, lok := gamedb.location_of(&db, 0x0000_0903)
	testing.expect(t, lok, "location indexed")
	testing.expect_value(t, gamedb.name_of(&db, 0x0000_0903), "Breezehome")
	testing.expect_value(t, l.parent, gamedb.Form_ID(0x0000_0902))
	testing.expect(t, l.has_marker_color, "map marker tint present")
	testing.expect(t, gamedb.location_is_child(&db, 0x0000_0903, 0x0000_0902), "direct parent")
	testing.expect(t, gamedb.location_is_child(&db, 0x0000_0903, 0x0000_0901), "grandparent")
	testing.expect(t, !gamedb.location_is_child(&db, 0x0000_0901, 0x0000_0903), "not upward")
	testing.expect(t, !gamedb.location_is_child(&db, 0x0000_0903, 0x0000_0903), "not its own child")
	root, rok := gamedb.location_of(&db, 0x0000_0901)
	testing.expect(t, rok, "root location indexed")
	testing.expect_value(t, root.parent, gamedb.Form_ID(0))

	// Weather: classification, fog, colours, imagespaces.
	w, wok := gamedb.weather_of(&db, 0x0000_0910)
	testing.expect(t, wok, "weather indexed")
	testing.expect_value(t, gamedb.weather_classification(&db, 0x0000_0910), gamedb.Weather_Class.Cloudy)
	testing.expect_value(t, w.info.wind_speed, u8(5))
	testing.expect_value(t, w.info.sun_glare, u8(128))
	testing.expect(t, w.info.flags & esm.WTHR_PERMANENT_AURORA != 0, "aurora bit survives")
	testing.expect(t, w.has_fog, "fog present")
	testing.expect_value(t, w.fog.day_far, f32(22500))
	testing.expect_value(t, w.fog.day_max, f32(0.9))
	testing.expect_value(t, w.color_rows, esm.WTHR_COLOR_ROWS_MAX)

	noon_sun, sok := gamedb.weather_color(&db, 0x0000_0910, esm.WTHR_COLOR_SUNLIGHT, 1)
	testing.expect(t, sok, "noon sunlight colour")
	testing.expect_value(t, noon_sun[0], u8(163))
	night_stars, nok := gamedb.weather_color(&db, 0x0000_0910, esm.WTHR_COLOR_STARS, 3)
	testing.expect(t, nok, "night stars colour")
	testing.expect_value(t, night_stars[0], u8(255))
	// Reading past the authored rows / times must fail rather than return garbage.
	_, past := gamedb.weather_color(&db, 0x0000_0910, esm.WTHR_COLOR_ROWS_MAX, 0)
	testing.expect(t, !past, "row past the table")
	_, bad_time := gamedb.weather_color(&db, 0x0000_0910, 0, esm.WTHR_TIMES)
	testing.expect(t, !bad_time, "time past the table")

	testing.expect_value(t, w.imagespaces[0], gamedb.Form_ID(0x0000_0A10))
	testing.expect_value(t, w.imagespaces[3], gamedb.Form_ID(0x0000_0A13))
}

// --- VMAD (records_scripts.odin) ---
//
// Synthetic, like the rest of this file: the REAL proof is `esmdump --vmad`, which decodes every
// VMAD in the user's own plugins and must report failed=0. These guard the branches that corpus
// run would not catch if one were broken — the objFormat-1 field order (only 6 records in 1,326
// mod plugins use it), the pre-version-4 layout with no status bytes, and a truncated field.

@(private = "file")
vm_put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	t: [2]u8
	endian.put_u16(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
vm_put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
vm_put_f32 :: proc(b: ^[dynamic]u8, v: f32) {vm_put_u32(b, transmute(u32)v)}

// A VMAD string: u16 length then the bytes, with NO terminator.
@(private = "file")
vm_put_str :: proc(b: ^[dynamic]u8, s: string) {
	vm_put_u16(b, u16(len(s)))
	append(b, ..transmute([]u8)s)
}

// An 8-byte object value, written in whichever field order objFormat selects.
@(private = "file")
vm_put_obj :: proc(b: ^[dynamic]u8, obj_format: i16, form: u32, alias: i16) {
	if obj_format == 1 {
		vm_put_u32(b, form)
		vm_put_u16(b, u16(alias))
		vm_put_u16(b, 0)
	} else {
		vm_put_u16(b, 0)
		vm_put_u16(b, u16(alias))
		vm_put_u32(b, form)
	}
}

// decode_vmad wants the record's field list, so wrap the VMAD bytes in one.
@(private = "file")
vm_decode :: proc(
	rec_type: string,
	vmad: []u8,
	fm: ^esm.Form_Map = nil,
) -> (
	esm.Form_Scripts,
	bool,
) {
	body := make([dynamic]u8, 0, len(vmad) + 8, context.temp_allocator)
	field(&body, "VMAD", vmad)
	fl, _, ok := esm.fields(esm.Record{type = rec_type, data = body[:]}, context.temp_allocator)
	if !ok {
		return {}, false
	}
	return esm.decode_vmad(rec_type, fl, fm)
}

@(test)
test_esm_vmad_properties :: proc(t: ^testing.T) {
	v := make([dynamic]u8, 0, 128, context.temp_allocator)
	vm_put_u16(&v, 5) // version
	vm_put_u16(&v, 2) // objFormat
	vm_put_u16(&v, 1) // scriptCount
	vm_put_str(&v, "TrapBearScript")
	append(&v, 0) // status: declared on this record
	vm_put_u16(&v, 6) // propCount

	vm_put_str(&v, "Target");append(&v, u8(1), u8(1));vm_put_obj(&v, 2, 0x0001_2345, -1)
	vm_put_str(&v, "Label");append(&v, u8(2), u8(1));vm_put_str(&v, "north gate")
	vm_put_str(&v, "Charges");append(&v, u8(3), u8(1));vm_put_u32(&v, 3)
	vm_put_str(&v, "Delay");append(&v, u8(4), u8(1));vm_put_f32(&v, 1.5)
	vm_put_str(&v, "Armed");append(&v, u8(5), u8(1));append(&v, 1)
	vm_put_str(&v, "Levels");append(&v, u8(13), u8(1))
	vm_put_u32(&v, 3) // array count
	vm_put_u32(&v, 10);vm_put_u32(&v, 20);vm_put_u32(&v, 30)

	fs, ok := vm_decode("ACTI", v[:])
	testing.expect(t, ok, "decode VMAD")
	defer esm.free_form_scripts(fs)

	testing.expect_value(t, len(fs.scripts), 1)
	s := fs.scripts[0]
	testing.expect_value(t, s.name, "TrapBearScript")
	testing.expect(t, !esm.script_attach_removed(s), "status 0 is not a removal")
	testing.expect_value(t, len(s.props), 6)

	testing.expect_value(t, s.props[0].kind, esm.Prop_Kind.Object)
	obj := s.props[0].value.(esm.Prop_Object)
	testing.expect_value(t, obj.form, esm.Form_ID(0x0001_2345))
	testing.expect_value(t, obj.alias, i16(-1)) // names the form directly

	testing.expect_value(t, s.props[1].value.(string), "north gate")
	testing.expect_value(t, s.props[2].value.(i32), i32(3))
	testing.expect_value(t, s.props[3].value.(f32), f32(1.5))
	testing.expect_value(t, s.props[4].value.(bool), true)

	levels := s.props[5].value.([]i32)
	testing.expect_value(t, len(levels), 3)
	testing.expect_value(t, levels[0], i32(10))
	testing.expect_value(t, levels[2], i32(30))
}

// objFormat 1 puts the formID FIRST and objFormat 2 puts it last. Both must land on the same
// form, or every property on a format-1 record silently points at the wrong thing.
@(test)
test_esm_vmad_object_formats :: proc(t: ^testing.T) {
	build :: proc(obj_format: i16) -> []u8 {
		v := make([dynamic]u8, 0, 64, context.temp_allocator)
		vm_put_u16(&v, 5)
		vm_put_u16(&v, u16(obj_format))
		vm_put_u16(&v, 1)
		vm_put_str(&v, "S")
		append(&v, 0)
		vm_put_u16(&v, 1)
		vm_put_str(&v, "Ref");append(&v, u8(1), u8(1))
		vm_put_obj(&v, obj_format, 0x0004_00FF, 7)
		return v[:]
	}

	for format in ([]i16{1, 2}) {
		fs, ok := vm_decode("ACTI", build(format))
		testing.expect(t, ok, "decode VMAD")
		defer esm.free_form_scripts(fs)

		obj := fs.scripts[0].props[0].value.(esm.Prop_Object)
		testing.expect_value(t, obj.form, esm.Form_ID(0x0004_00FF))
		testing.expect_value(t, obj.alias, i16(7))
	}
}

// Before version 4 there is no status byte on a script or a property. Reading one anyway shifts
// every following byte, so this is the branch that must not rot.
@(test)
test_esm_vmad_version_below_4 :: proc(t: ^testing.T) {
	v := make([dynamic]u8, 0, 64, context.temp_allocator)
	vm_put_u16(&v, 2) // version 2: no status bytes anywhere
	vm_put_u16(&v, 1)
	vm_put_u16(&v, 1)
	vm_put_str(&v, "OldScript")
	vm_put_u16(&v, 1) // propCount — straight after the name
	vm_put_str(&v, "Count");append(&v, 3) // kind, and no status byte
	vm_put_u32(&v, 42)

	fs, ok := vm_decode("ACTI", v[:])
	testing.expect(t, ok, "decode a version-2 VMAD")
	defer esm.free_form_scripts(fs)

	testing.expect_value(t, fs.scripts[0].name, "OldScript")
	testing.expect_value(t, fs.scripts[0].props[0].name, "Count")
	testing.expect_value(t, fs.scripts[0].props[0].value.(i32), i32(42))
}

// A quest carries its stage fragments and its per-alias scripts after the script list. The alias
// block restates its own version and objFormat, so it is decoded on its own terms.
@(test)
test_esm_vmad_quest_fragments :: proc(t: ^testing.T) {
	v := make([dynamic]u8, 0, 128, context.temp_allocator)
	vm_put_u16(&v, 5)
	vm_put_u16(&v, 2)
	vm_put_u16(&v, 1)
	vm_put_str(&v, "MQ101QuestScript")
	append(&v, 0)
	vm_put_u16(&v, 0) // no properties

	// fragment tail: QUST names its file AFTER the count
	append(&v, 2) // fragment-block version
	vm_put_u16(&v, 2) // fragmentCount
	vm_put_str(&v, "QF_MQ101_0003372B")
	vm_put_u16(&v, 10);vm_put_u16(&v, 0);vm_put_u32(&v, 0) // stage 10, unknown, log entry
	append(&v, 1);vm_put_str(&v, "QF_MQ101_0003372B");vm_put_str(&v, "Fragment_0")
	vm_put_u16(&v, 20);vm_put_u16(&v, 0);vm_put_u32(&v, 0)
	append(&v, 1);vm_put_str(&v, "QF_MQ101_0003372B");vm_put_str(&v, "Fragment_3")

	vm_put_u16(&v, 1) // aliasCount
	vm_put_obj(&v, 2, 0x0003_372B, 4) // owner: this quest, alias id 4
	vm_put_u16(&v, 5) // the alias block's own version …
	vm_put_u16(&v, 2) // … and its own objFormat
	vm_put_u16(&v, 1) // one script on the alias
	vm_put_str(&v, "MQ101PlayerAliasScript")
	append(&v, 0)
	vm_put_u16(&v, 0)

	fs, ok := vm_decode("QUST", v[:])
	testing.expect(t, ok, "decode a QUST VMAD")
	defer esm.free_form_scripts(fs)

	testing.expect_value(t, fs.frag_file, "QF_MQ101_0003372B")
	testing.expect_value(t, len(fs.fragments), 2)
	testing.expect_value(t, fs.fragments[0].index, u16(10)) // the quest STAGE
	testing.expect_value(t, fs.fragments[0].function, "Fragment_0")
	testing.expect_value(t, fs.fragments[1].index, u16(20))
	testing.expect_value(t, fs.fragments[1].function, "Fragment_3")

	testing.expect_value(t, len(fs.aliases), 1)
	testing.expect_value(t, fs.aliases[0].owner.alias, i16(4))
	testing.expect_value(t, len(fs.aliases[0].scripts), 1)
	testing.expect_value(t, fs.aliases[0].scripts[0].name, "MQ101PlayerAliasScript")
}

// A script a placed reference marks REMOVED (status 3) drops what it would inherit from its base
// form. Nothing else in the record distinguishes it, so the status byte has to survive decoding.
@(test)
test_esm_vmad_removed_attachment :: proc(t: ^testing.T) {
	v := make([dynamic]u8, 0, 32, context.temp_allocator)
	vm_put_u16(&v, 5)
	vm_put_u16(&v, 2)
	vm_put_u16(&v, 1)
	vm_put_str(&v, "defaultDisableHavokOnLoad")
	append(&v, 3) // inherited from the base form, removed here
	vm_put_u16(&v, 0)

	fs, ok := vm_decode("REFR", v[:])
	testing.expect(t, ok, "decode VMAD")
	defer esm.free_form_scripts(fs)
	testing.expect(t, esm.script_attach_removed(fs.scripts[0]), "status 3 is a removal")
}

// Truncation must fail cleanly rather than read past the field or hand back a half-built result.
@(test)
test_esm_vmad_truncated :: proc(t: ^testing.T) {
	v := make([dynamic]u8, 0, 32, context.temp_allocator)
	vm_put_u16(&v, 5)
	vm_put_u16(&v, 2)
	vm_put_u16(&v, 2) // claims two scripts …
	vm_put_str(&v, "First")
	append(&v, 0)
	vm_put_u16(&v, 0) // … and then stops

	_, ok := vm_decode("ACTI", v[:])
	testing.expect(t, !ok, "a truncated VMAD fails to decode")

	// A count no remaining byte could satisfy must be rejected before it is allocated for.
	big := make([dynamic]u8, 0, 32, context.temp_allocator)
	vm_put_u16(&big, 5)
	vm_put_u16(&big, 2)
	vm_put_u16(&big, 1)
	vm_put_str(&big, "S")
	append(&big, 0)
	vm_put_u16(&big, 1)
	vm_put_str(&big, "Huge");append(&big, u8(13), u8(1))
	vm_put_u32(&big, 0xFFFF_FFF0) // an array of four billion ints

	_, big_ok := vm_decode("ACTI", big[:])
	testing.expect(t, !big_ok, "an impossible array count is rejected")
}

// Object properties are FormIDs and must remap into global space like every other ref, or a
// script handed a property from a mod plugin would address the wrong plugin's form.
@(test)
test_esm_vmad_remaps_forms :: proc(t: ^testing.T) {
	v := make([dynamic]u8, 0, 64, context.temp_allocator)
	vm_put_u16(&v, 5)
	vm_put_u16(&v, 2)
	vm_put_u16(&v, 1)
	vm_put_str(&v, "S")
	append(&v, 0)
	vm_put_u16(&v, 1)
	vm_put_str(&v, "Ref");append(&v, u8(1), u8(1))
	vm_put_obj(&v, 2, 0x0100_0042, -1) // master index 1, local form 0x42

	fm: esm.Form_Map
	fm.slot[1] = 9 // that master sits in global slot 9
	fs, ok := vm_decode("ACTI", v[:], &fm)
	testing.expect(t, ok, "decode VMAD")
	defer esm.free_form_scripts(fs)

	obj := fs.scripts[0].props[0].value.(esm.Prop_Object)
	testing.expect_value(t, obj.form, esm.Form_ID(9) << 32 | 0x42)
}

// A ref that inherits a script and changes one property keeps the base form's other values
// (DLC1VQ06ReadingTriggerScript: the base declares 20, the ref only the one it changes).
@(test)
test_effective_scripts_merge_props :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.form_scripts)
	BASE, REF :: gamedb.Form_ID(0x10), gamedb.Form_ID(0x11)
	db.form_scripts[BASE] = {scripts = []esm.Script_Attach{{name = "Trigger", props = {{name = "Sound", value = i32(1)}, {name = "Quest", value = i32(2)}}}}}
	db.form_scripts[REF] = {scripts = []esm.Script_Attach{{name = "trigger", status = 1, props = {{name = "SOUND", value = i32(9)}}}}}

	got := gamedb.effective_scripts(&db, REF, BASE, context.temp_allocator)
	testing.expect_value(t, len(got), 1)
	testing.expect_value(t, len(got[0].props), 2)
	for p in got[0].props {
		want := i32(9) if strings.equal_fold(p.name, "sound") else i32(2)
		testing.expect_value(t, p.value.(i32), want)
	}
}

// Armor slots read from BOD2 or LE's BODT; an EQUP lists its parent slots and whether it takes all.
@(test)
test_equip_decode :: proc(t: ^testing.T) {
	mask, ok := esm.biped_slots([]esm.Field{{type = "BODT", data = {0x04, 0, 0, 0, 1, 0, 0, 0}}})
	testing.expect(t, ok && mask == 0x04, "BODT slot mask")
	parents, all := esm.equip_type([]esm.Field{{type = "PNAM", data = {0x43, 0x3F, 1, 0, 0x42, 0x3F, 1, 0}}, {type = "DATA", data = {1, 0, 0, 0}}}, context.temp_allocator)
	testing.expect(t, all && len(parents) == 2 && parents[0] == 0x13F43 && parents[1] == 0x13F42, "BothHands")
}
