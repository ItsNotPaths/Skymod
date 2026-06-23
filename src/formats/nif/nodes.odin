package nif

// NIF node graph → placed shapes (ROADMAP Iteration 1, Milestone B2 finish). Walks
// the NiNode/BSFadeNode hierarchy from the footer roots, composing each node's
// local transform (NiAVObject: translation + 3x3 rotation + scale) down to each
// NiTriShape, resolves the shape's Data ref to its NiTriShapeData geometry, and
// emits world-placed shapes ready for the renderer.
//
// Layout is Skyrim LE (20.2.0.7), validated empirically against real NIFs (the
// composed world transforms must land geometry in sane Skyrim coordinates).

// Transform is one node's local TRS (NiAVObject).
Transform :: struct {
	translation: [3]f32,
	rotation:    matrix[3, 3]f32,
	scale:       f32,
}

// PlacedShape is one renderable mesh with its world matrix and material. diffuse is
// the archive-internal DDS path (e.g. `textures\...\.dds`) or "" if untextured.
PlacedShape :: struct {
	geometry: Geometry,
	world:    matrix[4, 4]f32,
	diffuse:  string,
}

// parse_scene returns every NiTriShape in the file, world-placed. Caller frees with
// destroy_shapes.
parse_scene :: proc(data: []u8, h: ^Header, allocator := context.allocator) -> []PlacedShape {
	context.allocator = allocator

	infos := make([]Block_Info, int(h.num_blocks), context.temp_allocator)
	for i in 0 ..< int(h.num_blocks) {
		infos[i] = parse_block_info(h, data, i)
	}

	roots := parse_footer(data, h)
	shapes := make([dynamic]PlacedShape, 0, 8)
	for root in roots {
		walk_node(infos, data, h, int(root), 1, &shapes)
	}
	return shapes[:]
}

destroy_shapes :: proc(shapes: []PlacedShape) {
	for &s in shapes {
		destroy_geometry(&s.geometry)
		delete(s.diffuse)
	}
	delete(shapes)
}

// --- internals ---

@(private)
Block_Info :: struct {
	is_node:    bool,
	is_shape:   bool,
	transform:  Transform,
	children:   []i32, // node children (temp)
	data_ref:   i32,   // shape geometry data ref, or -1
	shader_ref: i32,   // shape BSLightingShaderProperty ref, or -1
}

@(private)
walk_node :: proc(
	infos: []Block_Info,
	data: []u8,
	h: ^Header,
	idx: int,
	parent_world: matrix[4, 4]f32,
	out: ^[dynamic]PlacedShape,
) {
	if idx < 0 || idx >= len(infos) {
		return
	}
	info := infos[idx]
	if !info.is_node && !info.is_shape {
		return
	}
	world := parent_world * transform_to_mat4(info.transform)

	if info.is_shape {
		dr := int(info.data_ref)
		// Both NiTriShape and BSLODTriShape point at NiTriShapeData geometry.
		if dr >= 0 && dr < int(h.num_blocks) && block_type(h, dr) == "NiTriShapeData" {
			if g, ok := parse_tri_shape_data(block_data(h, data, dr)); ok {
				diffuse := resolve_diffuse(data, h, info.shader_ref)
				append(out, PlacedShape{geometry = g, world = world, diffuse = diffuse})
			}
		}
		return
	}
	for c in info.children {
		walk_node(infos, data, h, int(c), world, out)
	}
}

// is_node_type reports whether a block is a NiNode (or a subclass we can walk for
// children). All these inherit NiNode's layout — Children come right after the
// NiAVObject prefix, with any subclass-specific fields AFTER, so reading just the
// children (parse_block_info stops there) is safe for every one of them. Covers
// switch/billboard/ordered/etc. nodes that hold static clutter geometry (without
// these, e.g. NiSwitchNode-wrapped meshes silently load as zero shapes).
@(private)
is_node_type :: proc(t: string) -> bool {
	switch t {
	case "NiNode",
	     "BSFadeNode",
	     "NiSwitchNode",
	     "NiBillboardNode",
	     "BSOrderedNode",
	     "BSMultiBoundNode",
	     "BSValueNode",
	     "BSLeafAnimNode",
	     "BSBlastNode",
	     "BSDamageStage":
		return true
	}
	return false
}

