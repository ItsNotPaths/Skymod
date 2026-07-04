package main

// Dev harness (not shipped): point the BSA reader / NIF parser at a REAL install
// to validate them against ground truth — the only meaningful test for these
// formats (synthetic fixtures only prove self-consistency). Prints structural
// metadata only (counts, block-type names, asset paths) — never asset bytes — so
// nothing copyrighted lands in logs or the repo.
//
//   odin run tools/nifdump -- <archive.bsa>                 # list .nif entries
//   odin run tools/nifdump -- <archive.bsa> <internal\path> # extract + (later) parse
//
// No SDL — pure formats code, runs headless.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "../../src/formats/bsa"
import "../../src/formats/dds"
import "../../src/formats/nif"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: nifdump <archive.bsa> [internal\\path]")
		os.exit(2)
	}
	for a in os.args {
		if a == "--nodes" {
			nif.Debug_Nodes = true // dump each node's local transform + composed world
		}
	}
	arc, ok := bsa.open(os.args[1])
	if !ok {
		fmt.eprintfln("failed to open archive: %s", os.args[1])
		os.exit(1)
	}
	defer bsa.close(&arc)

	fmt.printfln("archive: %s", os.args[1])
	fmt.printfln("method: %v  entries: %d", arc.method, len(arc.entries))

	if len(os.args) >= 3 && os.args[2] == "--all" {
		validate_all(&arc)
		return
	}

	if len(os.args) >= 3 && os.args[2] == "--dds" {
		validate_dds(&arc)
		return
	}

	if len(os.args) >= 3 && os.args[2] == "--collision" {
		validate_collision(&arc)
		return
	}

	if len(os.args) >= 3 && os.args[2] == "--constraints" {
		constraint_survey(&arc)
		return
	}

	if len(os.args) >= 4 && os.args[2] == "--conraw" {
		// Dump every bhk*Constraint block's raw bytes (u32/i32/f32 per word) to RE the descriptor
		// layout — pivots/axes read as small Havok floats, entity refs as small block indices.
		dump_constraints_raw(&arc, os.args[3])
		return
	}

	if len(os.args) >= 4 && os.args[2] == "--list" {
		// List .nif entries whose path contains the substring (case-insensitive).
		sub := strings.to_lower(os.args[3], context.temp_allocator)
		shown := 0
		for e in arc.entries {
			lp := strings.to_lower(e.path, context.temp_allocator)
			if strings.has_suffix(lp, ".nif") && strings.contains(lp, sub) {
				fmt.printfln("  %s  (%d KB)", e.path, e.size / 1024)
				shown += 1
				if shown >= 40 {break}
			}
		}
		fmt.printfln("(showed %d)", shown)
		return
	}

	if len(os.args) >= 3 {
		// Extract one file and report size (NIF parse comes once the parser lands).
		target := os.args[2]
		for e in arc.entries {
			if strings.equal_fold(e.path, target) {
				data, eok := bsa.extract(&arc, e)
				if !eok {
					fmt.eprintfln("extract failed: %s", target)
					os.exit(1)
				}
				defer delete(data)
				fmt.printfln("extracted %s: %d bytes, compressed=%v", e.path, len(data), e.compressed)
				if strings.has_suffix(strings.to_lower(target, context.temp_allocator), ".dds") {
					dump_dds(data)
				} else {
					dump_nif(data)
				}
				return
			}
		}
		fmt.eprintfln("not found in archive: %s", target)
		os.exit(1)
	}

	// List a sample of .nif entries so we can pick a target.
	shown := 0
	for e in arc.entries {
		if strings.has_suffix(strings.to_lower(e.path, context.temp_allocator), ".nif") {
			fmt.printfln("  %s  (%d bytes, compressed=%v)", e.path, e.size, e.compressed)
			shown += 1
			if shown >= 15 {
				break
			}
		}
	}
	fmt.printfln("(showed %d of the .nif entries)", shown)
}

