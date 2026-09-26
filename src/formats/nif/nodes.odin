package nif

// NIF node graph → placed shapes (ROADMAP Iteration 1, Milestone B2 finish). Walks
// the NiNode/BSFadeNode hierarchy from the footer roots, composing each node's
// local transform (NiAVObject: translation + 3x3 rotation + scale) down to each
// NiTriShape, resolves the shape's Data ref to its NiTriShapeData geometry, and
// emits world-placed shapes ready for the renderer.
//
// Layout is Skyrim LE (20.2.0.7), validated empirically against real NIFs (the
// composed world transforms must land geometry in sane Skyrim coordinates).

import "core:fmt"
import "core:strings"

// Transform is one node's local TRS (NiAVObject).
Transform :: struct {
	translation: [3]f32,
	rotation:    matrix[3, 3]f32,
	scale:       f32,
}

// PlacedShape is one renderable mesh with its world matrix and material. diffuse is
// the archive-internal DDS path (e.g. `textures\...\.dds`) or "" if untextured.
// alpha_cutoff is the alpha-test threshold in [0,1] (0 = opaque) — foliage leaf cutouts.
// lod_tris is the BSLODTriShape per-level TRIANGLE count (level 0 = full … level 2 =
// coarsest); {0,0,0} when the shape is a plain NiTriShape (no built-in LOD). Bethesda
// sorts the triangle list so the first lod_tris[k]·3 indices form LOD level k.
PlacedShape :: struct {
	geometry:     Geometry,
	world:        matrix[4, 4]f32,
	diffuse:      string,
	normal:       string, // normal-map path (texture-set slot 1), owned; "" if none
	material:     Material, // specular/glossiness/emissive scalars (DEFAULT_MATERIAL if none)
	alpha_cutoff: f32,
	lod_tris:     [3]u32,
	is_effect:    bool, // BSEffectShaderProperty (fire/FX) — rendered additive, not opaque
	scroll:       [2]f32, // effect-shader UV scroll speed (tiles/sec); 0 unless an animated effect
	name:         string, // this shape's NiTriShape name (e.g. "DoorBlack"), owned; "" if unnamed
	under_hinge:  bool, // true if a "Door" hinge node is an ancestor (animated door panel)
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
	// Guard against shared children (DAG → duplicated geometry) and back-edges (cycle →
	// stack overflow): each block is walked at most once. Game NIFs are trees, so this
	// only ever fires on a malformed file.
	visited := make([]bool, int(h.num_blocks), context.temp_allocator)
	shapes := make([dynamic]PlacedShape, 0, 8)
	for root in roots {
		walk_node(infos, data, h, visited, int(root), 1, false, &shapes, is_root = true)
	}
	return shapes[:]
}

destroy_shapes :: proc(shapes: []PlacedShape) {
	for &s in shapes {
		destroy_geometry(&s.geometry)
		delete(s.diffuse)
		delete(s.normal)
		delete(s.name)
	}
	delete(shapes)
}

// HINGE_NODE is the node name whose subtree is the animated door panel (Bethesda convention).
// Shapes under it are tagged under_hinge so the door harness / portal can swing them.
HINGE_NODE :: "Door"

// --- internals ---

@(private)
Block_Info :: struct {
	is_node:        bool,
	is_shape:       bool,
	transform:      Transform,
	name_ref:       i32, // Name StringRef into h.strings, or -1
	controller_ref: i32, // Controller ref (animation chain root), or -1
	children:       []i32, // node children (temp)
	data_ref:       i32,   // shape geometry data ref, or -1
	skin_ref:       i32,   // shape NiSkinInstance ref, or -1 (skinned geometry holds tris in the skin partition)
	shader_ref:     i32,   // shape BSLightingShaderProperty ref, or -1
	alpha_ref:      i32,   // shape NiAlphaProperty ref, or -1
	collision_ref:  i32,   // NiAVObject Collision Object ref (bhkCollisionObject), or -1 — used by collision.odin
	lod_tris:       [3]u32, // BSLODTriShape per-level triangle counts ({0,0,0} if none)
	inline_geom:    bool,  // SSE BSTriShape family: geometry is packed inside the shape block itself
}