@(private)
parse_block_info :: proc(h: ^Header, data: []u8, i: int) -> (bi: Block_Info) {
	bi.data_ref = -1
	bi.shader_ref = -1
	t := block_type(h, i)
	is_node := is_node_type(t)
	// BSLODTriShape = NiTriShape + trailing LOD-level sizes; identical NiTriBasedGeom
	// layout up through the shader ref (the extra fields come AFTER, so the shared
	// reader is safe). Without it, whole BSLODTriShape-built buildings (e.g. Whiterun's
	// WRHouseStores01) and roof pieces silently load as zero shapes.
	is_shape := t == "NiTriShape" || t == "BSLODTriShape"
	if !is_node && !is_shape {
		return
	}

	r := Reader{data = block_data(h, data, i), ok = true}
	bi.transform = parse_avobject(&r)
	if is_node {
		n := int(read_u32(&r))
		if !r.ok || n < 0 || n > MAX_LIST {
			return // garbage / misaligned — skip this node defensively
		}
		ch := make([]i32, n, context.temp_allocator)
		for j in 0 ..< n {
			ch[j] = read_i32(&r)
		}
		if r.ok {
			bi.children = ch
			bi.is_node = true
		}
	} else {
		// NiGeometry (after NiAVObject): Data ref, Skin Instance ref, then the
		// material data block (Skyrim LE) ending in the Shader Property ref.
		dr := read_i32(&r) // Data ref
		_ = read_i32(&r) // Skin Instance ref
		shader_ref: i32 = -1
		n_mat := int(read_u32(&r)) // Num Materials
		if r.ok && n_mat >= 0 && n_mat <= MAX_LIST {
			for _ in 0 ..< n_mat {
				_ = read_u32(&r) // Material Name (string-table index)
			}
			for _ in 0 ..< n_mat {
				_ = read_i32(&r) // Material Extra Data
			}
			_ = read_i32(&r) // Active Material
			_ = read_u8(&r) // Material Needs Update (bool)
			shader_ref = read_i32(&r) // Shader Property ref
			// Alpha Property ref follows; not needed.
		}
		if r.ok {
			bi.data_ref = dr
			bi.shader_ref = shader_ref
			bi.is_shape = true
		}
	}
	return
}

// parse_avobject reads the NiObjectNET + NiAVObject prefix and returns the local
// transform, leaving the reader at the start of the subclass fields.
// MAX_LIST caps list counts read from (possibly misaligned) data so a garbage
// length can't trigger a huge alloc or a multi-billion-iteration loop.
@(private)
MAX_LIST :: 1 << 16

@(private)
parse_avobject :: proc(r: ^Reader) -> Transform {
	_ = read_i32(r) // Name (StringRef)
	n_extra := int(read_u32(r)) // Num Extra Data List
	if !r.ok || n_extra < 0 || n_extra > MAX_LIST {
		r.ok = false
		return {}
	}
	for _ in 0 ..< n_extra {
		_ = read_i32(r) // Extra Data refs
	}
	_ = read_i32(r) // Controller
	_ = read_u32(r) // Flags

	t: Transform
	t.translation = read_vec3(r)
	t.rotation = read_mat3(r)
	t.scale = read_f32(r)
	_ = read_i32(r) // Collision Object
	return t
}

@(private)
transform_to_mat4 :: proc(t: Transform) -> matrix[4, 4]f32 {
	r := t.rotation
	s := t.scale
	// Row-major literal; translation in the last column.
	return matrix[4, 4]f32{
		r[0, 0] * s, r[0, 1] * s, r[0, 2] * s, t.translation.x,
		r[1, 0] * s, r[1, 1] * s, r[1, 2] * s, t.translation.y,
		r[2, 0] * s, r[2, 1] * s, r[2, 2] * s, t.translation.z,
		0, 0, 0, 1,
	}
}

// parse_footer reads the NiFooter (after the last block): root block refs.
@(private)
parse_footer :: proc(data: []u8, h: ^Header) -> []i32 {
	foff := h.blocks_offset
	if h.num_blocks > 0 {
		last := int(h.num_blocks) - 1
		foff = h.block_offsets[last] + int(h.block_sizes[last])
	}
	r := Reader{data = data, pos = foff, ok = true}
	n := int(read_u32(&r))
	if !r.ok || n < 0 || n > MAX_LIST {
		return {}
	}
	roots := make([]i32, n, context.temp_allocator)
	for i in 0 ..< n {
		roots[i] = read_i32(&r)
	}
	if !r.ok {
		return {}
	}
	return roots
}
