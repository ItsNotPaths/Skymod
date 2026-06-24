package nif

// NIF block decoders (ROADMAP Iteration 1, Milestone B2). The static-mesh subset:
// geometry (NiTriShapeData). Transforms (NiNode/NiTriShape) and materials
// (BSLightingShaderProperty/BSShaderTextureSet) build on this next.
//
// Field layout is Skyrim LE (20.2.0.7, BS 83). Validated empirically against real
// NIFs (tools/nifdump): the parsed vertices must fall inside the data's own bounding
// sphere (center+radius) and every triangle index must be < num_vertices — strong
// signals the conditional field layout is correct.

// Geometry is the decoded triangle mesh from one NiTriShapeData block: positions,
// optional normals + first UV set, and a flat triangle index list (3 per tri). The
// bounding sphere is the data's own, used as a self-check.
Geometry :: struct {
	vertices:  [][3]f32,
	normals:   [][3]f32, // empty if absent
	uvs:       [][2]f32, // first UV set, empty if absent
	triangles: []u16,    // 3 indices per triangle, flattened
	center:    [3]f32,
	radius:    f32,
}

destroy_geometry :: proc(g: ^Geometry) {
	delete(g.vertices)
	delete(g.normals)
	delete(g.uvs)
	delete(g.triangles)
	g^ = {}
}

// BS Vector Flags (NiGeometryData): low bits = number of UV sets, 0x1000 = has
// tangents/bitangents arrays.
BSVF_NUM_UV_MASK :: 0x003F
BSVF_HAS_TANGENTS :: 0x1000

// parse_tri_shape_data decodes one NiTriShapeData block (raw bytes from
// block_data). Returns ok=false on overrun.
parse_tri_shape_data :: proc(b: []u8, allocator := context.allocator) -> (g: Geometry, ok: bool) {
	context.allocator = allocator
	r := Reader{data = b, ok = true}

	// --- NiGeometryData ---
	_ = read_i32(&r) // Group ID
	num_verts := int(read_u16(&r))
	_ = read_u8(&r) // Keep Flags
	_ = read_u8(&r) // Compress Flags
	has_vertices := read_u8(&r) != 0
	if has_vertices {
		g.vertices = make([][3]f32, num_verts)
		for i in 0 ..< num_verts {
			g.vertices[i] = read_vec3(&r)
		}
	}

	bs_vector_flags := read_u16(&r)
	num_uv_sets := int(bs_vector_flags & BSVF_NUM_UV_MASK)
	has_tangents := bs_vector_flags & BSVF_HAS_TANGENTS != 0
	// An unknown/reserved u32 (always 0 observed) sits between BS Vector Flags and
	// Has Normals here. Determined empirically and validated across 59k+ real
	// NiTriShapeData blocks (bounding-sphere + index self-check). The exception is
	// facegen head meshes (meshes\actors\...\facegeom), a different vertex format —
	// out of scope until Phase 6 (NPC faces).
	_ = read_u32(&r)

	has_normals := read_u8(&r) != 0
	if has_normals {
		g.normals = make([][3]f32, num_verts)
		for i in 0 ..< num_verts {
			g.normals[i] = read_vec3(&r)
		}
		if has_tangents {
			for _ in 0 ..< num_verts * 2 { // tangents + bitangents
				_ = read_vec3(&r)
			}
		}
	}

	g.center = read_vec3(&r)
	g.radius = read_f32(&r)

	has_colors := read_u8(&r) != 0
	if has_colors {
		for _ in 0 ..< num_verts { // Color4 = 4 floats
			_ = read_u32(&r)
			_ = read_u32(&r)
			_ = read_u32(&r)
			_ = read_u32(&r)
		}
	}

	if num_uv_sets > 0 {
		g.uvs = make([][2]f32, num_verts) // keep the first set
		for i in 0 ..< num_verts {
			g.uvs[i] = read_vec2(&r)
		}
		for _ in 1 ..< num_uv_sets { // skip extra sets
			for _ in 0 ..< num_verts {
				_ = read_vec2(&r)
			}
		}
	}

	_ = read_u16(&r) // Consistency Flags
	_ = read_i32(&r) // Additional Data ref

	// --- NiTriBasedGeomData ---
	num_tris := int(read_u16(&r))

	// --- NiTriShapeData ---
	_ = read_u32(&r) // Num Triangle Points (= num_tris*3)
	has_triangles := read_u8(&r) != 0
	if has_triangles {
		g.triangles = make([]u16, num_tris * 3)
		for i in 0 ..< num_tris * 3 {
			g.triangles[i] = read_u16(&r)
		}
	}
	// Match groups follow; not needed.

	if !r.ok {
		destroy_geometry(&g)
		return {}, false
	}
	return g, true
}

