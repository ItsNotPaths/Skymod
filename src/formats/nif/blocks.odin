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