// (hole hkx-reader :tags animation :sev blocker) no .hkx reader exists (src/formats has none), so even with a skeleton there is no clip data to sample.
// (hole idle-graph :tags animation :sev gap :needs (hkx-reader)) IDLE and ANIO are decoded by nothing — no idle graph, so nothing could choose which clip to play.
// (hole animation :tags animation :sev blocker :needs (hkx-reader skinned-pipeline)) node transforms are read once and baked — no skeleton, no clip sampling, nothing plays a .hkx. Actors T-pose and every animated prop is frozen.
@(private)
walk_node :: proc(
	infos: []Block_Info,
	data: []u8,
	h: ^Header,
	visited: []bool,
	idx: int,
	parent_world: matrix[4, 4]f32,
	under_hinge: bool,
	out: ^[dynamic]PlacedShape,
	is_root := false,
) {
	if idx < 0 || idx >= len(infos) {
		return
	}
	if visited[idx] {
		return // already emitted (shared child / cycle) — don't duplicate or loop
	}
	visited[idx] = true
	info := infos[idx]
	if !info.is_node && !info.is_shape {
		return
	}
	// The ROOT node's own local transform is the object's base placement, which the REFR
	// transform supersedes — so ignore it (start its children at the parent/identity frame).
// Nearly every mesh's root is identity, so this is a no-op there; it matters for the rare
	// mesh that bakes a rotation onto the root (e.g. Clutter\CounterSet\CounterCornerIn01, root
	// Rz+90 — applying it sent its corner the wrong way).
	world := parent_world if is_root else parent_world * transform_to_mat4(info.transform)

	if Debug_Nodes {
		t := info.transform
		r := t.rotation
		dbg_printf(
			"node[%d] %q type=%q shape=%v  t=(%.1f,%.1f,%.1f) scale=%.3f\n    R=[%.3f %.3f %.3f][%.3f %.3f %.3f][%.3f %.3f %.3f]\n    world_t=(%.1f,%.1f,%.1f)\n",
			idx,
			block_name(h, info),
			block_type(h, idx),
			info.is_shape,
			t.translation.x, t.translation.y, t.translation.z, t.scale,
			r[0, 0], r[0, 1], r[0, 2], r[1, 0], r[1, 1], r[1, 2], r[2, 0], r[2, 1], r[2, 2],
			world[0, 3], world[1, 3], world[2, 3],
		)
	}

	if info.is_shape {
		g: Geometry
		lod_tris := info.lod_tris
		gok: bool
		if info.inline_geom {
			// SSE BSTriShape family: packed geometry inside the shape block itself
			// (BSMeshLODTriShape's per-level counts trail the data — take them here).
			g, lod_tris, gok = parse_bs_geometry(block_data(h, data, idx), h.bs_version, block_type(h, idx))
		} else if dr := int(info.data_ref);
		   dr >= 0 && dr < int(h.num_blocks) && block_type(h, dr) == "NiTriShapeData" {
			// LE: both NiTriShape and BSLODTriShape point at NiTriShapeData geometry.
			g, gok = parse_tri_shape_data(block_data(h, data, dr))
			// Skinned geometry (trees' swaying canopy, banners) keeps its vertices in
			// NiTriShapeData but its triangle list in the NiSkinPartition. Pull the tris
			// from there so the mesh isn't empty — rendered in bind pose (no skinning).
			if gok && len(g.triangles) == 0 && info.skin_ref >= 0 {
				if pidx := skin_partition_block(data, h, int(info.skin_ref)); pidx >= 0 {
					if st, sok := parse_skin_partition_tris(
						block_data(h, data, pidx),
						len(g.vertices),
					); sok {
						g.triangles = st
					}
				}
			}
		}
		if gok {
			// Effect shapes (BSEffectShaderProperty) carry their texture in a Source Texture
			// field (not a texture set) + a controller-driven UV scroll; lit shapes resolve
			// the usual lighting-shader diffuse. Both feed the same `diffuse` (VFS) pipe.
			is_eff := is_effect_shader(h, info.shader_ref)
			diffuse, normal: string
			material := DEFAULT_MATERIAL
			scroll: [2]f32
			if is_eff {
				eff := resolve_effect(data, h, info.shader_ref)
				diffuse, scroll = eff.source, eff.scroll
			} else {
				diffuse, normal, material = resolve_lighting(data, h, info.shader_ref)
			}
			cutoff := resolve_alpha(data, h, info.alpha_ref)
			name := block_name(h, info)
			append(
				out,
				PlacedShape {
					geometry = g,
					world = world,
					diffuse = diffuse,
					normal = normal,
					material = material,
					alpha_cutoff = cutoff,
					lod_tris = lod_tris,
					is_effect = is_eff,
					scroll = scroll,
					name = strings.clone(name),
					under_hinge = under_hinge,
				},
			)
		}
		return
	}
	// A node named "Door" marks the animated hinge subtree: its descendant shapes swing.
	child_hinge := under_hinge || block_name(h, info) == HINGE_NODE
	for c in info.children {
		walk_node(infos, data, h, visited, int(c), world, child_hinge, out)
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
	     "BSTreeNode",
	     "BSBlastNode",
	     "BSDamageStage":
		return true
	}
	return false
}