// parse_skin_partition_tris extracts the triangle index list from a NiSkinPartition
// block. Skyrim stores SKINNED geometry's triangles here, leaving the NiTriShapeData's
// own triangle list empty (num_triangles 0) — the canopy of a tree, swaying branches,
// banners, chains. We render these statically (bind pose), so we only want the
// connectivity: positions/normals/UVs still come from the NiTriShapeData, and each
// partition-local index is mapped back to a global vertex index through the partition's
// Vertex Map. Returns a flat u16 triangle list (3 indices per triangle).
//
// Layout is Skyrim LE (BS 83). We read the full SkinPartition sub-block (including the
// trailing bone-index + BS Unknown Short fields) so multi-partition blocks advance
// correctly. `num_geom_verts` is the owning NiTriShapeData's vertex count, used to drop
// any triangle that maps out of range (a self-check, like validate_geometry).
parse_skin_partition_tris :: proc(
	b: []u8,
	num_geom_verts: int,
	allocator := context.allocator,
) -> (tris: []u16, ok: bool) {
	context.allocator = allocator
	r := Reader{data = b, ok = true}

	num_part := int(read_u32(&r))
	if !r.ok || num_part < 0 || num_part > MAX_LIST {
		return nil, false
	}

	out := make([dynamic]u16, 0, 512)
	emit :: proc(out: ^[dynamic]u16, vmap: []u16, num_geom_verts: int, a, b, c: u16) {
		ga := vmap[int(a)] if len(vmap) > 0 && int(a) < len(vmap) else a
		gb := vmap[int(b)] if len(vmap) > 0 && int(b) < len(vmap) else b
		gc := vmap[int(c)] if len(vmap) > 0 && int(c) < len(vmap) else c
		if int(ga) >= num_geom_verts || int(gb) >= num_geom_verts || int(gc) >= num_geom_verts {
			return // out of range — drop (mapping/layout self-check)
		}
		append(out, ga, gb, gc)
	}

	for _ in 0 ..< num_part {
		num_verts := int(read_u16(&r))
		num_tris := int(read_u16(&r))
		num_bones := int(read_u16(&r))
		num_strips := int(read_u16(&r))
		num_wpv := int(read_u16(&r))
		if !r.ok ||
		   num_verts < 0 || num_verts > MAX_LIST ||
		   num_tris < 0 || num_tris > MAX_LIST ||
		   num_strips < 0 || num_strips > MAX_LIST {
			delete(out)
			return nil, false
		}
		for _ in 0 ..< num_bones {_ = read_u16(&r)} // Bones (skeleton bone indices)

		has_vmap := read_u8(&r) != 0
		vmap: []u16
		if has_vmap {
			vmap = make([]u16, num_verts, context.temp_allocator)
			for i in 0 ..< num_verts {vmap[i] = read_u16(&r)}
		}

		has_vweights := read_u8(&r) != 0
		if has_vweights {
			for _ in 0 ..< num_verts * num_wpv {_ = read_f32(&r)} // skin weights (unused — static)
		}

		strip_lengths := make([]int, num_strips, context.temp_allocator)
		for i in 0 ..< num_strips {strip_lengths[i] = int(read_u16(&r))}

		has_faces := read_u8(&r) != 0
		if has_faces && num_strips != 0 {
			for sl in strip_lengths {
				strip := make([]u16, sl, context.temp_allocator)
				for j in 0 ..< sl {strip[j] = read_u16(&r)}
				if !r.ok {break}
				// Destripe: alternate winding, skip degenerate triangles.
				for i in 0 ..< sl - 2 {
					a, bb, c := strip[i], strip[i + 1], strip[i + 2]
					if a == bb || bb == c || a == c {
						continue
					}
					if i % 2 == 0 {
						emit(&out, vmap, num_geom_verts, a, bb, c)
					} else {
						emit(&out, vmap, num_geom_verts, bb, a, c)
					}
				}
			}
		} else if has_faces {
			for _ in 0 ..< num_tris {
				a := read_u16(&r)
				bb := read_u16(&r)
				c := read_u16(&r)
				emit(&out, vmap, num_geom_verts, a, bb, c)
			}
		}

		// Trailing skin fields — read past them so the next sub-block aligns.
		has_bone_idx := read_u8(&r) != 0
		if has_bone_idx {
			for _ in 0 ..< num_verts * num_wpv {_ = read_u8(&r)} // bone indices
		}
		_ = read_u16(&r) // BS Unknown Short (LOD level), BS version > 34
		if !r.ok {
			break
		}
	}

	if !r.ok && len(out) == 0 {
		delete(out)
		return nil, false
	}
	return out[:], len(out) > 0
}

// validate_geometry self-checks decoded geometry against the NIF's own bounding
// sphere and index bounds — a strong signal the field layout is right.
validate_geometry :: proc(g: ^Geometry) -> (ok: bool, reason: string) {
	if len(g.vertices) == 0 {
		return false, "no vertices"
	}
	for t in g.triangles {
		if int(t) >= len(g.vertices) {
			return false, "triangle index out of range"
		}
	}
	// Every vertex must lie within (a small slack over) the data's bounding sphere.
	r2 := g.radius * g.radius * 1.02 + 1e-3
	for v in g.vertices {
		d := v - g.center
		if d.x * d.x + d.y * d.y + d.z * d.z > r2 {
			return false, "vertex outside bounding sphere"
		}
	}
	return true, ""
}