// validate_all sweeps every .nif in the archive: extract → parse header → decode
// each NiTriShapeData → bounding-sphere/index self-check. Tallies pass/fail so we
// know the layout holds across thousands of real meshes, not just one.
validate_all :: proc(arc: ^bsa.Archive) {
	nifs, shapes, valid, bad_header, bad_geom := 0, 0, 0, 0, 0
	placed, bad_xform := 0, 0
	empty_placed := 0 // placed shapes with no triangles (skinned-but-unrecovered geometry)
	with_diffuse, bad_diffuse := 0, 0 // shapes with a diffuse path; paths not matching textures\...\.dds
	alpha_tested := 0 // shapes with a non-zero alpha-test cutoff (NiAlphaProperty parsed)
	lod_shapes, lod_bad := 0, 0 // BSLODTriShape shapes; ones with a bad level ordering
	effect_shapes := 0 // BSEffectShaderProperty shapes (ghosted at render)
	with_normal, bad_normal := 0, 0 // shapes with a normal-map path; paths not textures\...\.dds
	with_tangents := 0 // placed shapes whose geometry carries authored tangents
	mat_bad := 0 // shapes whose material scalars look like garbage (wrong offsets → NaN/huge)
	examples := make([dynamic]string, 0, 8)
	defer delete(examples)
	xform_ex := make([dynamic]string, 0, 8)
	defer delete(xform_ex)
	diffuse_ex := make([dynamic]string, 0, 8)
	defer delete(diffuse_ex)

	for e in arc.entries {
		if !strings.has_suffix(strings.to_lower(e.path, context.temp_allocator), ".nif") {
			continue
		}
		nifs += 1
		data, eok := bsa.extract(arc, e)
		if !eok {
			continue
		}
		defer delete(data)
		h, hok := nif.parse_header(data)
		if !hok {
			bad_header += 1
			continue
		}
		defer nif.destroy_header(&h)
		for i in 0 ..< int(h.num_blocks) {
			if nif.block_type(&h, i) != "NiTriShapeData" {
				continue
			}
			shapes += 1
			g, gok := nif.parse_tri_shape_data(nif.block_data(&h, data, i))
			if !gok {
				bad_geom += 1
				if len(examples) < 8 {append(&examples, e.path)}
				continue
			}
			ok2, _ := nif.validate_geometry(&g)
			if ok2 {valid += 1} else {
				bad_geom += 1
				if len(examples) < 8 {append(&examples, e.path)}
			}
			nif.destroy_geometry(&g)
		}

		// Scene/transform validation: every placed shape's world transform must be
		// finite and sane (catches a wrong NiAVObject field layout, e.g. Flags width).
		scene := nif.parse_scene(data, &h)
		placed += len(scene)
		for s in scene {
			if len(s.geometry.triangles) == 0 {
				empty_placed += 1
			}
			tx, ty, tz := s.world[0, 3], s.world[1, 3], s.world[2, 3]
			finite := tx == tx && ty == ty && tz == tz
			sane := abs(tx) < 1e7 && abs(ty) < 1e7 && abs(tz) < 1e7
			if !finite || !sane {
				bad_xform += 1
				if len(xform_ex) < 8 {append(&xform_ex, e.path)}
			}
			if s.alpha_cutoff > 0 {
				alpha_tested += 1
			}
			if s.is_effect {
				effect_shapes += 1
			}
			if s.lod_tris != {0, 0, 0} {
				lod_shapes += 1
				// The 3 level sizes PARTITION the triangle list (each LOD draws a sub-range),
				// so they must sum to the geometry's triangle count — confirms the parse.
				ntris := u32(len(s.geometry.triangles) / 3)
				if s.lod_tris[0] + s.lod_tris[1] + s.lod_tris[2] != ntris {
					lod_bad += 1
				}
			}
			if s.diffuse != "" {
				with_diffuse += 1
				// A correctly-parsed diffuse path is a Skyrim texture path. Anything
				// else signals the material field layout is off (garbage string).
				lp := strings.to_lower(s.diffuse, context.temp_allocator)
				if !strings.has_prefix(lp, "textures\\") || !strings.has_suffix(lp, ".dds") {
					bad_diffuse += 1
					// Heap-clone (survives the per-NIF temp reset below) so the printout
					// reflects the real string, not reused temp memory.
					if len(diffuse_ex) < 8 {
						append(&diffuse_ex, fmt.aprintf("%s :: %q", e.path, s.diffuse))
					}
				}
			}
			if s.normal != "" {
				with_normal += 1
				np := strings.to_lower(s.normal, context.temp_allocator)
				if !strings.has_prefix(np, "textures\\") || !strings.has_suffix(np, ".dds") {
					bad_normal += 1
				}
			}
			if len(s.geometry.tangents) > 0 {
				with_tangents += 1
			}
			// Material scalars should be finite + in a sane range (wrong offsets → NaN/huge).
			m := s.material
			g2 := m.glossiness
			ss := m.spec_strength
			if !(g2 == g2 && ss == ss) || g2 < 0 || g2 > 1e5 || ss < 0 || ss > 1e4 {
				mat_bad += 1
			}
		}
		nif.destroy_shapes(scene)

		free_all(context.temp_allocator)
	}

	fmt.printfln(
		"\nswept %d .nif files: %d bad headers; %d NiTriShapeData blocks → %d VALID, %d failed",
		nifs,
		bad_header,
		shapes,
		valid,
		bad_geom,
	)
	fmt.printfln("scene: %d shapes placed; %d with bad/insane world transforms", placed, bad_xform)
	fmt.printfln("empty: %d placed shapes have 0 triangles (skinned geometry not recovered)", empty_placed)
	fmt.printfln(
		"materials: %d/%d shapes have a diffuse path; %d malformed (not textures\\...\\.dds)",
		with_diffuse,
		placed,
		bad_diffuse,
	)
	fmt.printfln(
		"normals: %d/%d shapes have a normal-map path; %d malformed. tangents on %d placed shapes",
		with_normal,
		placed,
		bad_normal,
		with_tangents,
	)
	fmt.printfln("material: %d/%d shapes have garbage spec/gloss scalars (wrong offsets if non-zero)", mat_bad, placed)
	fmt.printfln("alpha: %d/%d shapes are alpha-tested (NiAlphaProperty cutoff > 0)", alpha_tested, placed)
	fmt.printfln("lod: %d shapes are BSLODTriShape; %d have level sizes NOT summing to the triangle count", lod_shapes, lod_bad)
	fmt.printfln("effects: %d shapes are BSEffectShaderProperty (ghosted at render)", effect_shapes)
	for ex in diffuse_ex {
		fmt.printfln("  malformed diffuse: %s", ex)
		delete(ex)
	}
	for ex in xform_ex {
		fmt.printfln("  bad transform: %s", ex)
	}
	for ex in examples {
		fmt.printfln("  failed example: %s", ex)
	}
}

