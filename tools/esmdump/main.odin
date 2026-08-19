package main

// Dev harness (not shipped): point the ESM parser / gamedb at a REAL plugin to
// validate them against ground truth — the only meaningful test for these formats
// (synthetic fixtures only prove self-consistency). Prints structural metadata only
// (counts, editor ids, formIDs, mesh paths) — never copyrighted record contents
// beyond the asset paths we already surface.
//
//   odin run tools/esmdump -- <plugin.esm>                  # header + index summary
//   odin run tools/esmdump -- <plugin.esm> --rectypes       # record-type histogram
//   odin run tools/esmdump -- <plugin.esm> --cells <substr> # interior cells matching
//   odin run tools/esmdump -- <plugin.esm> --cell <edid>    # one cell's placed refs
//   odin run tools/esmdump -- <plugin.esm> --forms [edid]   # keyword/link/faction/magic/alias survey
//   odin run tools/esmdump -- <plugin.esm> --gmst [substr] # game-setting (GMST) survey
//   odin run tools/esmdump -- <plugin.esm> --mesg [substr] # message (MESG) survey
//   odin run tools/esmdump -- <plugin.esm> --perk [skill] # perk records + AVIF perk-tree survey
//   odin run tools/esmdump -- <plugin.esm> --cobj [bench] # crafting recipe (COBJ) survey
//   odin run tools/esmdump -- <plugin.esm> --worlds         # worldspace survey (cells/refs/land)
//   odin run tools/esmdump -- <plugin.esm> --world <edid>   # one worldspace's tallies
//   odin run tools/esmdump -- <plugin.esm> --world-load <edid> # raw-walk ref→model resolution
//   odin run tools/esmdump -- <plugin.esm> --gw <edid>      # gamedb-path worldspace resolution
//   odin run tools/esmdump -- <plugin.esm> --terrain <edid> <gx> <gy> # one cell's LAND height stats
//   odin run tools/esmdump -- <Data-dir>  --loadorder      # resolve+build the WHOLE load order
//
// No SDL — pure formats/gamedb code, runs headless.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "../../src/formats/dds"
import "../../src/formats/esm"
import "../../src/formats/nif"
import "../../src/gamedb"
import "../../src/vfs"

// Form_ID is the global form handle (= gamedb.Form_ID = u64).
Form_ID :: gamedb.Form_ID

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: esmdump <plugin.esm> [--rectypes | --cells <substr> | --cell <edid>]")
		os.exit(2)
	}
	path := os.args[1]

	// --loadorder mode takes a Data DIRECTORY (not a single plugin): enumerate every
	// .esm/.esp, resolve the load order, and build one DB with all FormIDs remapped into
	// global space — the multi-master path, validated against the real install.
	if len(os.args) >= 3 && os.args[2] == "--loadorder" {
		loadorder_mode(path)
		return
	}

	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("failed to read: %s", path)
		os.exit(1)
	}
	defer delete(data)
	fmt.printfln("plugin: %s (%d bytes)", path, len(data))

	h, hok := esm.parse_header(data)
	if !hok {
		fmt.eprintln("TES4 header parse FAILED")
		os.exit(1)
	}
	defer esm.destroy_header(&h)
	fmt.printfln("masters: %v   next_object_id: 0x%08X", h.masters, h.next_object_id)

	if len(os.args) >= 3 && os.args[2] == "--rectypes" {
		rectypes(data)
		return
	}

	db := gamedb.build(data)
	defer gamedb.destroy(&db)
	interior := 0
	for _, c in db.cells {
		if c.interior {interior += 1}
	}
	fmt.printfln(
		"indexed: %d cells (%d interior), %d base-form models",
		len(db.cells),
		interior,
		len(db.base_models),
	)

	if len(os.args) >= 3 && os.args[2] == "--gmst" {
		filter := len(os.args) >= 4 ? os.args[3] : ""
		gmst_survey(path, filter)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--mesg" {
		filter := len(os.args) >= 4 ? os.args[3] : ""
		mesg_survey(path, filter)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--perk" {
		filter := len(os.args) >= 4 ? os.args[3] : ""
		perk_survey(path, filter)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--cobj" {
		filter := len(os.args) >= 4 ? os.args[3] : ""
		cobj_survey(path, filter)
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--cells" {
		list_cells(&db, os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--cell" {
		dump_cell(&db, os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--cell-load" {
		cell_load(&db, filepath.dir(path), os.args[3])
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--worlds" {
		worlds(data)
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--world" {
		world_detail(data, os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--world-load" {
		world_load(&db, data, os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--gw" {
		gamedb_world(&db, os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--world-meshes" {
		world_meshes(&db, filepath.dir(path), os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--densest" {
		densest(&db, os.args[3])
		return
	}
	if len(os.args) >= 6 && os.args[2] == "--cellmodels" {
		gx, _ := strconv.parse_int(os.args[4])
		gy, _ := strconv.parse_int(os.args[5])
		cell_models(&db, os.args[3], i32(gx), i32(gy))
		return
	}
	if len(os.args) >= 6 && os.args[2] == "--stream-test" {
		gx, _ := strconv.parse_int(os.args[4])
		gy, _ := strconv.parse_int(os.args[5])
		stream_test(&db, filepath.dir(path), os.args[3], i32(gx), i32(gy))
		return
	}
	if len(os.args) >= 6 && os.args[2] == "--terrain" {
		gx, _ := strconv.parse_int(os.args[4])
		gy, _ := strconv.parse_int(os.args[5])
		terrain(&db, filepath.dir(path), os.args[3], i32(gx), i32(gy))
		return
	}
	if len(os.args) >= 6 && os.args[2] == "--grass" {
		gx, _ := strconv.parse_int(os.args[4])
		gy, _ := strconv.parse_int(os.args[5])
		grass(&db, filepath.dir(path), os.args[3], i32(gx), i32(gy))
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--grasses" {
		grasses_survey(&db)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--lexaudit" {
		lexaudit(&db, filepath.dir(path))
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--rec" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		dump_record(data, Form_ID(want))
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--items" {
		items_mode(data, os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--contents" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		contents_mode(data, Form_ID(want))
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--flst" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		flst_mode(data, Form_ID(want))
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--lvli" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		lvli_mode(data, Form_ID(want))
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--quest" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		quest_mode(data, Form_ID(want), path)
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--glob" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		glob_mode(data, Form_ID(want))
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--npc" {
		want, _ := strconv.parse_u64(os.args[3], 16)
		npc_mode(data, Form_ID(want))
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--imgs" {
		filter := os.args[3] if len(os.args) >= 4 else ""
		imagespaces(data, filter)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--lscr" {
		lscr_mode(data, path)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--forms" {
		sdb := build_with_strings(data, path)
		defer gamedb.destroy(&sdb)
		forms_mode(&sdb, os.args[3] if len(os.args) >= 4 else "")
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--locks" {
		sdb := build_with_strings(data, path)
		defer gamedb.destroy(&sdb)
		locks_mode(&sdb)
		return
	}
	if len(os.args) >= 3 && os.args[2] == "--cellnames" {
		sdb := build_with_strings(data, path)
		defer gamedb.destroy(&sdb)
		cellnames_mode(&sdb, os.args[3] if len(os.args) >= 4 else "")
		return
	}
	if len(os.args) >= 5 && os.args[2] == "--cellfind" {
		cell, ok := gamedb.find_cell(&db, os.args[3])
		if !ok {fmt.eprintfln("cell not found: %s", os.args[3]);return}
		sub := strings.to_lower(os.args[4], context.temp_allocator)
		for r in gamedb.refs_of(&db, cell.form_id) {
			model, _ := gamedb.model_of(&db, r.base)
			if !strings.contains(strings.to_lower(model, context.temp_allocator), sub) {
				continue
			}
			fmt.printfln(
				"  base=0x%08X  is_door=%v  pos=(%.0f,%.0f,%.0f) disabled=%v has_tp=%v  %q",
				r.base,
				gamedb.is_door(&db, r.base),
				r.pos.x, r.pos.y, r.pos.z,
				r.disabled, r.has_tp,
				model,
			)
		}
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--extent" {
		wfid, ok := gamedb.find_world(&db, os.args[3])
		if !ok {fmt.eprintfln("no world %s", os.args[3]);return}
		min_gx, min_gy, max_gx, max_gy := max(i32), max(i32), min(i32), min(i32)
		n, withland := 0, 0
		for cid in gamedb.cells_of(&db, wfid) {
			if c, cok := gamedb.cell_by_formid(&db, cid); cok && c.has_grid {
				n += 1
				min_gx, min_gy = min(min_gx, c.gx), min(min_gy, c.gy)
				max_gx, max_gy = max(max_gx, c.gx), max(max_gy, c.gy)
				if _, hok := gamedb.cell_terrain(&db, cid); hok {withland += 1}
			}
		}
		bw := (int(max_gx - min_gx) / 32 + 1)
		bh := (int(max_gy - min_gy) / 32 + 1)
		fmt.printfln(
			"%s: %d grid cells (%d with LAND), gx[%d..%d] gy[%d..%d] → far-terrain blocks %dx%d = %d",
			os.args[3], n, withland, min_gx, max_gx, min_gy, max_gy, bw, bh, bw * bh,
		)
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--findmodels" {
		sub := strings.to_lower(os.args[3], context.temp_allocator)
		seen := make(map[string]bool)
		defer delete(seen)
		for fid, m in db.base_models {
			lm := strings.to_lower(m, context.temp_allocator)
			if strings.contains(lm, sub) && !seen[m] {
				seen[m] = true
				door := "  [DOOR]" if gamedb.is_door(&db, fid) else ""
				fmt.printfln("  0x%08X  %s%s", fid, m, door)
			}
		}
		fmt.printfln("(%d distinct base models contain %q)", len(seen), os.args[3])
		return
	}
	if len(os.args) >= 4 && os.args[2] == "--water" {
		water(&db, os.args[3])
		return
	}
	if len(os.args) >= 6 && os.args[2] == "--objlod" {
		gx, _ := strconv.parse_int(os.args[4])
		gy, _ := strconv.parse_int(os.args[5])
		objlod(&db, os.args[3], i32(gx), i32(gy))
		return
	}
}

// objlod reports, for one exterior cell, how many statics survive the object-LOD size
// cull at each LOD ring + the distinct-model count (= instanced draw calls) — a headless
// check on OBND sizing + the cull thresholds + the per-cell draw cost (no GPU).
objlod :: proc(db: ^gamedb.DB, edid: string, gx, gy: i32) {
	MIN := [4]f32{0, 60, 150, 350} // mirrors world.OBJ_MIN_RADIUS (lod 0/1/2/3)
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	cid, cok := gamedb.cell_at(db, wfid, gx, gy)
	if !cok {
		fmt.eprintfln("no cell at (%d,%d)", gx, gy)
		return
	}
	refs := gamedb.refs_of(db, cid)
	with_model, with_obnd := 0, 0
	for r in refs {
		if r.disabled {
			continue
		}
		if m, mok := gamedb.model_of(db, r.base); mok && m != "" {
			with_model += 1
		}
		if gamedb.base_size(db, r.base) > 0 {
			with_obnd += 1
		}
	}
	fmt.printfln("cell 0x%08X (%d,%d): %d refs, %d with model, %d with OBND", cid, gx, gy, len(refs), with_model, with_obnd)
	for lod in 1 ..= 3 {
		kept := make(map[string]int, 64, context.temp_allocator)
		defer delete(kept)
		n := 0
		for r in refs {
			if r.disabled {
				continue
			}
			modl, mok := gamedb.model_of(db, r.base)
			if !mok || modl == "" {
				continue
			}
			if gamedb.base_size(db, r.base) * r.scale < MIN[lod] {
				continue
			}
			kept[modl] += 1
			n += 1
		}
		fmt.printfln("  lod %d (min radius %.0f): %d objects kept, %d distinct models (= draws/cell)", lod, MIN[lod], n, len(kept))
	}
}

// water surveys a worldspace's resolved per-cell water: how many cells carry water, the
// height distribution (so the ocean's shared default vs custom river/lake heights show),
// and how many would actually DRAW a plane (terrain dips below the height) vs are culled —
// the headless check on the gamedb decode + the visibility cull before the GPU water pass.
water :: proc(db: ^gamedb.DB, edid: string) {
	HEIGHT_SCALE :: f32(8)
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	cells := 0
	with_water, would_draw, culled, no_land, absurd := 0, 0, 0, 0, 0
	wmin, wmax := max(f32), min(f32)
	heights := make(map[int]int) // rounded water height -> cell count
	defer delete(heights)
	for cid in gamedb.cells_of(db, wfid) {
		c, cok := gamedb.cell_by_formid(db, cid)
		if !cok || !c.has_grid {
			continue
		}
		cells += 1
		wh, hok := gamedb.cell_water(db, cid)
		if !hok {
			continue
		}
		with_water += 1
		// Outlier guard: a real Skyrim water height is within terrain Z range (~±60k). A
		// value far outside that is a non-sentinel placeholder that would float a plane in
		// the sky — flag it so the renderer can ignore it.
		if abs(wh) > 1e6 {
			absurd += 1
		}
		heights[int(wh)] += 1
		wmin, wmax = min(wmin, wh), max(wmax, wh)
		if th, tok := gamedb.cell_terrain(db, cid); tok {
			tmin := max(f32)
			for v in th {
				tmin = min(tmin, v * HEIGHT_SCALE)
			}
			if wh > tmin {would_draw += 1} else {culled += 1}
		} else {
			no_land += 1
		}
	}
	fmt.printfln("water survey %s (0x%08X): %d grid cells", edid, wfid, cells)
	def, dok := db.world_water[wfid]
	fmt.printfln("  worldspace default water height: %.1f (present=%v)", def, dok)
	fmt.printfln(
		"  %d cells have water; would DRAW %d, culled (terrain above) %d, no-land %d, ABSURD(|z|>1e6) %d",
		with_water, would_draw, culled, no_land, absurd,
	)
	fmt.printfln("  resolved height range: %.1f .. %.1f", wmin, wmax)
	// Show the most common heights (the ocean default dominates; rivers/lakes are the tail).
	Pair :: struct {
		h: int,
		n: int,
	}
	pairs := make([dynamic]Pair, 0, len(heights), context.temp_allocator)
	for h, n in heights {append(&pairs, Pair{h, n})}
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.n > b.n})
	fmt.printfln("  distinct water heights: %d (top 12 by cell count)", len(pairs))
	for p, i in pairs {
		if i >= 12 {break}
		fmt.printfln("    z=%d\t%d cells", p.h, p.n)
	}
}

// imagespaces walks every IMGS record and prints its decoded tone/color params (saturation,
// brightness, contrast, white, sun/sky scale, tint). With a non-empty `filter`, records whose
// EDID contains it ALSO dump the raw DNAM float array (index:value) — to validate the field
// offsets against real data (decode-and-eyeball, the project's record-validation workflow).
imagespaces :: proc(data: []u8, filter: string) {
	Ctx :: struct {
		filter: string,
		n:      int,
	}
	ctx := Ctx{filter, 0}
	fmt.println("formID     EDID                         sat   bright contr  white  sun    sky    tintA  tint")
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		if esm.sig(rec) != "IMGS" {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return true
		}
		defer {delete(fl);if backing != nil {delete(backing)}}
		edid := esm.editor_id(fl)
		if im, dok := esm.decode_imagespace(fl); dok {
			c.n += 1
			fmt.printfln(
				"0x%08X %-28s %.3f %.3f %.3f %.3f %.3f %.3f %.3f (%.2f,%.2f,%.2f)",
				rec.form_id, edid, im.saturation, im.brightness, im.contrast, im.hdr_white,
				im.sunlight_scale, im.sky_scale, im.tint_amount,
				im.tint_color.x, im.tint_color.y, im.tint_color.z,
			)
		}
		// Raw DNAM float dump for the filtered record(s) — offset validation.
		if c.filter != "" && strings.contains(strings.to_lower(edid, context.temp_allocator), strings.to_lower(c.filter, context.temp_allocator)) {
			fmt.printfln("  raw float dump for %s:", edid)
			for tag in ([?]string{"HNAM", "CNAM", "TNAM", "DNAM"}) {
				if f, fok := esm.find_field(fl, tag); fok {
					fmt.printf("    %s (%d bytes):", tag, len(f.data))
					for off := 0; off + 4 <= len(f.data); off += 4 {
						fmt.printf(" [%d]%g", off / 4, esm_rf32(f.data, off))
					}
					fmt.println()
				}
			}
		}
		return true
	}, &ctx)
	fmt.printfln("(%d imagespaces decoded)", ctx.n)
}

// dump_record walks to a record by formID and prints its field signatures + small/string
// values — for diagnosing an odd record (e.g. an LTEX with no resolvable diffuse).
// items_mode walks the plugin and prints editor id / value / weight for every record of a given
// type (WEAP/ARMO/ALCH/…), validating item_value_weight against the real game. Metadata only —
// no FULL name text (that's localized/copyrighted), just the decoded numbers + editor ids.
items_mode :: proc(data: []u8, want_type: string) {
	Ctx :: struct {
		want:            string,
		count:           int,
		min_v, max_v:    i32,
		min_w, max_w:    f32,
		shown:           int,
	}
	ctx := Ctx{want = want_type, min_v = max(i32), max_v = min(i32), min_w = max(f32), max_w = min(f32)}
	fmt.printfln("items of type %s (editor id : value / weight):", want_type)
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		if esm.sig(rec) != c.want {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return true
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		value, weight, vok := esm.item_value_weight(rec.type, fl)
		if !vok {
			return true
		}
		c.count += 1
		c.min_v = min(c.min_v, value); c.max_v = max(c.max_v, value)
		c.min_w = min(c.min_w, weight); c.max_w = max(c.max_w, weight)
		if c.shown < 40 { // a sample — enough to eyeball known items, not the whole table
			fmt.printfln("  0x%08X %-28s : %d / %.2f", rec.form_id, esm.editor_id(fl), value, weight)
			c.shown += 1
		}
		return true
	}, &ctx)
	if ctx.count == 0 {
		fmt.printfln("(no valued items of type %s)", want_type)
		return
	}
	fmt.printfln("%d items; value [%d..%d], weight [%.2f..%.2f]", ctx.count, ctx.min_v, ctx.max_v, ctx.min_w, ctx.max_w)
}

// contents_mode prints a container's (CONT) CNTO baseline inventory — each item's editor id x
// count — validating container_contents against the real game. One walk builds a formID→editor-id
// map (so item refs resolve to readable ids) and captures the target's raw contents; then prints.
contents_mode :: proc(data: []u8, want: Form_ID) {
	Ctx :: struct {
		want:     Form_ID,
		edids:    map[Form_ID]string, // formID -> editor id (temp-owned)
		items:    []esm.Content_Item, // the target's raw CNTO entries
		cont_ed:  string,
		found:    bool,
	}
	ctx := Ctx{want = want, edids = make(map[Form_ID]string, 4096, context.temp_allocator)}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return true
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		if ed := esm.editor_id(fl); ed != "" {
			c.edids[rec.form_id] = strings.clone(ed, context.temp_allocator)
		}
		if rec.form_id == c.want && esm.sig(rec) == "CONT" {
			c.found = true
			c.cont_ed = strings.clone(esm.editor_id(fl), context.temp_allocator)
			c.items = esm.container_contents(fl, context.temp_allocator)
		}
		return true
	}, &ctx)
	if !ctx.found {
		fmt.printfln("container 0x%08X not found (or not a CONT)", want)
		return
	}
	fmt.printfln("container 0x%08X %q — %d item entries:", want, ctx.cont_ed, len(ctx.items))
	for it in ctx.items {
		ed := ctx.edids[Form_ID(it.item)] or_else "?"
		fmt.printfln("  %5d x 0x%08X %s", it.count, it.item, ed)
	}
}

