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
	tangents:  [][4]f32, // authored tangent-space basis: xyz = tangent, w = bitangent handedness (±1); empty if absent
	uvs:       [][2]f32, // first UV set, empty if absent
	triangles: []u16,    // 3 indices per triangle, flattened
	center:    [3]f32,
	radius:    f32,
}

destroy_geometry :: proc(g: ^Geometry) {
	delete(g.vertices)
	delete(g.normals)
	delete(g.tangents)
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
			// Authored tangent + bitangent arrays (two separate runs). Keep the tangent and
			// derive the bitangent HANDEDNESS (±1) by comparing cross(N,T) to the stored
			// bitangent — so the shader reconstructs B = cross(N,T)·w (handles mirrored UVs).
			g.tangents = make([][4]f32, num_verts)
			tans := make([][3]f32, num_verts, context.temp_allocator)
			for i in 0 ..< num_verts {
				tans[i] = read_vec3(&r)
			}
			for i in 0 ..< num_verts {
				bt := read_vec3(&r)
				t := tans[i]
				n := g.normals[i]
				// cross(n, t)
				c := [3]f32{n[1] * t[2] - n[2] * t[1], n[2] * t[0] - n[0] * t[2], n[0] * t[1] - n[1] * t[0]}
				w: f32 = 1
				if c[0] * bt[0] + c[1] * bt[1] + c[2] * bt[2] < 0 {
					w = -1
				}
				g.tangents[i] = {t[0], t[1], t[2], w}
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

// --- SSE (BS 100) BSTriShape family: geometry lives INLINE in the shape block as
// packed, interleaved vertices described by a 64-bit BSVertexDesc — no NiTriShapeData.
// Desc layout (verified by hand against real SSE blocks, e.g. 0x0003B000_07650408):
// low nibble = per-vertex stride in dwords; nibbles 8..39 = per-attribute dword
// offsets; bits 44+ = attribute flags (bit 0 = VERTEX ... below). Attribute order
// within a vertex is fixed (position, uv, uv2, normal, tangent, colors, skin
// weights+bones, eye data). At stream 100 positions are ALWAYS full f32 (+f32
// bitangent X) — half-float positions are an FO4 (stream 130) economy; UVs are
// halfs, normals/tangents are biased u8. The stride computed from the flags MUST
// equal the desc's own stride — that plus the bounding-sphere/index validation is
// the empirical proof of the layout.

VA_VERTEX :: 1 << 0
VA_UV :: 1 << 1
VA_UV2 :: 1 << 2
VA_NORMAL :: 1 << 3
VA_TANGENT :: 1 << 4
VA_COLORS :: 1 << 5
VA_SKINNED :: 1 << 6
VA_LANDDATA :: 1 << 7
VA_EYEDATA :: 1 << 8
VA_FULLPREC :: 1 << 10

// BS_Head is the fixed run of BSTriShape fields after the NiAVObject prefix,
// shared by the light ref scan (parse_block_info) and the full geometry decode.
BS_Head :: struct {
	center:     [3]f32,
	radius:     f32,
	skin_ref:   i32,
	shader_ref: i32,
	alpha_ref:  i32,
	vdesc:      u64,
	num_tris:   int,
	num_verts:  int,
	data_size:  u32,
}

// read_bs_head reads the BSTriShape head; r must sit just past the NiAVObject
// prefix (parse_avobject). Triangle count is u16 below stream 130 (SSE), u32 at
// 130+ (FO4 — not supported, but read correctly for the self-checks to reject).
@(private)
read_bs_head :: proc(r: ^Reader, bs_version: u32) -> (head: BS_Head) {
	head.center = read_vec3(r)
	head.radius = read_f32(r)
	head.skin_ref = read_i32(r)
	head.shader_ref = read_i32(r)
	head.alpha_ref = read_i32(r)
	head.vdesc = read_u64(r)
	if bs_version >= 130 {
		head.num_tris = int(read_u32(r))
	} else {
		head.num_tris = int(read_u16(r))
	}
	head.num_verts = int(read_u16(r))
	head.data_size = read_u32(r)
	return
}

// bs_vertex_stride computes the packed per-vertex byte stride the attribute flags
// imply. full_prec: f32 positions (16 bytes) vs halfs (8) — always true at stream
// 100. Returns -1 for flag sets we don't model (e.g. LANDDATA terrain vertices)
// so the caller can reject instead of misreading.
@(private)
bs_vertex_stride :: proc(flags: u32, full_prec: bool) -> int {
	if flags & VA_LANDDATA != 0 {
		return -1
	}
	stride := 0
	if flags & VA_VERTEX != 0 {stride += 16 if full_prec else 8}
	if flags & VA_UV != 0 {stride += 4}
	if flags & VA_UV2 != 0 {stride += 4}
	if flags & VA_NORMAL != 0 {stride += 4}
	if flags & VA_TANGENT != 0 {stride += 4}
	if flags & VA_COLORS != 0 {stride += 4}
	if flags & VA_SKINNED != 0 {stride += 8}
	if flags & VA_EYEDATA != 0 {stride += 4}
	return stride
}

// parse_bs_geometry decodes a whole BSTriShape-family block (raw bytes from
// block_data) into Geometry. Also returns the head (shader/alpha/skin refs — the
// caller may already have them) and, for BSMeshLODTriShape, the per-level triangle
// counts from the trailing LOD fields. ok=false on overrun, stride mismatch, or a
// shape whose vertex data lives elsewhere (data_size 0 — SSE skinned meshes keep
// packed vertices in the NiSkinPartition; actors are out of scope until skinning).
parse_bs_geometry :: proc(
	b: []u8,
	bs_version: u32,
	type_name: string,
	allocator := context.allocator,
) -> (
	g: Geometry,
	lod_tris: [3]u32,
	ok: bool,
) {
	context.allocator = allocator
	r := Reader{data = b, ok = true}
	_, _, _, _ = parse_avobject(&r)
	head := read_bs_head(&r, bs_version)
	if !r.ok || head.num_verts < 0 || head.num_verts > MAX_LIST || head.num_tris < 0 || head.num_tris > MAX_LIST {
		return {}, {}, false
	}
	if head.data_size == 0 {
		return {}, {}, false // vertex data lives in the skin partition (skinned actor mesh)
	}

	flags := u32(head.vdesc >> 44)
	// Stream 100 (SSE) always writes f32 positions; VA_FULLPREC is the FO4 opt-in.
	full_prec := bs_version == BS_VERSION_SE || flags & VA_FULLPREC != 0
	stride := bs_vertex_stride(flags, full_prec)
	desc_stride := int(head.vdesc & 0xF) * 4
	if stride < 0 || stride != desc_stride || flags & VA_VERTEX == 0 {
		return {}, {}, false // unmodeled layout — reject loudly rather than misread
	}

	is_dynamic := type_name == "BSDynamicTriShape"
	has_uv := flags & VA_UV != 0
	has_normal := flags & VA_NORMAL != 0
	has_tangent := flags & VA_TANGENT != 0

	g.center = head.center
	g.radius = head.radius
	g.vertices = make([][3]f32, head.num_verts)
	if has_uv {g.uvs = make([][2]f32, head.num_verts)}
	if has_normal {g.normals = make([][3]f32, head.num_verts)}
	if has_normal && has_tangent {g.tangents = make([][4]f32, head.num_verts)}

	byte_to_snorm :: proc(v: u8) -> f32 {return f32(v) / 255 * 2 - 1}

	for i in 0 ..< head.num_verts {
		bit_x, bit_y, bit_z: f32 // bitangent, scattered across the three attribute blocks
		if full_prec {
			g.vertices[i] = read_vec3(&r)
			bit_x = read_f32(&r)
		} else {
			g.vertices[i] = {read_f16(&r), read_f16(&r), read_f16(&r)}
			bit_x = read_f16(&r)
		}
		if has_uv {
			g.uvs[i] = {read_f16(&r), read_f16(&r)}
		}
		if flags & VA_UV2 != 0 {
			_ = read_u32(&r)
		}
		if has_normal {
			g.normals[i] = {byte_to_snorm(read_u8(&r)), byte_to_snorm(read_u8(&r)), byte_to_snorm(read_u8(&r))}
			bit_y = byte_to_snorm(read_u8(&r))
		}
		if has_tangent {
			t := [3]f32{byte_to_snorm(read_u8(&r)), byte_to_snorm(read_u8(&r)), byte_to_snorm(read_u8(&r))}
			bit_z = byte_to_snorm(read_u8(&r))
			if has_normal {
				// Same handedness trick as the LE path: w = sign(cross(N,T)·B), with the
				// stored bitangent reassembled from its scattered x/y/z components.
				n := g.normals[i]
				c := [3]f32 {
					n[1] * t[2] - n[2] * t[1],
					n[2] * t[0] - n[0] * t[2],
					n[0] * t[1] - n[1] * t[0],
				}
				w: f32 = 1
				if c[0] * bit_x + c[1] * bit_y + c[2] * bit_z < 0 {
					w = -1
				}
				g.tangents[i] = {t[0], t[1], t[2], w}
			}
		}
		if flags & VA_COLORS != 0 {
			_ = read_u32(&r)
		}
		if flags & VA_SKINNED != 0 {
			_ = read_u32(&r) // 4 half weights +
			_ = read_u32(&r) // 4 byte bone indices — bind pose only, skipped
		}
		if flags & VA_EYEDATA != 0 {
			_ = read_u32(&r)
		}
	}

	g.triangles = make([]u16, head.num_tris * 3)
	for i in 0 ..< head.num_tris * 3 {
		g.triangles[i] = read_u16(&r)
	}

	// BSDynamicTriShape (facegen/morph targets): the REAL positions are a trailing
	// f32 vec4 array; the packed positions above are morph-base garbage. Replace.
	if is_dynamic {
		_ = read_u32(&r) // dynamic data size (num_verts * 16)
		for i in 0 ..< head.num_verts {
			v := read_vec3(&r)
			_ = read_f32(&r) // w
			if r.ok {g.vertices[i] = v}
		}
	}

	// BSMeshLODTriShape: trailing per-level triangle counts (same semantics as
	// BSLODTriShape's lod_tris — the triangle list is LOD-sorted).
	if type_name == "BSMeshLODTriShape" {
		lod_tris[0] = read_u32(&r)
		lod_tris[1] = read_u32(&r)
		lod_tris[2] = read_u32(&r)
	}

	if !r.ok {
		destroy_geometry(&g)
		return {}, {}, false
	}
	return g, lod_tris, true
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