// AABB accumulator over world-space points.
Aabb :: struct {
	lo: [3]f32,
	hi: [3]f32,
}

aabb_init :: proc() -> Aabb {return {{1e30, 1e30, 1e30}, {-1e30, -1e30, -1e30}}}

aabb_add :: proc(a: ^Aabb, p: [3]f32) {
	a.lo = {min(a.lo.x, p.x), min(a.lo.y, p.y), min(a.lo.z, p.z)}
	a.hi = {max(a.hi.x, p.x), max(a.hi.y, p.y), max(a.hi.z, p.z)}
}

aabb_valid :: proc(a: Aabb) -> bool {return a.hi.x >= a.lo.x}

xf_point :: proc(m: matrix[4, 4]f32, v: [3]f32) -> [3]f32 {
	p := m * [4]f32{v.x, v.y, v.z, 1}
	return {p.x, p.y, p.z}
}

// collision_aabb expands `a` to cover one collision shape's world footprint.
collision_aabb :: proc(a: ^Aabb, s: nif.Collision_Shape) {
	switch s.kind {
	case .Box:
		h := s.half_extents
		for dx in ([2]f32{-1, 1}) {
			for dy in ([2]f32{-1, 1}) {
				for dz in ([2]f32{-1, 1}) {
					aabb_add(a, xf_point(s.transform, {h.x * dx, h.y * dy, h.z * dz}))
				}
			}
		}
	case .Sphere:
		c := xf_point(s.transform, {0, 0, 0})
		aabb_add(a, c - s.radius)
		aabb_add(a, c + s.radius)
	case .Capsule:
		for p in ([2][3]f32{s.point_a, s.point_b}) {
			c := xf_point(s.transform, p)
			aabb_add(a, c - s.radius)
			aabb_add(a, c + s.radius)
		}
	case .Convex, .Mesh:
		for v in s.vertices {
			aabb_add(a, xf_point(s.transform, v))
		}
	}
}