flst_mode :: proc(data: []u8, want: Form_ID) {
	Ctx :: struct {
		want:    Form_ID,
		edids:   map[Form_ID]string, // formID -> editor id (temp-owned)
		members: []u32, // the target's raw LNAM member formIDs
		flst_ed: string,
		found:   bool,
	}
	ctx := Ctx{want = want, edids = make(map[Form_ID]string, 8192, context.temp_allocator)}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return true
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		if ed := esm.editor_id(fl); ed != "" {
			c.edids[rec.form_id] = strings.clone(ed, context.temp_allocator)
		}
		if rec.form_id == c.want && esm.sig(rec) == "FLST" {
			c.found = true
			c.flst_ed = strings.clone(esm.editor_id(fl), context.temp_allocator)
			c.members = esm.form_list_members(fl, context.temp_allocator)
		}
		return true
	}, &ctx)
	if !ctx.found {
		fmt.printfln("form list 0x%08X not found (or not an FLST)", want)
		return
	}
	fmt.printfln("form list 0x%08X %q — %d members:", want, ctx.flst_ed, len(ctx.members))
	for m, i in ctx.members {
		ed := ctx.edids[Form_ID(m)] or_else "?"
		fmt.printfln("  [%2d] 0x%08X %s", i, m, ed)
	}
}

lvli_mode :: proc(data: []u8, want: Form_ID) {
	Ctx :: struct {
		want:    Form_ID,
		edids:   map[Form_ID]string, // formID -> editor id (temp-owned)
		chance:  u8,
		flags:   u8,
		entries: []esm.Leveled_Entry, // the target's raw LVLO entries
		lvli_ed: string,
		found:   bool,
	}
	ctx := Ctx{want = want, edids = make(map[Form_ID]string, 8192, context.temp_allocator)}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return true
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		if ed := esm.editor_id(fl); ed != "" {
			c.edids[rec.form_id] = strings.clone(ed, context.temp_allocator)
		}
		if rec.form_id == c.want && esm.sig(rec) == "LVLI" {
			c.found = true
			c.lvli_ed = strings.clone(esm.editor_id(fl), context.temp_allocator)
			c.chance, c.flags, c.entries = esm.leveled_list(fl, context.temp_allocator)
		}
		return true
	}, &ctx)
	if !ctx.found {
		fmt.printfln("leveled list 0x%08X not found (or not a LVLI)", want)
		return
	}
	fmt.printfln(
		"leveled list 0x%08X %q — chance_none=%d flags=0x%02X, %d entries:",
		want, ctx.lvli_ed, ctx.chance, ctx.flags, len(ctx.entries),
	)
	for e in ctx.entries {
		ed := ctx.edids[Form_ID(e.item)] or_else "?"
		fmt.printfln("  lvl %3d  %3d x 0x%08X %s", e.level, e.count, e.item, ed)
	}
}

import strtab "../../src/formats/strings"

npc_mode :: proc(data: []u8, want: Form_ID) {
	Ctx :: struct {
		want:  Form_ID,
		found: bool,
		edid:  string,
		cfg:   esm.Actor_Config,
		attr:  esm.Actor_Attributes,
		hcfg:  bool,
		hattr: bool,
		race:  u32,
		class: u32,
		voice: u32,
		nspell: int,
		npkid:  int,
		ninv:   int,
	}
	ctx := Ctx{want = want}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		if rec.form_id != c.want || esm.sig(rec) != "NPC_" {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return false
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		c.found = true
		c.edid = strings.clone(esm.editor_id(fl), context.temp_allocator)
		c.cfg, c.hcfg = esm.actor_config(fl)
		c.attr, c.hattr = esm.actor_attributes(fl)
		c.race, _ = esm.subrecord_formid(fl, "RNAM")
		c.class, _ = esm.subrecord_formid(fl, "CNAM")
		c.voice, _ = esm.subrecord_formid(fl, "VTCK")
		if sp := esm.formid_list(fl, "SPLO", context.temp_allocator); sp != nil {c.nspell = len(sp)}
		if pk := esm.formid_list(fl, "PKID", context.temp_allocator); pk != nil {c.npkid = len(pk)}
		if inv := esm.container_contents(fl, context.temp_allocator); inv != nil {c.ninv = len(inv)}
		return false
	}, &ctx)
	if !ctx.found {
		fmt.printfln("npc 0x%08X not found (or not an NPC_)", want)
		return
	}
	fmt.printfln("npc 0x%08X %q:", want, ctx.edid)
	if ctx.hcfg {
		fmt.printfln(
			"  ACBS flags=0x%08X level=%d calc=%d..%d speed=%d  offsets H/M/S=%d/%d/%d",
			ctx.cfg.flags, ctx.cfg.level, ctx.cfg.calc_min, ctx.cfg.calc_max, ctx.cfg.speed_mult,
			ctx.cfg.health_off, ctx.cfg.magicka_off, ctx.cfg.stamina_off,
		)
	}
	if ctx.hattr {
		fmt.printfln(
			"  DNAM base H/M/S=%d/%d/%d  skills[0..3]=%d,%d,%d,%d",
			ctx.attr.health, ctx.attr.magicka, ctx.attr.stamina,
			ctx.attr.skills[0], ctx.attr.skills[1], ctx.attr.skills[2], ctx.attr.skills[3],
		)
	}
	fmt.printfln(
		"  race=0x%08X class=0x%08X voice=0x%08X  spells=%d packages=%d inventory=%d",
		ctx.race, ctx.class, ctx.voice, ctx.nspell, ctx.npkid, ctx.ninv,
	)
}

