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
	testing.expect_value(t, a.health_off, u16(50))
	testing.expect_value(t, a.magicka_off, u16(50))
	testing.expect_value(t, a.stamina_off, u16(50))
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