// validate_collision sweeps every .nif: parse the bhk* collision tree, tally shapes
// by kind, check mesh index ranges, and compare each file's COLLISION AABB to its
// RENDER AABB (parse_scene). A collision hull lives just inside the visual mesh, so a
// centre that matches + an extent of similar magnitude confirms the ×HAVOK_SCALE
// factor and the rigid-body transform offsets are right; a wildly off AABB flags a
// scale/offset bug. Metadata only — no asset bytes.
validate_collision :: proc(arc: ^bsa.Archive) {
	nif.Debug_Collision = true // tally unhandled shape-block type names
	nifs, with_col, unhandled, uh_seen := 0, 0, 0, 0
	kind_counts: [nif.Collision_Kind]int
	mesh_verts, mesh_tris, bad_idx := 0, 0, 0
	bad_xform := 0 // non-finite / insane collision placement
	aabb_ok, aabb_off := 0, 0 // collision AABB sits sensibly within the render AABB / not
	off_ex := make([dynamic]string, 0, 8)
	defer delete(off_ex)

	for e in arc.entries {
		if !strings.has_suffix(strings.to_lower(e.path, context.temp_allocator), ".nif") {
			continue
		}
		nifs += 1
		data, eok := bsa.extract(arc, e)
		if !eok {continue}
		defer delete(data)
		h, hok := nif.parse_header(data)
		if !hok {continue}
		defer nif.destroy_header(&h)

		col := nif.parse_collision(data, &h)
		defer nif.destroy_collision(&col)
		unhandled += col.unhandled
		if col.unhandled > 0 && uh_seen < 12 {
			fmt.printfln("  unhandled-in: %s", e.path)
			uh_seen += 1
		}
		if len(col.shapes) == 0 {
			free_all(context.temp_allocator)
			continue
		}
		with_col += 1

		cbox := aabb_init()
		for s in col.shapes {
			kind_counts[s.kind] += 1
			if s.kind == .Mesh {
				mesh_verts += len(s.vertices)
				mesh_tris += len(s.indices) / 3
				for i in s.indices {
					if int(i) >= len(s.vertices) {bad_idx += 1;break}
				}
			}
			t := s.transform
			fin := t[0, 3] == t[0, 3] && t[1, 3] == t[1, 3] && t[2, 3] == t[2, 3]
			if !fin || abs(t[0, 3]) > 1e7 || abs(t[1, 3]) > 1e7 || abs(t[2, 3]) > 1e7 {
				bad_xform += 1
			}
			collision_aabb(&cbox, s)
		}

		// Render AABB from the placed render shapes.
		rbox := aabb_init()
		scene := nif.parse_scene(data, &h)
		for s in scene {
			for v in s.geometry.vertices {
				aabb_add(&rbox, xf_point(s.world, v))
			}
		}
		nif.destroy_shapes(scene)

		if aabb_valid(cbox) && aabb_valid(rbox) {
			cc := (cbox.lo + cbox.hi) * 0.5
			rc := (rbox.lo + rbox.hi) * 0.5
			rext := rbox.hi - rbox.lo
			cext := cbox.hi - cbox.lo
			rspan := max(rext.x, rext.y, rext.z) + 1
			// centre within the render extent, and collision no more than ~2× larger.
			centre_ok := abs(cc.x - rc.x) < rspan && abs(cc.y - rc.y) < rspan && abs(cc.z - rc.z) < rspan
			ext_ok := max(cext.x, cext.y, cext.z) < 2.5 * rspan
			if centre_ok && ext_ok {
				aabb_ok += 1
			} else {
				aabb_off += 1
				if len(off_ex) < 10 {
					append(&off_ex, fmt.aprintf(
						"%s  col c(%.0f,%.0f,%.0f) ext(%.0f,%.0f,%.0f) | render c(%.0f,%.0f,%.0f) ext(%.0f,%.0f,%.0f)",
						e.path, cc.x, cc.y, cc.z, cext.x, cext.y, cext.z, rc.x, rc.y, rc.z, rext.x, rext.y, rext.z))
				}
			}
		}
		free_all(context.temp_allocator)
	}

	fmt.printfln("\nswept %d .nif files: %d have bhk* collision", nifs, with_col)
	for k in nif.Collision_Kind {
		fmt.printfln("  %-8v %d", k, kind_counts[k])
	}
	fmt.printfln("mesh: %d verts, %d tris total; %d shapes had an out-of-range index (remap bug)", mesh_verts, mesh_tris, bad_idx)
	fmt.printfln("unhandled bhk* shape blocks (not yet decoded): %d", unhandled)
	for name, n in nif.Unhandled_Types {
		fmt.printfln("    %5d  %s", n, name)
	}
	fmt.printfln("placement: %d shapes with non-finite/insane transform", bad_xform)
	fmt.printfln("aabb vs render: %d sane, %d off (scale/offset suspects)", aabb_ok, aabb_off)
	for ex in off_ex {
		fmt.printfln("  off: %s", ex)
		delete(ex)
	}
}