glob_mode :: proc(data: []u8, want: Form_ID) {
	Ctx :: struct {
		want:  Form_ID,
		found: bool,
		edid:  string,
		value: f32,
		kind:  u8,
	}
	ctx := Ctx{want = want}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		if rec.form_id != c.want || esm.sig(rec) != "GLOB" {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return false
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		c.found = true
		c.edid = strings.clone(esm.editor_id(fl), context.temp_allocator)
		c.value, c.kind, _ = esm.global_value(fl)
		return false
	}, &ctx)
	if !ctx.found {
		fmt.printfln("global 0x%08X not found (or not a GLOB)", want)
		return
	}
	fmt.printfln("global 0x%08X %q — type=%c value=%g", want, ctx.edid, ctx.kind, ctx.value)
}

// lscr_mode validates the LSCR loading-tip decode: count raw LSCR records with a DESC, then build a
// real gamedb (STRINGS+DLSTRINGS attached) and report how many tips gamedb.load_tips resolved non-empty.
// Structure/counts only — never the copyrighted tip text.
lscr_mode :: proc(data: []u8, esm_path: string) {
	Ctx :: struct {
		n:        int,
		desc_ids: [dynamic]u32, // DESC localized-string ids (to test which table resolves them)
	}
	ctx := Ctx{desc_ids = make([dynamic]u32, context.temp_allocator)}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		if esm.sig(rec) != "LSCR" {
			return true
		}
		c := (^Ctx)(user)
		if fl, backing, ok := esm.fields(rec); ok {
			if f, dok := esm.find_field(fl, "DESC"); dok {
				c.n += 1
				if id, idok := esm.lstring_id(f); idok {append(&c.desc_ids, id)}
			}
			delete(fl)
			if backing != nil {delete(backing)}
		}
		return true
	}, &ctx)
	fmt.printfln("LSCR records with a DESC subrecord: %d (%d as lstring ids)", ctx.n, len(ctx.desc_ids))

	dir := filepath.dir(esm_path)
	defer delete(dir)
	// Which STRINGS-family table resolves the DESC ids? (DESC could be Plain STRINGS, not DLSTRINGS.)
	loadtbl :: proc(dir, ext: string, kind: strtab.Kind) -> map[u32]string {
		p, _ := filepath.join({dir, "Strings", fmt.tprintf("Skyrim_English.%s", ext)}, context.temp_allocator)
		b, rerr := os.read_entire_file(p, context.temp_allocator)
		if rerr != nil {return nil}
		tbl, _ := strtab.parse(b, kind, context.temp_allocator)
		return tbl
	}
	for tb in ([3]struct{name: string, tbl: map[u32]string}{
		{"STRINGS", loadtbl(dir, "STRINGS", .Plain)},
		{"ILSTRINGS", loadtbl(dir, "ILSTRINGS", .Lengthed)},
		{"DLSTRINGS", loadtbl(dir, "DLSTRINGS", .Lengthed)},
	}) {
		hit := 0
		for id in ctx.desc_ids {if s, ok := tb.tbl[id]; ok && s != "" {hit += 1}}
		fmt.printfln("  DESC %-10s %d/%d ids resolve", tb.name, hit, len(ctx.desc_ids))
	}
	loadraw :: proc(dir, ext: string) -> []u8 {
		p, _ := filepath.join({dir, "Strings", fmt.tprintf("Skyrim_English.%s", ext)}, context.temp_allocator)
		b, rerr := os.read_entire_file(p, context.temp_allocator)
		if rerr != nil {return nil}
		return b
	}
	inputs := []gamedb.Plugin_Input {
		{name = filepath.base(esm_path), data = data, strings_data = loadraw(dir, "STRINGS"), dlstrings_data = loadraw(dir, "DLSTRINGS")},
	}
	order := gamedb.resolve_load_order(inputs, context.temp_allocator)
	db := gamedb.build_plugins(order, context.temp_allocator)
	defer gamedb.destroy(&db)
	tips := gamedb.load_tips(&db)
	nonempty := 0
	for t in tips {if t != "" {nonempty += 1}}
	fmt.printfln("gamedb load_tips: %d total, %d non-empty", len(tips), nonempty)
}

// quest_mode validates the QUST journal-text decode against a real quest AND determines which
// STRINGS-family file the localized ids live in (STRINGS / ILSTRINGS / DLSTRINGS) — the plain
// .STRINGS gamedb loads today may not hold quest text. Prints STRUCTURE only (counts + which table
// resolves), never the copyrighted text itself.
quest_mode :: proc(data: []u8, want: Form_ID, esm_path: string) {
	Ctx :: struct {
		want:       Form_ID,
		found:      bool,
		edid:       string,
		n_indx:     int,
		cnam_ids:   [dynamic]u32, // stage log-text ids (in order)
		qobj:       int,
		nnam_ids:   [dynamic]u32, // objective-text ids
	}
	ctx := Ctx{want = want, cnam_ids = make([dynamic]u32, context.temp_allocator), nnam_ids = make([dynamic]u32, context.temp_allocator)}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		if rec.form_id != c.want || esm.sig(rec) != "QUST" {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return false
		}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		c.found = true
		c.edid = strings.clone(esm.editor_id(fl), context.temp_allocator)
		have_stage, have_obj := false, false
		for f in fl {
			switch f.type {
			case "INDX":
				if len(f.data) >= 2 {c.n_indx += 1;have_stage = true;have_obj = false}
			case "CNAM":
				if have_stage {if id, idok := esm.lstring_id(f); idok {append(&c.cnam_ids, id)}}
			case "QOBJ":
				if len(f.data) >= 2 {c.qobj += 1;have_obj = true;have_stage = false}
			case "NNAM":
				if have_obj {if id, idok := esm.lstring_id(f); idok {append(&c.nnam_ids, id)}}
			}
		}
		return false
	}, &ctx)
	if !ctx.found {
		fmt.printfln("quest 0x%08X not found (or not a QUST)", want)
		return
	}
	fmt.printfln(
		"quest 0x%08X %q — %d INDX, %d CNAM, %d QOBJ, %d NNAM",
		want, ctx.edid, ctx.n_indx, len(ctx.cnam_ids), ctx.qobj, len(ctx.nnam_ids),
	)

	// Load the three sibling STRINGS tables and report which one resolves the ids.
	dir := filepath.dir(esm_path)
	defer delete(dir)
	stem := "Skyrim" // TODO: derive from esm_path stem if validating other plugins
	load :: proc(dir, stem, ext: string, kind: strtab.Kind) -> map[u32]string {
		p, _ := filepath.join({dir, "Strings", fmt.tprintf("%s_English.%s", stem, ext)}, context.temp_allocator)
		bytes, rerr := os.read_entire_file(p, context.temp_allocator)
		if rerr != nil {return nil}
		tbl, _ := strtab.parse(bytes, kind, context.temp_allocator)
		return tbl
	}
	tbls := [3]struct{name: string, tbl: map[u32]string}{
		{"STRINGS", load(dir, stem, "STRINGS", .Plain)},
		{"ILSTRINGS", load(dir, stem, "ILSTRINGS", .Lengthed)},
		{"DLSTRINGS", load(dir, stem, "DLSTRINGS", .Lengthed)},
	}
	report :: proc(label: string, ids: []u32, tbls: [3]struct{name: string, tbl: map[u32]string}) {
		if len(ids) == 0 {return}
		for tb in tbls {
			hit := 0
			for id in ids {
				if s, ok := tb.tbl[id]; ok && s != "" {hit += 1}
			}
			fmt.printfln("  %-10s %-10s %d/%d ids resolve", label, tb.name, hit, len(ids))
		}
	}
	report("CNAM", ctx.cnam_ids[:], tbls)
	report("NNAM", ctx.nnam_ids[:], tbls)

	// End-to-end: build a real gamedb (single plugin, STRINGS+DLSTRINGS attached) and confirm the
	// full pipeline resolves the quest's journal/objective text. Counts only — no copyrighted text.
	loadraw :: proc(dir, stem, ext: string) -> []u8 {
		p, _ := filepath.join({dir, "Strings", fmt.tprintf("%s_English.%s", stem, ext)}, context.temp_allocator)
		b, rerr := os.read_entire_file(p, context.temp_allocator)
		if rerr != nil {return nil}
		return b
	}
	inputs := []gamedb.Plugin_Input {
		{
			name = filepath.base(esm_path),
			data = data,
			strings_data = loadraw(dir, stem, "STRINGS"),
			dlstrings_data = loadraw(dir, stem, "DLSTRINGS"),
		},
	}
	order := gamedb.resolve_load_order(inputs, context.temp_allocator)
	db := gamedb.build_plugins(order, context.temp_allocator)
	defer gamedb.destroy(&db)
	qb, qbok := gamedb.quest_baseline_of(&db, want)
	if !qbok {
		fmt.println("  gamedb: quest not indexed")
		return
	}
	stage_hits, obj_hits := 0, 0
	for _, s in qb.stage_log {if s != "" {stage_hits += 1}}
	for _, s in qb.objective_text {if s != "" {obj_hits += 1}}
	fmt.printfln(
		"  gamedb resolved: %d/%d stage logs, %d/%d objective texts (non-empty)",
		stage_hits, len(ctx.cnam_ids), obj_hits, len(ctx.nnam_ids),
	)
}

dump_record :: proc(data: []u8, want: Form_ID) {
	Ctx :: struct {
		want:  Form_ID,
		found: bool,
	}
	ctx := Ctx{want, false}
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		c := (^Ctx)(user)
		if rec.form_id != c.want {
			return true
		}
		c.found = true
		fmt.printfln("record 0x%08X type=%s flags=0x%08X", rec.form_id, esm.sig(rec), rec.flags)
		if fl, backing, ok := esm.fields(rec); ok {
			for f in fl {
				preview := ""
				if len(f.data) <= 4 && len(f.data) >= 4 {
					preview = fmt.tprintf(" = 0x%08X", esm_rd32(f.data))
				} else if len(f.data) > 0 && f.data[len(f.data) - 1] == 0 {
					preview = fmt.tprintf(" = %q", string(f.data[:len(f.data) - 1]))
				}
				fmt.printfln("  %s (%d bytes)%s", f.type, len(f.data), preview)
			}
			delete(fl)
			if backing != nil {delete(backing)}
		}
		return false // stop
	}, &ctx)
	if !ctx.found {
		fmt.printfln("record 0x%08X not found", want)
	}
}

@(private = "file")
esm_rd32 :: proc(b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private = "file")
esm_rf32 :: proc(b: []u8, off: int) -> f32 {
	return transmute(f32)(u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24)
}