@(private)
parse_block_info :: proc(h: ^Header, data: []u8, i: int) -> (bi: Block_Info) {
	bi.data_ref = -1
	bi.skin_ref = -1
	bi.shader_ref = -1
	bi.alpha_ref = -1
	bi.collision_ref = -1
	bi.name_ref = -1
	bi.controller_ref = -1
	t := block_type(h, i)
	is_node := is_node_type(t)
	// BSLODTriShape = NiTriShape + trailing LOD-level sizes; identical NiTriBasedGeom
	// layout up through the shader ref (the extra fields come AFTER, so the shared
	// reader is safe). Without it, whole BSLODTriShape-built buildings (e.g. Whiterun's
	// WRHouseStores01) and roof pieces silently load as zero shapes.
	is_shape := t == "NiTriShape" || t == "BSLODTriShape"
	// SSE (BS 100) shapes: geometry is packed inline, refs live in the BSTriShape
	// head instead of a NiGeometry material block. Decoded by parse_bs_geometry.
	is_bs_shape := t == "BSTriShape" ||
	               t == "BSSubIndexTriShape" ||
	               t == "BSMeshLODTriShape" ||
	               t == "BSDynamicTriShape"
	if !is_node && !is_shape && !is_bs_shape {
		return
	}

	r := Reader{data = block_data(h, data, i), ok = true}
	bi.transform, bi.name_ref, bi.controller_ref, bi.collision_ref = parse_avobject(&r)
	if is_bs_shape {
		head := read_bs_head(&r, h.bs_version)
		if r.ok {
			bi.skin_ref = head.skin_ref
			bi.shader_ref = head.shader_ref
			bi.alpha_ref = head.alpha_ref
			bi.inline_geom = true
			bi.is_shape = true
		}
		return
	}
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
		skin := read_i32(&r) // Skin Instance ref
		shader_ref: i32 = -1
		alpha_ref: i32 = -1
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
			alpha_ref = read_i32(&r) // Alpha Property ref (NiAlphaProperty)
		}
		// BSLODTriShape appends 3 per-level triangle counts after the NiTriBasedGeom
		// fields. The referenced NiTriShapeData holds the full, LOD-sorted triangle list.
		lod_tris: [3]u32
		if t == "BSLODTriShape" {
			lod_tris[0] = read_u32(&r)
			lod_tris[1] = read_u32(&r)
			lod_tris[2] = read_u32(&r)
		}
		if r.ok {
			bi.data_ref = dr
			bi.skin_ref = skin
			bi.shader_ref = shader_ref
			bi.alpha_ref = alpha_ref
			bi.lod_tris = lod_tris
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
parse_avobject :: proc(
	r: ^Reader,
) -> (
	t: Transform,
	name_ref: i32,
	controller_ref: i32,
	collision_ref: i32,
) {
	name_ref = read_i32(r) // Name (StringRef into the header string table)
	n_extra := int(read_u32(r)) // Num Extra Data List
	if !r.ok || n_extra < 0 || n_extra > MAX_LIST {
		r.ok = false
		return {}, -1, -1, -1
	}
	for _ in 0 ..< n_extra {
		_ = read_i32(r) // Extra Data refs
	}
	controller_ref = read_i32(r) // Controller (NiTimeController chain root)
	_ = read_u32(r) // Flags

	t.translation = read_vec3(r)
	t.rotation = read_mat3(r)
	t.scale = read_f32(r)
	collision_ref = read_i32(r) // Collision Object (bhkCollisionObject), -1 if none
	return t, name_ref, controller_ref, collision_ref
}

// block_name resolves a block's Name string (from parse_avobject's StringRef) via the header
// string table, or "" if unnamed / out of range. Used to find the "Door" hinge node and the
// "DoorBlack" aperture in door meshes.
@(private)
block_name :: proc(h: ^Header, bi: Block_Info) -> string {
	if bi.name_ref >= 0 && int(bi.name_ref) < len(h.strings) {
		return h.strings[bi.name_ref]
	}
	return ""
}

// Debug_Nodes (dev only): when set, walk_node prints each node's local transform + composed
// world translation — for diagnosing transform conventions. nifdump sets it via --nodes.
Debug_Nodes := false

@(private)
dbg_printf :: proc(format: string, args: ..any) {
	fmt.printf(format, ..args)
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

// skin_partition_block resolves a NiSkinInstance block ref to its NiSkinPartition
// block index (-1 if absent/garbage). NiSkinInstance begins Data ref, then Skin
// Partition ref — and BSDismemberSkinInstance inherits the same prefix, so reading the
// second ref works for both.
@(private)
skin_partition_block :: proc(data: []u8, h: ^Header, skin_ref: int) -> int {
	if skin_ref < 0 || skin_ref >= int(h.num_blocks) {
		return -1
	}
	r := Reader{data = block_data(h, data, skin_ref), ok = true}
	_ = read_i32(&r) // Data ref (NiSkinData)
	part := int(read_i32(&r)) // Skin Partition ref (NiSkinPartition)
	if !r.ok || part < 0 || part >= int(h.num_blocks) {
		return -1
	}
	if block_type(h, part) != "NiSkinPartition" {
		return -1
	}
	return part
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

// bound reads a skeleton's BBX (its BSBound): center and half extents, in game units. For every
// vanilla race it matches the OBND the CK writes on its NPC_, and forums call it the actor's
// living collision shape (build/out/wsP/bbx/bbx_se.txt).
bound :: proc(data: []u8) -> (center, half: [3]f32, ok: bool) {
	h := parse_header(data, context.temp_allocator) or_return
	for i in 0 ..< int(h.num_blocks) {
		if block_type(&h, i) != "BSBound" {continue}
		b := block_data(&h, data, i)
		if len(b) < 28 {return}
		f :: proc(b: []u8, o: int) -> f32 {return transmute(f32)(u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24)}
		return {f(b, 4), f(b, 8), f(b, 12)}, {f(b, 16), f(b, 20), f(b, 24)}, true
	}
	return
}