// validate_dds sweeps every .dds in the archive: parse header → classify format →
// verify the computed mip chain fits the file. Tallies per-format counts so we know
// the layout holds across the real texture set, not just one file.
validate_dds :: proc(arc: ^bsa.Archive) {
	total, parsed, bad := 0, 0, 0
	short := 0 // file shorter than the declared mip chain (truncated/streamed)
	fmt_counts: [dds.Format]int
	examples := make([dynamic]string, 0, 8)
	defer delete(examples)

	for e in arc.entries {
		if !strings.has_suffix(strings.to_lower(e.path, context.temp_allocator), ".dds") {
			continue
		}
		total += 1
		data, eok := bsa.extract(arc, e)
		if !eok {
			continue
		}
		defer delete(data)
		img, ok := dds.parse(data)
		if !ok {
			bad += 1
			if len(examples) < 8 && len(data) >= 4 + 124 {
				// Report why: pixelformat dwFlags@file80, dwFourCC@file84, dwRGBBitCount@file88.
				cc := string(data[4 + 80:4 + 84])
				flags := u32(data[80]) | u32(data[81]) << 8 | u32(data[82]) << 16 | u32(data[83]) << 24
				bits := u32(data[88]) | u32(data[89]) << 8 | u32(data[90]) << 16 | u32(data[91]) << 24
				append(&examples, fmt.aprintf("%s [fourcc=%q pfFlags=0x%x bpp=%d]", e.path, cc, flags, bits))
			}
			continue
		}
		parsed += 1
		fmt_counts[img.format] += 1
		chain := dds.mip_chain(img, context.temp_allocator)
		if len(chain) < int(img.mip_count) {
			short += 1
		}
		free_all(context.temp_allocator)
	}

	fmt.printfln("\nswept %d .dds files: %d parsed, %d unsupported/bad header", total, parsed, bad)
	for f in dds.Format {
		if fmt_counts[f] > 0 {
			fmt.printfln("  %-8v %d", f, fmt_counts[f])
		}
	}
	fmt.printfln("  (%d had a file shorter than the declared mip chain)", short)
	for ex in examples {
		fmt.printfln("  unsupported: %s", ex)
		delete(ex)
	}
}

// dump_dds parses one DDS and prints its format, dimensions, and mip layout.
dump_dds :: proc(data: []u8) {
	img, ok := dds.parse(data)
	if !ok {
		fmt.eprintln("dds: parse FAILED (bad magic or unsupported format)")
		return
	}
	fmt.printfln(
		"dds: format=%v %dx%d mips=%d bgra=%v data=%d bytes",
		img.format,
		img.width,
		img.height,
		img.mip_count,
		img.bgra,
		len(img.data),
	)
	chain := dds.mip_chain(img)
	defer delete(chain)
	fmt.printfln("dds: mip chain → %d level(s):", len(chain))
	for m in chain {
		fmt.printfln("    level %d: %dx%d  %d bytes", m.level, m.width, m.height, len(m.data))
	}
}