// lexaudit checks every landscape texture a cell can use (distinct base LTEX across all
// cells): does its diffuse exist with the "textures\" prefix, already-prefixed (as-is),
// or fail both — and does the DDS parse to a supported format. Pinpoints the white-square
// bug (unresolved / double-prefixed / unsupported terrain textures).
lexaudit :: proc(db: ^gamedb.DB, data_dir: string) {
	tex_bsa, _ := filepath.join({data_dir, "Skyrim - Textures.bsa"}, context.temp_allocator)
	v: vfs.VFS
	if !vfs.mount_archive(&v, tex_bsa) {
		fmt.eprintfln("could not mount %s", tex_bsa)
		return
	}
	defer vfs.destroy(&v)

	seen := make(map[Form_ID]bool) // distinct base LTEX
	defer delete(seen)
	for _, bt in db.cell_base_tex {
		for q in 0 ..< 4 {
			if bt[q] != 0 {seen[bt[q]] = true}
		}
	}

	no_diffuse, ok_prefixed, ok_asis, not_found, bad_dds := 0, 0, 0, 0, 0
	for ltex in seen {
		path, ok := gamedb.landscape_diffuse(db, ltex)
		if !ok || path == "" {
			no_diffuse += 1
			fmt.printfln("  LTEX 0x%08X: no diffuse path", ltex)
			continue
		}
		prefixed, _ := filepath.join({"textures", path}, context.temp_allocator)
		full := ""
		if vfs.exists(&v, prefixed) {
			ok_prefixed += 1
			full = prefixed
		} else if vfs.exists(&v, path) {
			ok_asis += 1 // already has a textures\ prefix — our unconditional prepend would MISS it
			full = path
			fmt.printfln("  AS-IS (already prefixed): %s", path)
		} else {
			not_found += 1
			fmt.printfln("  NOT FOUND: %q (tried %q)", path, prefixed)
			continue
		}
		// Parse the DDS + check the format is one we upload.
		if data, rok := vfs.read(&v, full, context.temp_allocator); rok {
			if img, pok := dds.parse(data); !pok || img.format == .Unknown {
				bad_dds += 1
				fmt.printfln("  BAD DDS (parse/format): %s", full)
			}
		}
	}
	fmt.printfln(
		"\n%d distinct landscape textures: %d ok(prefixed), %d ok(as-is/already-prefixed), %d NOT FOUND, %d bad DDS, %d no-diffuse",
		len(seen), ok_prefixed, ok_asis, not_found, bad_dds, no_diffuse,
	)
}

// grasses_survey lists every GRAS type (model + density) and counts how many LTEX map to
// a grass — a headless confirmation that the LTEX.GNAM → GRAS → MODL chain decodes.
grasses_survey :: proc(db: ^gamedb.DB) {
	fmt.printfln("%d GRAS records:", len(db.grasses))
	for fid, g in db.grasses {
		fmt.printfln("  0x%08X  density=%d  %s", fid, int(g.density), g.model)
	}
	with_grass := 0
	for ltex in db.ltex_grass {
		if _, ok := gamedb.grass_for_texture(db, ltex); ok {
			with_grass += 1
		}
	}
	fmt.printfln("%d LTEX records map to a grass type (via GNAM)", with_grass)
}

// grass resolves a cell's per-quadrant grass (base LTEX → GNAM → GRAS → MODL/density)
// and verifies each grass cluster mesh exists in the Meshes archive — a headless check
// on the grass data chain before the scatter/instanced renderer (no GPU).
grass :: proc(db: ^gamedb.DB, data_dir: string, edid: string, gx, gy: i32) {
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	cid, cok := gamedb.cell_at(db, wfid, gx, gy)
	if !cok {
		fmt.eprintfln("no cell at (%d,%d)", gx, gy)
		return
	}
	dom, domok := gamedb.cell_dominant_texture(db, cid)
	if !domok {
		fmt.printfln("cell 0x%08X (%d,%d): no LAND texture layers", cid, gx, gy)
		return
	}
	mesh_bsa, _ := filepath.join({data_dir, "Skyrim - Meshes.bsa"}, context.temp_allocator)
	v: vfs.VFS
	mounted := vfs.mount_archive(&v, mesh_bsa)
	defer if mounted {vfs.destroy(&v)}

	// Sweep the per-vertex dominant grid: tally how many of the 33×33 vertices grow each
	// grass type vs none — the per-point coverage the scatter now follows (vs the old
	// coarse per-quadrant base).
	counts := make(map[string]int) // grass model -> vertex count
	defer delete(counts)
	grassy, total := 0, len(dom)
	for ltex in dom {
		if ltex == 0 {
			continue
		}
		if g, ok := gamedb.grass_for_texture(db, ltex); ok {
			counts[g.model] += 1
			grassy += 1
		}
	}
	fmt.printfln(
		"cell 0x%08X (%d,%d): %d/%d vertices grow grass (%.0f%%), %d distinct grass type(s):",
		cid, gx, gy, grassy, total, 100 * f32(grassy) / f32(total), len(counts),
	)
	for model, n in counts {
		exists := ""
		if mounted {
			full, _ := filepath.join({"meshes", model}, context.temp_allocator)
			exists = " [exists]" if vfs.exists(&v, full) else " [NOT FOUND]"
		}
		fmt.printfln("  %3d verts  %s%s", n, model, exists)
	}
}

// terrain decodes one exterior cell's LAND heightmap (gamedb's VHGT decode) and prints
// its corner/min/max world-Z stats — a headless sanity check on the height decode and
// scale before the streamer renders it (no GPU). HEIGHT_SCALE here mirrors world's.
terrain :: proc(db: ^gamedb.DB, data_dir: string, edid: string, gx, gy: i32) {
	HEIGHT_SCALE :: f32(8)
	G :: 33
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	cid, cok := gamedb.cell_at(db, wfid, gx, gy)
	if !cok {
		fmt.eprintfln("no cell at (%d,%d)", gx, gy)
		return
	}
	h, hok := gamedb.cell_terrain(db, cid)
	if !hok {
		fmt.printfln("cell 0x%08X (%d,%d): no LAND terrain", cid, gx, gy)
		return
	}
	lo, hi := max(f32), min(f32)
	for v in h {
		z := v * HEIGHT_SCALE
		lo = min(lo, z)
		hi = max(hi, z)
	}
	fmt.printfln("cell 0x%08X (%d,%d): %d height samples", cid, gx, gy, len(h))
	fmt.printfln("  world Z: min %.1f  max %.1f  range %.1f", lo, hi, hi - lo)
	fmt.printfln(
		"  corners (world Z): SW %.1f  SE %.1f  NW %.1f  NE %.1f",
		h[0] * HEIGHT_SCALE,
		h[G - 1] * HEIGHT_SCALE,
		h[(G - 1) * G] * HEIGHT_SCALE,
		h[G * G - 1] * HEIGHT_SCALE,
	)

	// Resolve per-quadrant base textures (BTXT → LTEX → TXST → TX00) and verify each
	// diffuse exists in the Textures archive (with and without a "textures\" prefix).
	bt, btok := gamedb.cell_base_textures(db, cid)
	if !btok {
		fmt.println("  base textures: none (no BTXT)")
		return
	}
	tex_bsa, _ := filepath.join({data_dir, "Skyrim - Textures.bsa"}, context.temp_allocator)
	v: vfs.VFS
	mounted := vfs.mount_archive(&v, tex_bsa)
	defer if mounted {vfs.destroy(&v)}

	names := [4]string{"SW", "SE", "NW", "NE"}
	for q in 0 ..< 4 {
		if bt[q] == 0 {
			fmt.printfln("  %s: (no base)", names[q])
			continue
		}
		path, pok := gamedb.landscape_diffuse(db, bt[q])
		if !pok {
			fmt.printfln("  %s: LTEX 0x%08X → (unresolved)", names[q], bt[q])
			continue
		}
		exists := ""
		if mounted {
			prefixed, _ := filepath.join({"textures", path}, context.temp_allocator)
			if vfs.exists(&v, path) {
				exists = " [exists]"
			} else if vfs.exists(&v, prefixed) {
				exists = " [exists w/ textures\\ prefix]"
			} else {
				exists = " [NOT FOUND]"
			}
		}
		fmt.printfln("  %s: %s%s", names[q], path, exists)
	}
}

// stream_test exercises the streamer's THREAD-SAFETY-critical path headlessly (no
// GPU): N worker threads concurrently vfs.read (positional pread) + nif.parse on the
// same archive, each using its own temp allocator and the shared heap for output.
// Validates concurrent reads, per-thread scratch, and cross-thread alloc/free before
// the real (GPU) streamer is run. Mirrors assetdb.decode_model's IO + parse.
Stream_Ctx :: struct {
	v:      ^vfs.VFS,
	paths:  []string,
	mu:     sync.Mutex,
	next:   int,
	shapes: int, // total shapes parsed (guarded by mu)
	fails:  int,
}

stream_test :: proc(db: ^gamedb.DB, data_dir: string, edid: string, gx, gy: i32) {
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	cid, cok := gamedb.cell_at(db, wfid, gx, gy)
	if !cok {
		fmt.eprintfln("no cell at (%d,%d)", gx, gy)
		return
	}
	mesh_bsa, _ := filepath.join({data_dir, "Skyrim - Meshes.bsa"}, context.temp_allocator)
	v: vfs.VFS
	if !vfs.mount_archive(&v, mesh_bsa) {
		fmt.eprintfln("could not mount %s", mesh_bsa)
		return
	}
	defer vfs.destroy(&v)

	// Distinct model paths in the cell.
	set := make(map[string]bool)
	defer delete(set)
	for r in gamedb.refs_of(db, cid) {
		if m, mok := gamedb.model_of(db, r.base); mok && m != "" {
			set[m] = true
		}
	}
	paths := make([dynamic]string, 0, len(set))
	defer delete(paths)
	for m in set {
		append(&paths, m)
	}

	ctx := Stream_Ctx {
		v     = &v,
		paths = paths[:],
	}
	NTHREADS :: 4
	threads: [NTHREADS]^thread.Thread
	for i in 0 ..< NTHREADS {
		t := thread.create(stream_worker)
		t.data = &ctx
		threads[i] = t
		thread.start(t)
	}
	for t in threads {
		thread.join(t)
		thread.destroy(t)
	}
	fmt.printfln(
		"stream-test cell (%d,%d): %d distinct models decoded across %d threads → %d shapes, %d fails",
		gx, gy, len(paths), NTHREADS, ctx.shapes, ctx.fails,
	)
}

stream_worker :: proc(t: ^thread.Thread) {
	ctx := (^Stream_Ctx)(t.data)
	for {
		sync.mutex_lock(&ctx.mu)
		i := ctx.next
		if i >= len(ctx.paths) {
			sync.mutex_unlock(&ctx.mu)
			return
		}
		ctx.next += 1
		path := ctx.paths[i]
		sync.mutex_unlock(&ctx.mu)

		full := strings.concatenate({"meshes\\", path}, context.temp_allocator)
		data, rok := vfs.read(ctx.v, full, context.temp_allocator) // concurrent pread
		nshapes, ok := 0, false
		if rok {
			if h, hok := nif.parse_header(data, context.temp_allocator); hok {
				scene := nif.parse_scene(data, &h, context.allocator) // heap (thread-safe)
				nshapes = len(scene)
				nif.destroy_shapes(scene)
				ok = true
			}
		}
		sync.mutex_lock(&ctx.mu)
		if ok {
			ctx.shapes += nshapes
		} else {
			ctx.fails += 1
		}
		sync.mutex_unlock(&ctx.mu)
		free_all(context.temp_allocator) // reset this thread's scratch each iteration
	}
}

// cell_models prints the distinct model paths placed in one exterior grid cell — to
// identify a location by its landmarks.
cell_models :: proc(db: ^gamedb.DB, edid: string, gx, gy: i32) {
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	cid, cok := gamedb.cell_at(db, wfid, gx, gy)
	if !cok {
		fmt.eprintfln("no cell at (%d,%d) in %s", gx, gy, edid)
		return
	}
	seen := make(map[string]int)
	defer delete(seen)
	for r in gamedb.refs_of(db, cid) {
		if m, mok := gamedb.model_of(db, r.base); mok && m != "" {
			seen[m] += 1
		}
	}
	fmt.printfln("cell (%d,%d) [0x%08X] distinct models:", gx, gy, cid)
	for m, n in seen {
		fmt.printfln("  %3d x  %s", n, m)
	}
}

// densest lists a worldspace's exterior cells sorted by placeable-ref count, with
// their grid coords — used to pick a content-rich streaming spawn point.
densest :: proc(db: ^gamedb.DB, edid: string) {
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	XMARKER :: 0x0000_003B
	XMARKER_HEADING :: 0x0000_0034
	Cellinfo :: struct {
		gx, gy:   i32,
		placeable: int,
	}
	infos := make([dynamic]Cellinfo, 0, 256)
	defer delete(infos)
	for cid in gamedb.cells_of(db, wfid) {
		c, _ := gamedb.cell_by_formid(db, cid)
		if !c.has_grid {
			continue
		}
		n := 0
		for r in gamedb.refs_of(db, cid) {
			if r.disabled || r.base == XMARKER || r.base == XMARKER_HEADING {
				continue
			}
			if m, mok := gamedb.model_of(db, r.base); mok && m != "" {
				n += 1
			}
		}
		append(&infos, Cellinfo{c.gx, c.gy, n})
	}
	slice.sort_by(infos[:], proc(a, b: Cellinfo) -> bool {return a.placeable > b.placeable})
	fmt.printfln("densest cells in %s (grid: placeable statics):", edid)
	for inf, i in infos {
		if i >= 20 {break}
		fmt.printfln("  (%4d,%4d)  %d statics", inf.gx, inf.gy, inf.placeable)
	}
}

// world_meshes replicates the world loader headlessly for an EXTERIOR worldspace:
// mount the meshes archive, actually parse each placeable ref's NIF, and report which
// models produce ZERO shapes (silently missing in-game) plus the NIF block types they
// contain — so an unhandled geometry block type (e.g. BSLODTriShape) shows up by name.
world_meshes :: proc(db: ^gamedb.DB, data_dir: string, edid: string) {
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found: %s", edid)
		return
	}
	mesh_bsa, _ := filepath.join({data_dir, "Skyrim - Meshes.bsa"}, context.temp_allocator)
	v: vfs.VFS
	if !vfs.mount_archive(&v, mesh_bsa) {
		fmt.eprintfln("could not mount %s", mesh_bsa)
		return
	}
	defer vfs.destroy(&v)

	XMARKER :: 0x0000_003B
	XMARKER_HEADING :: 0x0000_0034
	loaded, shapes_total, fail_read, fail_parse, zero_shapes := 0, 0, 0, 0, 0
	seen := make(map[string]bool) // distinct model already parsed
	defer delete(seen)
	zero := make(map[string]string) // zero-shape model -> its block-type set
	defer { for _, v in zero {delete(v)}; delete(zero) }

	for cid in gamedb.cells_of(db, wfid) {
		for r in gamedb.refs_of(db, cid) {
			if r.disabled || r.base == XMARKER || r.base == XMARKER_HEADING {
				continue
			}
			modl, mok := gamedb.model_of(db, r.base)
			if !mok || modl == "" || seen[modl] {
				continue
			}
			seen[modl] = true

			full := strings.concatenate({"meshes\\", modl}, context.temp_allocator)
			ndata, rok := vfs.read(&v, full, context.temp_allocator)
			if !rok {
				fail_read += 1
				continue
			}
			h, hok := nif.parse_header(ndata, context.temp_allocator)
			if !hok {
				fail_parse += 1
				continue
			}
			scene := nif.parse_scene(ndata, &h, context.temp_allocator)
			if len(scene) == 0 {
				zero_shapes += 1
				zero[strings.clone(modl)] = block_types_of(&h)
			} else {
				loaded += 1
				shapes_total += len(scene)
			}
			free_all(context.temp_allocator)
		}
	}

	fmt.printfln(
		"world-meshes %s: %d distinct models loaded (%d shapes); %d not-found, %d bad-header, %d ZERO-shape",
		edid, loaded, shapes_total, fail_read, fail_parse, zero_shapes,
	)
	fmt.println("zero-shape models (silently missing in-game) and their NIF block types:")
	for modl, types in zero {
		fmt.printfln("  %-48s [%s]", modl, types)
	}
}

// block_types_of returns the distinct block-type names present in a parsed NIF header,
// comma-joined — reveals geometry block types parse_scene doesn't yet handle.
block_types_of :: proc(h: ^nif.Header) -> string {
	set := make(map[string]bool, 16, context.temp_allocator)
	for i in 0 ..< int(h.num_blocks) {
		set[nif.block_type(h, i)] = true
	}
	parts := make([dynamic]string, 0, len(set), context.temp_allocator)
	for t in set {
		append(&parts, t)
	}
	slice.sort(parts[:])
	return strings.join(parts[:], ", ")
}

// gamedb_world exercises the SAME gamedb queries world.load_worldspace uses
// (find_world → cells_of → refs_of → model_of), confirming the indexer — not just a
// raw walk — resolves a worldspace's exterior statics. The tallies must match
// --world-load.
gamedb_world :: proc(db: ^gamedb.DB, edid: string) {
	wfid, ok := gamedb.find_world(db, edid)
	if !ok {
		fmt.eprintfln("worldspace not found in gamedb: %s", edid)
		return
	}
	cells := gamedb.cells_of(db, wfid)

	XMARKER :: 0x0000_003B
	XMARKER_HEADING :: 0x0000_0034
	placeable, markers, disabled, nomodel, doors, refs := 0, 0, 0, 0, 0, 0
	gxmin, gxmax, gymin, gymax := max(i32), min(i32), max(i32), min(i32)
	for cid in cells {
		if c, cok := gamedb.cell_by_formid(db, cid); cok && c.has_grid {
			gxmin = min(gxmin, c.gx); gxmax = max(gxmax, c.gx)
			gymin = min(gymin, c.gy); gymax = max(gymax, c.gy)
		}
		for r in gamedb.refs_of(db, cid) {
			refs += 1
			if r.has_tp {doors += 1}
			switch {
			case r.disabled:
				disabled += 1
			case r.base == XMARKER || r.base == XMARKER_HEADING:
				markers += 1
			case false:
			case:
				if m, mok := gamedb.model_of(db, r.base); mok && m != "" {
					placeable += 1
				} else {
					nomodel += 1
				}
			}
		}
	}
	fmt.printfln("gamedb worldspace %s (0x%08X):", edid, wfid)
	fmt.printfln("  %d cells indexed, %d refs", len(cells), refs)
	fmt.printfln("  grid: X[%d..%d] Y[%d..%d]", gxmin, gxmax, gymin, gymax)
	fmt.printfln(
		"  %d placeable instances  (%d markers, %d disabled, %d no-model, %d doors)",
		placeable, markers, disabled, nomodel, doors,
	)

	// PERSISTENT cell: holds worldspace-wide statics (doors/bridges/gates) the grid streamer
	// never reaches. Report the renderable set (what build_chunk keeps: skip markers/no-model).
	if pcid, pok := gamedb.world_persistent_cell(db, wfid); pok {
		statics, doors2 := 0, 0
		samples := make([dynamic]string, 0, 12, context.temp_allocator)
		for r in gamedb.refs_of(db, pcid) {
			if r.disabled || r.base == XMARKER || r.base == XMARKER_HEADING {
				continue
			}
			m, ok := gamedb.model_of(db, r.base)
			low := strings.to_lower(m, context.temp_allocator)
			if !ok || m == "" || strings.contains(low, "marker") {
				continue // build_chunk drops markers / no-model (invisible auto-load triggers etc.)
			}
			statics += 1
			if r.has_tp {doors2 += 1}
			if len(samples) < 12 {append(&samples, m)}
		}
		fmt.printfln("  --- persistent cell 0x%08X: %d renderable statics (%d are doors) ---", pcid, statics, doors2)
		for s in samples {
			fmt.printfln("      %q", s)
		}
	}

	// List each load door's destination cell + worldspace (to scope cross-worldspace traversal).
	fmt.printfln("  --- load doors (dest cell / worldspace) ---")
	for cid in cells {
		for r in gamedb.refs_of(db, cid) {
			if !r.has_tp || r.disabled {
				continue
			}
			model, _ := gamedb.model_of(db, r.base)
			dest_w := "??"
			dest_c := "??"
			if dref, dok := gamedb.ref_by_formid(db, r.teleport.door); dok {
				if dcell, cok := gamedb.cell_by_formid(db, dref.cell_form_id); cok {
					dest_c = dcell.editor_id if dcell.editor_id != "" else (dcell.interior ? "(interior)" : "(exterior)")
					if dcell.interior {
						dest_w = "INTERIOR"
					} else if w, wok := gamedb.cell_by_formid(db, dref.cell_form_id); wok {
						dest_w = "0x%08X" if false else fmt.tprintf("world 0x%08X%s", w.world_form_id, w.world_form_id == wfid ? " (SAME)" : " (CROSS)")
					}
				}
			}
			fmt.printfln("    door %q pos=(%.0f,%.0f,%.0f) → %s  %s", model, r.pos.x, r.pos.y, r.pos.z, dest_c, dest_w)
		}
	}
}

// world_load resolves a worldspace's exterior REFRs against the gamedb base models —
// the exterior analogue of dump_cell's "world preview". Confirms exterior statics
// resolve to meshes exactly like interior refs do. Finds the target WRLD formID,
// then walks tallying that world's REFRs by NAME(base) → model / marker / no-model.
world_load :: proc(db: ^gamedb.DB, data: []u8, sub: string) {
	// Locate the worldspace formID by editor id (substring, case-insensitive).
	sc := scan_worlds(data)
	target: Form_ID = 0
	name := ""
	lsub := strings.to_lower(sub, context.temp_allocator)
	for fid in sc.order {
		w := sc.worlds[fid]
		if strings.contains(strings.to_lower(w.edid, context.temp_allocator), lsub) {
			target = fid
			name = w.edid
			break
		}
	}
	if target == 0 {
		fmt.eprintfln("worldspace not found: %s", sub)
		return
	}

	XMARKER :: 0x0000_003B
	XMARKER_HEADING :: 0x0000_0034
	Tally :: struct {
		db:                                       ^gamedb.DB,
		world:                                    Form_ID,
		placeable, markers, nomodel, disabled:    int,
		doors:                                    int,
	}
	t := Tally{db = db, world = target}
	esm.walk(data, proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
		t := (^Tally)(user)
		if ctx.world_form_id != t.world || esm.sig(rec) != "REFR" {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {return true}
		defer delete(fl)
		defer if backing != nil {delete(backing)}
		p := esm.decode_refr(fl)
		if rec.flags & gamedb.REFR_INITIALLY_DISABLED != 0 {
			t.disabled += 1
			return true
		}
		if p.base == XMARKER || p.base == XMARKER_HEADING {
			t.markers += 1
			return true
		}
		if _, has := esm.refr_teleport(fl); has {t.doors += 1}
		if m, mok := gamedb.model_of(t.db, Form_ID(p.base)); mok && m != "" {
			t.placeable += 1
		} else {
			t.nomodel += 1
		}
		return true
	}, &t)

	fmt.printfln("world-load %s (0x%08X):", name, target)
	fmt.printfln(
		"  %d placeable instances  (%d markers, %d disabled, %d no-model skipped, %d doors)",
		t.placeable, t.markers, t.disabled, t.nomodel, t.doors,
	)
}

// World accumulates one worldspace's exterior contents during a raw walk.
World :: struct {
	form_id:                Form_ID,
	edid:                   string, // view into file bytes (printed immediately)
	cells, refs, lands:     int,
	xmin, xmax, ymin, ymax: i32,
	has_grid:               bool,
}

World_Scan :: struct {
	worlds: map[Form_ID]^World, // WRLD formID -> accumulator
	order:  [dynamic]Form_ID, // discovery order
}