// dump_nif parses the header spine and prints structural metadata only (version,
// block-type histogram, string count) — never geometry/pixel bytes.
// dump_constraints_raw prints every bhk*Constraint block's bytes as u32/i32/f32 columns so the
// descriptor layout (numEntities, entity refs, pivotA/axisA/…, min/max angle, friction) can be RE'd
// by eye — pivots are small Havok floats, axes are ~unit vectors, refs are small block indices.
dump_constraints_raw :: proc(arc: ^bsa.Archive, path: string) {
	lu32 :: proc(b: []u8, o: int) -> u32 {
		if o + 4 > len(b) {return 0}
		return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
	}
	for e in arc.entries {
		if !strings.equal_fold(e.path, path) {continue}
		data, eok := bsa.extract(arc, e)
		if !eok {fmt.eprintfln("extract failed: %s", path);return}
		defer delete(data)
		h, hok := nif.parse_header(data)
		if !hok {fmt.eprintln("header parse failed");return}
		defer nif.destroy_header(&h)
		for i in 0 ..< int(h.num_blocks) {
			t := nif.block_type(&h, i)
			if !strings.contains(t, "Constraint") {continue}
			b := nif.block_data(&h, data, i)
			fmt.printfln("\n=== block[%d] %s (%d bytes) ===", i, t, len(b))
			for o := 0; o + 4 <= len(b); o += 4 {
				u := lu32(b, o)
				fmt.printfln("  @%3d  u32=%-11d  i32=%-11d  f32=%12.5f", o, u, i32(u), transmute(f32)u)
			}
		}
	}
}