// scan_worlds walks the whole file once, attributing every exterior CELL / REFR /
// LAND to its owning worldspace (via the new Walk_Context.world_form_id). WRLD
// records seed each worldspace's editor id.
scan_worlds :: proc(data: []u8) -> World_Scan {
	sc := World_Scan {
		worlds = make(map[Form_ID]^World),
	}
	esm.walk(data, proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
		sc := (^World_Scan)(user)
		s := esm.sig(rec)
		switch {
		case s == "WRLD":
			w := get_world(sc, rec.form_id)
			if fl, backing, ok := esm.fields(rec); ok {
				w.edid = strings.clone(esm.editor_id(fl))
				delete(fl)
				if backing != nil {delete(backing)}
			}
		case s == "CELL" && ctx.world_form_id != 0:
			w := get_world(sc, ctx.world_form_id)
			w.cells += 1
			if fl, backing, ok := esm.fields(rec); ok {
				if gx, gy, gok := esm.cell_grid(fl); gok {
					if !w.has_grid {
						w.xmin, w.xmax, w.ymin, w.ymax = gx, gx, gy, gy
						w.has_grid = true
					}
					w.xmin = min(w.xmin, gx); w.xmax = max(w.xmax, gx)
					w.ymin = min(w.ymin, gy); w.ymax = max(w.ymax, gy)
				}
				delete(fl)
				if backing != nil {delete(backing)}
			}
		case s == "REFR" && ctx.world_form_id != 0:
			get_world(sc, ctx.world_form_id).refs += 1
		case s == "LAND" && ctx.world_form_id != 0:
			get_world(sc, ctx.world_form_id).lands += 1
		}
		return true
	}, &sc)
	return sc
}

get_world :: proc(sc: ^World_Scan, fid: Form_ID) -> ^World {
	if w, ok := sc.worlds[fid]; ok {
		return w
	}
	w := new(World)
	w.form_id = fid
	sc.worlds[fid] = w
	append(&sc.order, fid)
	return w
}

// worlds lists every worldspace with its exterior cell / ref / LAND tallies and grid
// extent — the survey that tells us how big each exterior is before we load one.
worlds :: proc(data: []u8) {
	sc := scan_worlds(data)
	fmt.printfln("worldspaces (%d):", len(sc.order))
	for fid in sc.order {
		w := sc.worlds[fid]
		grid := "no grid"
		if w.has_grid {
			grid = fmt.tprintf(
				"X[%d..%d] Y[%d..%d] = %dx%d",
				w.xmin, w.xmax, w.ymin, w.ymax,
				w.xmax - w.xmin + 1, w.ymax - w.ymin + 1,
			)
		}
		fmt.printfln(
			"  %-28s 0x%08X  %4d cells  %6d refs  %4d land  %s",
			w.edid, w.form_id, w.cells, w.refs, w.lands, grid,
		)
	}
}

// world_detail prints one worldspace by editor id (case-insensitive substring).
world_detail :: proc(data: []u8, sub: string) {
	sc := scan_worlds(data)
	lsub := strings.to_lower(sub, context.temp_allocator)
	for fid in sc.order {
		w := sc.worlds[fid]
		if !strings.contains(strings.to_lower(w.edid, context.temp_allocator), lsub) {
			continue
		}
		fmt.printfln("worldspace %s (0x%08X):", w.edid, w.form_id)
		fmt.printfln("  exterior cells: %d", w.cells)
		fmt.printfln("  placed refs:    %d", w.refs)
		fmt.printfln("  LAND records:   %d", w.lands)
		if w.has_grid {
			fmt.printfln(
				"  grid: X[%d..%d] Y[%d..%d]  (%d x %d cells, %d units each)",
				w.xmin, w.xmax, w.ymin, w.ymax,
				w.xmax - w.xmin + 1, w.ymax - w.ymin + 1, 4096,
			)
		}
	}
}

// cell_load replicates the world loader headlessly: mount the meshes archive and
// actually parse each placeable ref's model, reporting which fail (the "missing"
// pieces) and how many refs carry compound (multi-axis) rotations (the "misplaced"
// suspects if the euler order is off).
cell_load :: proc(db: ^gamedb.DB, data_dir: string, edid: string) {
	cell, ok := gamedb.find_cell(db, edid)
	if !ok {
		fmt.eprintfln("cell not found: %s", edid)
		return
	}
	mesh_bsa, _ := filepath.join({data_dir, "Skyrim - Meshes.bsa"}, context.temp_allocator)
	v: vfs.VFS
	if !vfs.mount_archive(&v, mesh_bsa) {
		fmt.eprintfln("could not mount %s", mesh_bsa)
		return
	}
	defer vfs.destroy(&v)

	XMARKER :: 0x0000_003B
	XMARKER_HEADING :: 0x0000_0034
	loaded, shapes_total, fail_read, fail_parse, zero_shapes := 0, 0, 0, 0, 0
	rot_hist: [4]int // refs by count of non-zero euler components
	bad := make(map[string]int) // distinct failing model -> ref count
	defer delete(bad)

	for r in gamedb.refs_of(db, cell.form_id) {
		if r.disabled || r.base == XMARKER || r.base == XMARKER_HEADING {
			continue
		}
		modl, mok := gamedb.model_of(db, r.base)
		if !mok || modl == "" {
			continue
		}
		nz := 0
		for c in r.rot {
			if c != 0 {nz += 1}
		}
		rot_hist[nz] += 1

		full := strings.concatenate({"meshes\\", modl}, context.temp_allocator)
		data, rok := vfs.read(&v, full, context.temp_allocator)
		if !rok {
			fail_read += 1
			bad[modl] += 1
			continue
		}
		h, hok := nif.parse_header(data, context.temp_allocator)
		if !hok {
			fail_parse += 1
			bad[modl] += 1
			continue
		}
		scene := nif.parse_scene(data, &h, context.temp_allocator)
		if len(scene) == 0 {
			zero_shapes += 1
			bad[modl] += 1
		} else {
			loaded += 1
			shapes_total += len(scene)
		}
		free_all(context.temp_allocator)
	}

	fmt.printfln(
		"cell-load %s: %d models loaded (%d shapes); %d not-found, %d bad-header, %d zero-shape",
		cell.editor_id,
		loaded,
		shapes_total,
		fail_read,
		fail_parse,
		zero_shapes,
	)
	fmt.printfln(
		"rotations: %d none, %d 1-axis, %d 2-axis, %d 3-axis (compound = misplaced suspects)",
		rot_hist[0],
		rot_hist[1],
		rot_hist[2],
		rot_hist[3],
	)
	for modl, n in bad {
		fmt.printfln("  FAILED (%d refs): %s", n, modl)
	}
}

// rectypes counts every record type across the whole file via a raw walk — proves
// the GRUP descent reaches everything (independent of gamedb's wanted-set).
rectypes :: proc(data: []u8) {
	counts := make(map[string]int)
	defer delete(counts)
	esm.walk(data, proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
		c := (^map[string]int)(user)
		c[esm.sig(rec)] += 1
		return true
	}, &counts)

	Pair :: struct {
		name:  string,
		count: int,
	}
	pairs := make([dynamic]Pair, 0, len(counts))
	defer delete(pairs)
	total := 0
	for name, n in counts {
		append(&pairs, Pair{name, n})
		total += n
	}
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.count > b.count})
	fmt.printfln("record types (%d total records, %d distinct):", total, len(pairs))
	for p in pairs {
		fmt.printfln("  %6d  %s", p.count, p.name)
	}
}

// build_with_strings rebuilds the DB with this plugin's loose STRINGS/DLSTRINGS tables loaded, so
// localized FULL names resolve to real text (the plain top-level build() has no strings). Mirrors
// lscr_mode's loader; English LE ships loose Strings/ files.
build_with_strings :: proc(data: []u8, esm_path: string) -> gamedb.DB {
	dir := filepath.dir(esm_path)
	stem := filepath.stem(filepath.base(esm_path))
	// Localized tables come from loose Data/Strings (the LE-era layout) OR from
	// "Skyrim - Interface.bsa" (what SSE actually ships) — mirror the game's VFS lookup, else
	// every FULL/DESC resolves to "" here and a name survey proves nothing.
	v: vfs.VFS
	ifc, _ := filepath.join({dir, "Skyrim - Interface.bsa"}, context.temp_allocator)
	mounted := vfs.mount_archive(&v, ifc)
	defer if mounted {vfs.destroy(&v)}
	loadraw :: proc(v: ^vfs.VFS, mounted: bool, dir, stem, ext: string) -> []u8 {
		p, _ := filepath.join({dir, "Strings", fmt.tprintf("%s_English.%s", stem, ext)}, context.temp_allocator)
		if b, rerr := os.read_entire_file(p, context.temp_allocator); rerr == nil {
			return b
		}
		if !mounted {
			return nil
		}
		b, _ := vfs.read(v, fmt.tprintf("Strings/%s_English.%s", stem, ext), context.temp_allocator)
		return b
	}
	inputs := []gamedb.Plugin_Input {
		{
			name = filepath.base(esm_path),
			data = data,
			strings_data = loadraw(&v, mounted, dir, stem, "STRINGS"),
			dlstrings_data = loadraw(&v, mounted, dir, stem, "DLSTRINGS"),
		},
	}
	order := gamedb.resolve_load_order(inputs, context.temp_allocator)
	return gamedb.build_plugins(order)
}

// forms_mode surveys the form-metadata indexes (keywords, XLKR links, factions, the magic records,
// quest aliases) against the real ESM — the ground truth those decoders were written from. With no
// filter it prints tallies + one worked example per index; with `sub` it prints every faction /
// keyword whose editor id or name contains it.
forms_mode :: proc(db: ^gamedb.DB, sub: string) {
	if sub != "" {
		lsub := strings.to_lower(sub, context.temp_allocator)
		for form, edid in db.keyword_edid {
			if strings.contains(strings.to_lower(edid, context.temp_allocator), lsub) {
				fmt.printfln("  KYWD 0x%08X %q", u64(form), edid)
			}
		}
		for form, f in db.factions {
			name := gamedb.name_of(db, form)
			if !strings.contains(strings.to_lower(name, context.temp_allocator), lsub) {
				continue
			}
			fmt.printfln(
				"  FACT 0x%08X %q flags=0x%08X %d relation(s) %d rank(s)%s",
				u64(form), name, f.flags, len(f.relations), len(f.ranks),
				" crime" if f.has_crime else "",
			)
			for r in f.ranks {
				fmt.printfln("    rank %d: %q / %q", r.index, r.male_title, r.female_title)
			}
			for r in f.relations {
				fmt.printfln("    vs 0x%08X: %v (%+d)", u64(r.faction), r.combat, r.modifier)
			}
		}
		return
	}

	// Tallies — how much of each index the real masters actually populate.
	kw_forms, kw_tags := 0, 0
	for _, set in db.keywords {
		kw_forms += 1
		kw_tags += len(set)
	}
	links := 0
	for _, l in db.linked_refs {
		links += len(l)
	}
	ranks, relations, crime := 0, 0, 0
	for _, f in db.factions {
		ranks += len(f.ranks)
		relations += len(f.relations)
		if f.has_crime {crime += 1}
	}
	spell_effects, scrolls := 0, 0
	for _, sp in db.spells {
		spell_effects += len(sp.effects)
		if sp.scroll {scrolls += 1}
	}
	ench_effects := 0
	for _, e in db.enchantments {
		ench_effects += len(e.effects)
	}
	described := 0
	for _, m in db.magic_effects {
		if m.description != "" {described += 1}
	}
	aliases, forced := 0, 0
	for _, qb in db.quest_baseline {
		aliases += len(qb.aliases)
		for a in qb.aliases {
			if a.fill == .Forced {forced += 1}
		}
	}
	fmt.printfln("keywords:      %d KYWD records, %d tagged forms, %d tags total", len(db.keyword_edid), kw_forms, kw_tags)
	fmt.printfln("linked refs:   %d refs, %d links", len(db.linked_refs), links)
	fmt.printfln("factions:      %d, %d ranks, %d relations, %d with crime values", len(db.factions), ranks, relations, crime)
	fmt.printfln("spells:        %d (%d scrolls), %d effects", len(db.spells), scrolls, spell_effects)
	fmt.printfln("enchantments:  %d, %d effects", len(db.enchantments), ench_effects)
	fmt.printfln("magic effects: %d, %d with a description", len(db.magic_effects), described)
	fmt.printfln("quest aliases: %d (%d forced to a specific ref)", aliases, forced)

	// The actor-identity layer + the actor-value bridge.
	bonuses := 0
	for _, r in db.races {
		bonuses += r.info.bonus_count
	}
	gear := 0
	for _, o in db.outfits {
		gear += len(o)
	}
	indexed_avs := 0
	for _, av in db.actor_value_info {
		if av.has_index {indexed_avs += 1}
	}
	fmt.printfln("locations:     %d, %d with a parent", len(db.locations), count_parented(db))
	fmt.printfln("weathers:      %d", len(db.weathers))
	fmt.printfln("races:         %d, %d skill bonuses", len(db.races), bonuses)
	fmt.printfln("classes:       %d · voice types: %d · outfits: %d (%d items)",
		len(db.classes), len(db.voice_types), len(db.outfits), gear)
	fmt.printfln("actor values:  %d AVIF (%d with an engine index)", len(db.actor_value_info), indexed_avs)

	// The AV bridge is the load-bearing derivation — print the indices other records cite so a
	// regression shows up as a wrong NAME here, not as silently mismatched gameplay numbers.
	fmt.printfln("\nactor-value index spot check (cited by MGEF / RACE):")
	for idx in ([]i32{0, 6, 7, 18, 19, 21, 24, 25, 26, 53, 163}) {
		key, kok := gamedb.actor_value_key(db, idx)
		disp, _ := gamedb.actor_value_display(db, idx)
		fmt.printfln("    %3d  %-16q display=%q%s", idx, key, disp, "" if kok else "  (no AVIF record)")
	}
	for form, r in db.races {
		if r.info.bonus_count < 4 {continue}
		fmt.printfln("\nexample race 0x%08X %q (height M/F %.2f/%.2f):",
			u64(form), gamedb.name_of(db, form), r.info.height_male, r.info.height_female)
		for i in 0 ..< r.info.bonus_count {
			key, _ := gamedb.actor_value_key(db, i32(r.info.bonuses[i].skill))
			fmt.printfln("    +%d %s", r.info.bonuses[i].bonus, key)
		}
		break
	}
	for form, w in db.weathers {
		// Prefer a fully-authored weather: NAM0 is variable (vanilla carries 17, 14 or 13 rows),
		// so a short one would show empty sunlight/stars and prove nothing.
		if w.color_rows < esm.WTHR_COLOR_ROWS_MAX {continue} // WTHR carries no FULL — identify by form
		sun, _ := gamedb.weather_color(db, form, esm.WTHR_COLOR_SUNLIGHT, 1)
		stars, _ := gamedb.weather_color(db, form, esm.WTHR_COLOR_STARS, 3)
		fmt.printfln("\nexample weather 0x%08X %q: %v, %d colour rows, noon sunlight=%v night stars=%v",
			u64(form), gamedb.name_of(db, form), gamedb.weather_classification(db, form),
			w.color_rows, sun, stars)
		break
	}
	for form, l in db.locations {
		if l.parent == 0 {continue}
		fmt.printfln("\nexample location 0x%08X %q -> parent 0x%08X %q (child=%v)",
			u64(form), gamedb.name_of(db, form), u64(l.parent), gamedb.name_of(db, l.parent),
			gamedb.location_is_child(db, form, l.parent))
		break
	}

	// Worked examples — one populated entry per index, so the values can be eyeballed against the CK.
	for form, set in db.keywords {
		if len(set) < 3 {continue}
		fmt.printfln("\nexample tagged form 0x%08X %q:", u64(form), gamedb.name_of(db, form))
		for k in set {
			fmt.printfln("    %q", gamedb.keyword_editor_id(db, k))
		}
		break
	}
	for form, f in db.factions {
		if len(f.ranks) < 3 || !f.has_crime {continue}
		fmt.printfln("\nexample faction 0x%08X %q: murder=%d assault=%d trespass=%d pickpocket=%d steal=x%.2f",
			u64(form), gamedb.name_of(db, form), f.crime.murder, f.crime.assault,
			f.crime.trespass, f.crime.pickpocket, f.crime.steal_multiplier)
		break
	}
	for form, sp in db.spells {
		if len(sp.effects) < 2 {continue}
		fmt.printfln("\nexample spell 0x%08X %q: cost=%d %v/%v %d effect(s)",
			u64(form), gamedb.name_of(db, form), sp.info.cost, sp.info.cast_type, sp.info.delivery, len(sp.effects))
		for e in sp.effects {
			me, _ := gamedb.magic_effect_of(db, e.effect)
			fmt.printfln("    0x%08X %-28q mag=%.1f dur=%d  %v", u64(e.effect),
				gamedb.name_of(db, e.effect), e.magnitude, e.duration, me.info.archetype)
		}
		if i, ok := gamedb.spell_costliest_effect(db, form); ok {
			fmt.printfln("    costliest effect index: %d", i)
		}
		break
	}
	for form, qb in db.quest_baseline {
		if len(qb.aliases) < 3 {continue}
		fmt.printfln("\nexample quest 0x%08X %q aliases:", u64(form), gamedb.name_of(db, form))
		for a in qb.aliases {
			fmt.printfln("    [%2d] %-24q %v target=0x%08X extra=%d%s",
				a.id, a.name, a.fill, u64(a.target), a.extra, " (location)" if a.location else "")
		}
		break
	}
	for ref, l in db.linked_refs {
		fmt.printfln("\nexample linked ref 0x%08X:", u64(ref))
		for k in l {
			fmt.printfln("    keyword 0x%08X -> 0x%08X", u64(k.keyword), u64(k.ref))
		}
		break
	}
}

// count_parented tallies locations that sit under another (the tree Location.IsChild walks).
count_parented :: proc(db: ^gamedb.DB) -> int {
	n := 0
	for _, l in db.locations {
		if l.parent != 0 {n += 1}
	}
	return n
}

// locks_mode surveys decoded XLOC lock data — validates the XLOC decoder + gamedb lock index against
// the real ESM (which refs start locked, at what level, needing which key).
locks_mode :: proc(db: ^gamedb.DB) {
	shown := 0
	for ref_form, lk in db.locks {
		name := gamedb.name_of(db, ref_form)
		base: gamedb.Form_ID
		if r, ok := gamedb.ref_by_formid(db, ref_form); ok {
			base = r.base
			if name == "" {name = gamedb.name_of(db, base)}
		}
		fmt.printfln(
			"  REFR 0x%08X base 0x%08X  level=%3d key=0x%08X  %q",
			u64(ref_form), u64(base), lk.level, u64(lk.key), name,
		)
		shown += 1
		if shown >= 80 {break}
	}
	fmt.printfln("(showed %d of %d locked ref(s))", shown, len(db.locks))
}

// cellnames_mode lists cells that carry a FULL display name (editor id → FULL), filtered by `sub` —
// validates CELL FULL decode (so a load door shows "Riverwood Trader", not "RiverwoodTraderInterior").
cellnames_mode :: proc(db: ^gamedb.DB, sub: string) {
	lsub := strings.to_lower(sub, context.temp_allocator)
	shown, named := 0, 0
	for form, c in db.cells {
		full := gamedb.name_of(db, form)
		if full == "" {
			continue
		}
		named += 1
		hay := strings.to_lower(strings.concatenate({c.editor_id, " ", full}, context.temp_allocator), context.temp_allocator)
		if lsub != "" && !strings.contains(hay, lsub) {
			continue
		}
		fmt.printfln("  0x%08X  %-40s → %q", u64(form), c.editor_id, full)
		shown += 1
		if shown >= 80 {break}
	}
	fmt.printfln("(showed %d; %d cells carry a FULL name)", shown, named)
}

// list_cells prints interior cells whose editor id contains `sub` (case-insensitive).
list_cells :: proc(db: ^gamedb.DB, sub: string) {
	lsub := strings.to_lower(sub, context.temp_allocator)
	shown := 0
	for _, c in db.cells {
		if !c.interior {
			continue
		}
		if strings.contains(strings.to_lower(c.editor_id, context.temp_allocator), lsub) {
			refs := gamedb.refs_of(db, c.form_id)
			fmt.printfln("  %-40s formID=0x%08X  %d ref(s)", c.editor_id, c.form_id, len(refs))
			shown += 1
			if shown >= 60 {break}
		}
	}
	fmt.printfln("(showed %d interior cell(s))", shown)
}

// dump_cell lists a named cell's placed refs joined to their base model + transform —
// the Checkpoint 1b deliverable. Tallies how many resolved to a known mesh.
dump_cell :: proc(db: ^gamedb.DB, edid: string) {
	cell, ok := gamedb.find_cell(db, edid)
	if !ok {
		fmt.eprintfln("cell not found (interior): %s", edid)
		return
	}
	refs := gamedb.refs_of(db, cell.form_id)
	actors := gamedb.actors_of(db, cell.form_id)
	fmt.printfln(
		"cell %s (formID=0x%08X): %d ref(s), %d actor(s)",
		cell.editor_id, cell.form_id, len(refs), len(actors),
	)
	for a in actors {
		_, hasbase := gamedb.actor_base(db, a.base)
		fmt.printfln("  actor 0x%08X base=0x%08X (NPC_ indexed=%t)", a.form_id, a.base, hasbase)
	}

	// World-load filtering preview (matches src/world.load_cell): a ref becomes a
	// drawable instance unless it's disabled, a marker, or has no base model.
	XMARKER :: 0x0000_003B
	XMARKER_HEADING :: 0x0000_0034
	placeable, markers, disabled := 0, 0, 0

	resolved, doors, shown := 0, 0, 0
	for r in refs {
		model, mok := gamedb.model_of(db, r.base)
		if mok {resolved += 1}
		if r.has_tp {doors += 1}
		switch {
		case r.disabled:
			disabled += 1
		case r.base == XMARKER || r.base == XMARKER_HEADING:
			markers += 1
		case mok && model != "":
			placeable += 1
		}
		if r.has_tp {
			// Resolve the teleport: dest door REFR → its cell.
			dest := "??"
			if dref, dok := gamedb.ref_by_formid(db, r.teleport.door); dok {
				if dcell, cok := gamedb.cell_by_formid(db, dref.cell_form_id); cok {
					dest = fmt.tprintf("%s @(%.0f,%.0f,%.0f)", dcell.editor_id, dref.pos.x, dref.pos.y, dref.pos.z)
				}
			}
			dmodel, _ := gamedb.model_of(db, r.base)
			fmt.printfln("  DOOR base=0x%08X model=%q pos=(%.0f,%.0f,%.0f) → door 0x%08X in %s", r.base, dmodel, r.pos.x, r.pos.y, r.pos.z, r.teleport.door, dest)
		}
		if shown < 1000 {
			tp := ""
			if r.has_tp {
				tp = fmt.tprintf("  ->door 0x%08X", r.teleport.door)
			}
			RAD :: 180.0 / 3.14159265
			fmt.printfln(
				"  base=0x%08X pos=(%.0f,%.0f,%.0f) rot=(%.1f,%.1f,%.1f) scale=%.2f  %q%s",
				r.base,
				r.pos.x,
				r.pos.y,
				r.pos.z,
				r.rot.x * RAD,
				r.rot.y * RAD,
				r.rot.z * RAD,
				r.scale,
				model,
				tp,
			)
			shown += 1
		}
	}
	fmt.printfln(
		"resolved %d/%d refs to a base mesh; %d door teleport(s)",
		resolved,
		len(refs),
		doors,
	)
	fmt.printfln(
		"world preview: %d placeable instance(s)  (%d markers, %d disabled skipped)",
		placeable,
		markers,
		disabled,
	)
}