dump_nif :: proc(data: []u8) {
	h, ok := nif.parse_header(data)
	if !ok {
		fmt.eprintln("nif: header parse FAILED")
		return
	}
	defer nif.destroy_header(&h)
	fmt.printfln(
		"nif: version=0x%X user=%d bs=%d blocks=%d types=%d strings=%d blocks_offset=%d",
		h.version,
		h.user_version,
		h.bs_version,
		h.num_blocks,
		len(h.block_types),
		len(h.strings),
		h.blocks_offset,
	)

	// Histogram of block types across all blocks.
	counts := make(map[string]int)
	defer delete(counts)
	for i in 0 ..< int(h.num_blocks) {
		counts[nif.block_type(&h, i)] += 1
	}
	fmt.println("nif: block types:")
	for name, n in counts {
		fmt.printfln("    %4d  %s", n, name)
	}

	// Header string table — node/sequence/bone names (Door, DoorBlack, Open, Close, …).
	fmt.printfln("nif: strings (%d):", len(h.strings))
	for s, i in h.strings {
		fmt.printfln("    [%d] %q", i, s)
	}

	// Decode + validate every NiTriShapeData against its own bounding sphere.
	fmt.println("nif: geometry:")
	for i in 0 ..< int(h.num_blocks) {
		if nif.block_type(&h, i) != "NiTriShapeData" {
			continue
		}
		bd := nif.block_data(&h, data, i)
		g, gok := nif.parse_tri_shape_data(bd)
		if !gok {
			fmt.printfln("    block %d: PARSE FAILED", i)
			continue
		}
		defer nif.destroy_geometry(&g)
		valid, reason := nif.validate_geometry(&g)
		fmt.printfln(
			"    block %d: %d verts, %d tris, normals=%v uvs=%v, center=%.1v radius=%.1f  [%s]",
			i,
			len(g.vertices),
			len(g.triangles) / 3,
			len(g.normals) > 0,
			len(g.uvs) > 0,
			g.center,
			g.radius,
			"VALID" if valid else reason,
		)
	}

	// Scene: walk the node graph and place each shape in world space.
	shapes := nif.parse_scene(data, &h)
	defer nif.destroy_shapes(shapes)
	fmt.printfln("nif: scene → %d placed shape(s):", len(shapes))
	for s in shapes {
		wt := [3]f32{s.world[0, 3], s.world[1, 3], s.world[2, 3]}
		fmt.printfln(
			"    %d verts, %d tris @ world (%.1f, %.1f, %.1f)  alpha_cutoff=%.2f  lod_tris=%v  effect=%t  scroll=%.3v  diffuse=%q",
			len(s.geometry.vertices),
			len(s.geometry.triangles) / 3,
			wt.x,
			wt.y,
			wt.z,
			s.alpha_cutoff,
			s.lod_tris,
			s.is_effect,
			s.scroll,
			s.diffuse,
		)
		w := s.world
		fmt.printfln("      world 3x3:  [%.3f %.3f %.3f] [%.3f %.3f %.3f] [%.3f %.3f %.3f]",
			w[0, 0], w[0, 1], w[0, 2], w[1, 0], w[1, 1], w[1, 2], w[2, 0], w[2, 1], w[2, 2])
		lo := [3]f32{1e9, 1e9, 1e9}
		hi := [3]f32{-1e9, -1e9, -1e9}
		for v in s.geometry.vertices {
			p := w * [4]f32{v.x, v.y, v.z, 1}
			lo = {min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)}
			hi = {max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)}
		}
		fmt.printfln("      NIF-root AABB: x[%.0f..%.0f] y[%.0f..%.0f] z[%.0f..%.0f]",
			lo.x, hi.x, lo.y, hi.y, lo.z, hi.z)
		// XY quadrant occupancy (relative to AABB centre) reveals an L-shape's empty corner.
		cx, cy := (lo.x + hi.x) * 0.5, (lo.y + hi.y) * 0.5
		q: [4]int // 0:+X+Y 1:-X+Y 2:-X-Y 3:+X-Y
		for v in s.geometry.vertices {
			p := w * [4]f32{v.x, v.y, v.z, 1}
			qi := 0
			if p.x >= cx && p.y >= cy {qi = 0} else if p.x < cx && p.y >= cy {qi = 1} else if p.x < cx && p.y < cy {qi = 2} else {qi = 3}
			q[qi] += 1
		}
		fmt.printfln("      XY quad verts (+X+Y, -X+Y, -X-Y, +X-Y): %d %d %d %d", q[0], q[1], q[2], q[3])
	}

	// Collision: bhk* shape tree → world-placed Collision_Shapes (Skyrim units). Debug_Collision
	// makes the parser print each bhkRigidBody's layer/mass/motion (validates the 3b offsets).
	nif.Debug_Collision = true
	col := nif.parse_collision(data, &h)
	defer nif.destroy_collision(&col)
	fmt.printfln("nif: collision → %d shape(s), %d unhandled block(s):", len(col.shapes), col.unhandled)
	for s in col.shapes {
		wt := [3]f32{s.transform[0, 3], s.transform[1, 3], s.transform[2, 3]}
		cls := fmt.tprintf(" [movable=%v mass=%.2f layer=%d]", s.movable, s.mass, s.layer)
		switch s.kind {
		case .Box:
			fmt.printfln("    Box half=%.1v @ (%.0f, %.0f, %.0f)%s", s.half_extents, wt.x, wt.y, wt.z, cls)
		case .Sphere:
			fmt.printfln("    Sphere r=%.1f @ (%.0f, %.0f, %.0f)%s", s.radius, wt.x, wt.y, wt.z, cls)
		case .Capsule:
			fmt.printfln("    Capsule r=%.1f a=%.0v b=%.0v @ (%.0f, %.0f, %.0f)%s", s.radius, s.point_a, s.point_b, wt.x, wt.y, wt.z, cls)
		case .Convex:
			lo := [3]f32{max(f32), max(f32), max(f32)}
			hi := [3]f32{min(f32), min(f32), min(f32)}
			for v in s.vertices {lo = {min(lo.x, v.x), min(lo.y, v.y), min(lo.z, v.z)};hi = {max(hi.x, v.x), max(hi.y, v.y), max(hi.z, v.z)}}
			fmt.printfln("    Convex %d verts @ (%.0f, %.0f, %.0f)%s  margin=%.2f ext=%.2v", len(s.vertices), wt.x, wt.y, wt.z, cls, s.radius, hi - lo)
		case .Mesh:
			fmt.printfln("    Mesh %d verts, %d tris @ (%.0f, %.0f, %.0f)%s", len(s.vertices), len(s.indices) / 3, wt.x, wt.y, wt.z, cls)
		}
	}
	if len(col.bodies) > 0 {fmt.printfln("nif: %d rigid bodies, %d constraints:", len(col.bodies), len(col.constraints))}
	for c in col.constraints {
		kind := "LimitedHinge" if c.limited else "Hinge"
		fmt.printfln(
			"    %s A=body%d B=body%d  pivot=%.1v axis=%.2v perp=%.2v  limits=[%.1f°,%.1f°] fric=%.3f",
			kind, c.body_a, c.body_b, c.pivot, c.axis, c.perp,
			c.min_angle * 180 / 3.14159, c.max_angle * 180 / 3.14159, c.max_friction,
		)
	}
	// Phase-C render→body map validation: match each render shape's CENTROID to the movable body whose
	// collision AABB contains it (the same co-location match assetdb.map_articulated_shapes uses).
	if len(col.constraints) > 0 {
		scene := nif.parse_scene(data, &h)
		defer nif.destroy_shapes(scene)
		boxes := make([]Aabb, len(col.bodies), context.temp_allocator)
		for i in 0 ..< len(boxes) {boxes[i] = aabb_init()}
		for s in col.shapes {
			if s.body >= 0 && s.body < len(boxes) {collision_aabb(&boxes[s.body], s)}
		}
		fmt.printfln("nif: render→body map (%d placed shapes):", len(scene))
		M :: f32(5)
		for ps, i in scene {
			cw := ps.world * [4]f32{ps.geometry.center.x, ps.geometry.center.y, ps.geometry.center.z, 1}
			rc := [3]f32{cw.x, cw.y, cw.z}
			best_vol, bi := f32(1e30), -1
			for &bx, k in boxes {
				if !col.bodies[k].movable || !aabb_valid(bx) {continue}
				if rc.x < bx.lo.x - M || rc.x > bx.hi.x + M || rc.y < bx.lo.y - M || rc.y > bx.hi.y + M || rc.z < bx.lo.z - M || rc.z > bx.hi.z + M {continue}
				if size := (bx.hi.x - bx.lo.x) + (bx.hi.y - bx.lo.y) + (bx.hi.z - bx.lo.z); size < best_vol {best_vol = size;bi = k}
			}
			tag := fmt.tprintf("body%d", bi) if bi >= 0 else "STATIC"
			fmt.printfln("    shape%d centroid=(%.0f,%.0f,%.0f) -> %s", i, rc.x, rc.y, rc.z, tag)
		}
	}
}

// constraint_survey tallies every bhk*Constraint block type across the archive + how many NIFs
// carry multiple rigid bodies (articulated clutter: signs, hanging animals, chains) — scopes the
// physics-constraint porting work. Dev tool; metadata only.
constraint_survey :: proc(arc: ^bsa.Archive) {
	con_counts := make(map[string]int)
	defer delete(con_counts)
	nifs, with_con, with_multi_rb := 0, 0, 0
	rb_hist: [8]int // NIFs by rigid-body count bucket (0..6, 7=7+)
	examples := make(map[string]string) // constraint type -> first path seen
	defer delete(examples)
	for e in arc.entries {
		if !strings.has_suffix(strings.to_lower(e.path, context.temp_allocator), ".nif") {continue}
		nifs += 1
		data, eok := bsa.extract(arc, e)
		if !eok {continue}
		h, hok := nif.parse_header(data)
		if !hok {delete(data);continue}
		ncon, nrb := 0, 0
		for i in 0 ..< int(h.num_blocks) {
			t := nif.block_type(&h, i)
			if strings.contains(t, "Constraint") {
				// block_type views per-NIF header memory freed each loop, so CLONE the key
				// (and only on first insert) — otherwise stored keys dangle → garbage tallies.
				if _, seen := con_counts[t]; seen {
					con_counts[t] += 1
				} else {
					key := strings.clone(t)
					con_counts[key] = 1
					examples[key] = strings.clone(e.path)
				}
				ncon += 1
			}
			if t == "bhkRigidBody" || t == "bhkRigidBodyT" {nrb += 1}
		}
		if ncon > 0 {with_con += 1}
		if nrb > 1 {with_multi_rb += 1}
		rb_hist[min(nrb, 7)] += 1
		nif.destroy_header(&h)
		delete(data)
		free_all(context.temp_allocator)
	}
	fmt.printfln("\n=== CONSTRAINT SURVEY: %d NIFs ===", nifs)
	fmt.printfln("NIFs with >=1 constraint: %d   with >1 rigid body (articulated): %d", with_con, with_multi_rb)
	fmt.println("rigid-body count histogram (0,1,2,3,4,5,6,7+):", rb_hist)
	fmt.println("constraint block types:")
	for t, n in con_counts {
		fmt.printfln("  %6d  %s   e.g. %s", n, t, examples[t])
	}
}