// loadorder_mode resolves the full load order over a Data dir and builds one DB,
// reporting the order, totals, and a few DLC worldspaces to prove cross-master indexing.
loadorder_mode :: proc(dir: string) {
	infos, derr := os.read_all_directory_by_path(dir, context.allocator)
	if derr != nil {
		fmt.eprintfln("failed to read dir: %s", dir)
		os.exit(1)
	}
	defer delete(infos)

	inputs := make([dynamic]gamedb.Plugin_Input, 0, 16)
	defer {
		for inp in inputs {delete(inp.data)}
		delete(inputs)
	}
	for fi in infos {
		lower := strings.to_lower(fi.name, context.temp_allocator)
		if !strings.has_suffix(lower, ".esm") && !strings.has_suffix(lower, ".esp") {
			continue
		}
		p, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		bytes, rerr := os.read_entire_file(p, context.allocator)
		if rerr != nil {
			fmt.eprintfln("  skip %s (read failed)", fi.name)
			continue
		}
		append(&inputs, gamedb.Plugin_Input{name = fi.name, data = bytes})
	}
	if len(inputs) == 0 {
		fmt.eprintfln("no plugins in %s", dir)
		os.exit(1)
	}

	order := gamedb.resolve_load_order(inputs[:], context.allocator)
	defer delete(order, context.allocator)
	fmt.println("load order:")
	for lp in order {
		fmt.printfln("  [%02X] %s (%d bytes)", lp.index, lp.name, len(lp.data))
	}

	db := gamedb.build_plugins(order)
	defer gamedb.destroy(&db)

	interior, exterior := 0, 0
	for _, c in db.cells {
		if c.interior {interior += 1} else {exterior += 1}
	}
	fmt.printfln(
		"indexed: %d worldspaces, %d cells (%d interior / %d exterior), %d base models, %d refs",
		len(db.worlds), len(db.cells), interior, exterior, len(db.base_models), len(db.ref_by_id),
	)
	// DLC worldspaces only resolvable once their plugin is remapped into global space.
	for name in ([?]string{"Tamriel", "DLC2SolstheimWorld", "DLC1HunterHQWorld", "SoulCairn"}) {
		if wfid, ok := gamedb.find_world(&db, name); ok {
			fmt.printfln("  world %-20s 0x%08X  (%d cells)", name, wfid, len(gamedb.cells_of(&db, wfid)))
		} else {
			fmt.printfln("  world %-20s (not found)", name)
		}
	}
}

// gmst_survey reports the game settings by kind, and lists the ones matching `filter`.
// build_localized builds ONE plugin with its localized string tables attached. The tables matter
// for any record whose text is an lstring id: without them a GMST string or a MESG body decodes to
// noise. Mirrors what the app does — loose Data/Strings first, then the archive that carries them.
// The caller destroys the returned DB and frees `owned`.
build_localized :: proc(path: string) -> (db: gamedb.DB, owned: [3][]u8) {
	bytes, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("failed to read: %s", path)
		os.exit(1)
	}

	dir := filepath.dir(path)
	stem := filepath.stem(filepath.base(path))
	v: vfs.VFS
	defer vfs.destroy(&v)
	vfs.mount_loose(&v, dir)
	infos, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr == nil {
		for fi in infos {
			lower := strings.to_lower(fi.name, context.temp_allocator)
			if !strings.has_suffix(lower, ".bsa") {continue}
			// Only the archives that can hold this plugin's tables: the shared Interface
			// archive, or the plugin's own (a Creation Club plugin ships its own).
			if strings.contains(lower, "interface") ||
			   strings.has_prefix(lower, strings.to_lower(stem, context.temp_allocator)) {
				ap, _ := filepath.join({dir, fi.name}, context.temp_allocator)
				vfs.mount_archive(&v, ap)
			}
		}
	}
	spath := strings.concatenate({"Strings/", stem, "_English.STRINGS"}, context.temp_allocator)
	dlpath := strings.concatenate({"Strings/", stem, "_English.DLSTRINGS"}, context.temp_allocator)
	sbytes, _ := vfs.read(&v, spath, context.allocator)
	dlbytes, _ := vfs.read(&v, dlpath, context.allocator)
	fmt.printfln("string tables: STRINGS %d bytes, DLSTRINGS %d bytes", len(sbytes), len(dlbytes))

	inputs := []gamedb.Plugin_Input {
		{name = filepath.base(path), data = bytes, strings_data = sbytes, dlstrings_data = dlbytes},
	}
	order := gamedb.resolve_load_order(inputs, context.allocator)
	defer delete(order, context.allocator)
	return gamedb.build_plugins(order), {bytes, sbytes, dlbytes}
}

gmst_survey :: proc(path: string, filter: string) {
	db, owned := build_localized(path)
	defer gamedb.destroy(&db)
	defer for b in owned {delete(b)}

	floats, ints, bools, texts, empty := 0, 0, 0, 0, 0
	for _, val in db.settings {
		switch t in val {
		case f32:
			floats += 1
		case i32:
			ints += 1
		case bool:
			bools += 1
		case string:
			texts += 1
			if t == "" {empty += 1}
		}
	}
	fmt.printfln(
		"settings: %d total — %d float, %d int, %d bool, %d string (%d empty)",
		len(db.settings), floats, ints, bools, texts, empty,
	)

	if filter == "" {
		return
	}
	names := make([dynamic]string, 0, 64, context.temp_allocator)
	needle := strings.to_lower(filter, context.temp_allocator)
	for name in db.settings {
		if strings.contains(name, needle) {append(&names, name)}
	}
	slice.sort(names[:])
	fmt.printfln("matching %q: %d", filter, len(names))
	for name in names {
		fmt.printfln("  %-44s %v", name, db.settings[name])
	}
}

// mesg_survey reports the MESG messages: how many are modal boxes vs corner notifications, how
// many carry a title, buttons or an owning quest, and the button-count spread. `filter` lists the
// fully resolved records whose title or body contains it.
mesg_survey :: proc(path: string, filter: string) {
	db, owned := build_localized(path)
	defer gamedb.destroy(&db)
	defer for b in owned {delete(b)}

	boxes, notes, titled, quested, timed, empty_body, total_buttons := 0, 0, 0, 0, 0, 0, 0
	spread := make(map[int]int, 16, context.temp_allocator)
	for _, m in db.messages {
		if m.message_box {boxes += 1} else {notes += 1}
		if m.title != "" {titled += 1}
		if m.quest != 0 {quested += 1}
		if m.display_time != 0 {timed += 1}
		if m.body == "" {empty_body += 1}
		total_buttons += len(m.buttons)
		spread[len(m.buttons)] += 1
	}
	fmt.printfln(
		"messages: %d total — %d message box, %d notification; %d titled, %d with an owning quest, %d timed, %d with no body",
		len(db.messages), boxes, notes, titled, quested, timed, empty_body,
	)
	counts := make([dynamic]int, 0, 16, context.temp_allocator)
	for n in spread {append(&counts, n)}
	slice.sort(counts[:])
	fmt.printfln("buttons: %d total", total_buttons)
	for n in counts {
		fmt.printfln("  %d buttons: %d records", n, spread[n])
	}

	if filter == "" {
		return
	}
	needle := strings.to_lower(filter, context.temp_allocator)
	shown := 0
	for form, m in db.messages {
		if !strings.contains(strings.to_lower(m.title, context.temp_allocator), needle) &&
		   !strings.contains(strings.to_lower(m.body, context.temp_allocator), needle) {
			continue
		}
		shown += 1
		kind := m.message_box ? "box" : "notification"
		fmt.printfln("  0x%08X [%s] title=%q", form, kind, m.title)
		fmt.printfln("      body=%q", m.body)
		for b, i in m.buttons {
			fmt.printfln("      btn[%d]=%q", i, b)
		}
		if m.quest != 0 {fmt.printfln("      quest=0x%08X", m.quest)}
		if m.display_time != 0 {fmt.printfln("      time=%ds", m.display_time)}
	}
	fmt.printfln("matching %q: %d", filter, shown)
}

// perk_survey reports the PERK records and the AVIF perk trees. With `filter` it prints one skill's
// whole constellation — every node with its perk, placement and connections — which is the form the
// stats menu consumes.
perk_survey :: proc(path: string, filter: string) {
	db, owned := build_localized(path)
	defer gamedb.destroy(&db)
	defer for b in owned {delete(b)}

	playable, hidden, traits, chained, named := 0, 0, 0, 0, 0
	for _, p in db.perks {
		if p.playable {playable += 1}
		if p.hidden {hidden += 1}
		if p.trait {traits += 1}
		if p.next_rank != 0 {chained += 1}
		if p.name != "" {named += 1}
	}
	fmt.printfln(
		"perks: %d records — %d playable, %d hidden, %d traits, %d named, %d linked to a next rank",
		len(db.perks), playable, hidden, traits, named, chained,
	)

	// Every tree, and the nodes/connections in it. Roots carry no perk.
	trees, nodes, roots, conns := 0, 0, 0, 0
	for _, t in db.perk_trees {
		trees += 1
		nodes += len(t)
		for n in t {
			if n.perk == 0 {roots += 1}
			conns += len(n.connections)
		}
	}
	fmt.printfln("perk trees: %d skills — %d nodes (%d roots), %d connections", trees, nodes, roots, conns)

	if filter == "" {
		return
	}
	needle := strings.to_lower(filter, context.temp_allocator)
	for avif, tree in db.perk_trees {
		info, iok := gamedb.actor_value_info(&db, avif)
		if !iok {continue}
		if !strings.contains(strings.to_lower(info.editor_id, context.temp_allocator), needle) {continue}
		fmt.printfln("\n0x%08X %s — %d nodes", avif, info.editor_id, len(tree))
		for n in tree {
			label := "(root)"
			ranks := 0
			if p, pok := gamedb.perk_of(&db, n.perk); pok {
				label = p.name != "" ? p.name : "(unnamed)"
				ranks = gamedb.perk_ranks(&db, n.perk)
			}
			fmt.printfln(
				"  idx=%d perk=0x%08X %s ranks=%d grid=(%d,%d) pos=(%.3f,%.3f) -> %v",
				n.index, n.perk, label, ranks, n.grid.x, n.grid.y, n.pos.x, n.pos.y, n.connections,
			)
		}
	}
}

// cobj_survey reports the crafting recipes grouped by workbench — the shape a crafting menu reads.
// `filter` prints one bench's rows in full, with ingredient and result names resolved.
cobj_survey :: proc(path: string, filter: string) {
	db, owned := build_localized(path)
	defer gamedb.destroy(&db)
	defer for b in owned {delete(b)}

	noresult, noingredients, ingredients, listed := 0, 0, 0, 0
	qty := make(map[u16]int, 8, context.temp_allocator)
	for _, r in db.recipes {
		if r.result == 0 {noresult += 1}
		if len(r.ingredients) == 0 {noingredients += 1}
		ingredients += len(r.ingredients)
		qty[r.quantity] += 1
	}
	fmt.printfln(
		"recipes: %d — %d ingredient entries, %d making nothing, %d needing nothing",
		len(db.recipes), ingredients, noresult, noingredients,
	)
	fmt.print("yields:")
	qk := make([dynamic]u16, 0, 8, context.temp_allocator)
	for k in qty {append(&qk, k)}
	slice.sort(qk[:])
	for k in qk {fmt.printf(" %d(x%d)", k, qty[k])}
	fmt.println()

	fmt.printfln("workbenches: %d", len(db.recipes_by_bench))
	for bench, list in db.recipes_by_bench {
		listed += len(list)
		fmt.printfln("  0x%08X %-40s %d recipes", bench, gamedb.keyword_editor_id(&db, bench), len(list))
	}
	fmt.printfln("grouped total: %d (matches record count: %v)", listed, listed == len(db.recipes))

	if filter == "" {
		return
	}
	needle := strings.to_lower(filter, context.temp_allocator)
	for bench, list in db.recipes_by_bench {
		if !strings.contains(strings.to_lower(gamedb.keyword_editor_id(&db, bench), context.temp_allocator), needle) {
			continue
		}
		fmt.printfln("\n%s — %d recipes", gamedb.keyword_editor_id(&db, bench), len(list))
		for form, i in list {
			if i >= 12 {fmt.printfln("  … %d more", len(list) - 12);break}
			r, _ := gamedb.recipe_of(&db, form)
			fmt.printf("  0x%08X makes %dx %s  <-", form, r.quantity, gamedb.name_of(&db, r.result))
			for ing in r.ingredients {
				fmt.printf(" %dx %s,", ing.count, gamedb.name_of(&db, ing.item))
			}
			fmt.println()
		}
	}
}
