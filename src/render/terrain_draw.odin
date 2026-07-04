package render

// CDLOD terrain draw (terrain pivot, phase 1). A single reusable unit-grid patch (make_terrain_patch)
// is drawn INSTANCED — one instance per quadtree node — with the heightfield sampled in the vertex
// shader (terrain.vert) instead of baked into per-cell meshes. The fragment stage is the SHARED
// mesh.frag, so terrain gets the full lighting + shadow path; terrain.vert just emits the same
// varyings. This collapses thousands of per-cell terrain buffers into one patch mesh + one instance
// buffer, which is the whole point of the pivot (constant allocation, no per-cell GPU churn).

import smath "../math"
import sdl "vendor:sdl3"

TERRAIN_VERT_SPV :: #load("shaders/terrain.vert.spv")
TERRAIN_FRAG_SPV :: #load("shaders/terrain.frag.spv")
TERRAIN_NEAR_VERT_SPV :: #load("shaders/terrain_near.vert.spv")

// Terrain_Instance places the unit patch over a square of world (vertex buffer slot 1, per-instance).
Terrain_Instance :: struct {
	params: [4]f32, // xy = world origin; z = patch size (world units); w = geomorph end distance
}
#assert(size_of(Terrain_Instance) == 16)

// Terrain_Instances is an uploaded patch-placement buffer — opaque handle (buffer + count).
Terrain_Instances :: struct {
	buf:   ^sdl.GPUBuffer,
	count: int,
}

// Terrain_Uniforms mirrors terrain.vert's UBO (set 1, binding 0). cam/morph drive the CDLOD
// geomorph (terrain.vert); terrain_near.vert declares them too but ignores them.
Terrain_Uniforms :: struct {
	vp:    smath.Mat4,
	field: [4]f32, // xy = height-texture world origin; zw = 1 / world extent
	texel: [4]f32, // xy = 1 / texture dims; z = world units per texel; w = height drop
	cam:   [4]f32, // xyz = camera world pos (xy used for the geomorph distance)
	morph: [4]f32, // x = morph start ratio; y = strength (1 = crack-free); zw unused
}

upload_terrain_instances :: proc(r: ^Renderer, instances: []Terrain_Instance) -> Terrain_Instances {
	if len(instances) == 0 {
		return {}
	}
	return {buf = upload_buffer(r.device, {.VERTEX}, bytes_of(instances)), count = len(instances)}
}

release_terrain_instances :: proc(r: ^Renderer, ti: Terrain_Instances) {
	if ti.buf != nil {
		sdl.ReleaseGPUBuffer(r.device, ti.buf)
	}
}

// make_terrain_patch builds the reusable unit grid: (n+1)² verts at grid coords [0,1]² packed into
// pos.xy (the rest of Mesh_Vertex is unused by terrain.vert). Upload once, draw instanced. n ≤ 254
// keeps the vertex count u16-indexable.
make_terrain_patch :: proc(r: ^Renderer, n: int) -> Mesh {
	side := n + 1
	verts := make([]Mesh_Vertex, side * side, context.temp_allocator)
	for j in 0 ..< side {
		for i in 0 ..< side {
			verts[j * side + i] = {pos = {f32(i) / f32(n), f32(j) / f32(n), 0}}
		}
	}
	idx := make([]u16, n * n * 6, context.temp_allocator)
	k := 0
	for j in 0 ..< n {
		for i in 0 ..< n {
			v00 := u16(j * side + i)
			v10 := u16(j * side + i + 1)
			v01 := u16((j + 1) * side + i)
			v11 := u16((j + 1) * side + i + 1)
			idx[k + 0], idx[k + 1], idx[k + 2] = v00, v10, v11
			idx[k + 3], idx[k + 4], idx[k + 5] = v00, v11, v01
			k += 6
		}
	}
	return upload_mesh(r, verts, idx)
}

// draw_terrain instanced-draws the patch `m` over the placements in `ti`: the vertex stage samples
// `height` (R32F world-Z); the fragment stage (terrain.frag) reads the per-cell layer from `index`
// (R8, nearest) and that layer of the `ground` array (mipped), lit by the per-frame lighting UBO
// (set_lighting). Call between begin/end_frame.
draw_terrain :: proc(
	r: ^Renderer,
	m: Mesh,
	ti: Terrain_Instances,
	height, ground, index: Texture,
	u: Terrain_Uniforms,
) {
	if m.vbuf == nil || m.ibuf == nil || ti.buf == nil || ti.count == 0 || height.tex == nil || ground.tex == nil || index.tex == nil {
		return
	}
	uu := u
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &uu, u32(size_of(uu)))
	mp := Material_Params{} // terrain is matte: no spec/emissive
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 1, &mp, u32(size_of(mp)))

	bind_pipeline(r, r.frame_pass, r.terrain_pipeline)
	binds := [2]sdl.GPUBufferBinding{{buffer = m.vbuf}, {buffer = ti.buf}}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &binds[0], 2)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	// Vertex-stage height sampler (set 0). CLAMP (hdr_sampler) — NOT the tiling mesh_sampler:
	// patches that overshoot the worldspace bbox (the quadtree root is power-of-two) must read the
	// edge height, not wrap to the far side of the map (which built cliffs on the north/east edges).
	hb := sdl.GPUTextureSamplerBinding{texture = height.tex, sampler = r.hdr_sampler}
	sdl.BindGPUVertexSamplers(r.frame_pass, 0, &hb, 1)
	bind_terrain_textures(r, ground, index)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, u32(ti.count), 0, 0, 0)
}

// bind_terrain_textures binds the shared terrain.frag samplers: the ground array (trilinear +
// anisotropic), the flat-normal fallback, the CSM shadow array, and the per-cell index (nearest).
@(private)
bind_terrain_textures :: proc(r: ^Renderer, ground, index: Texture) {
	fb := [4]sdl.GPUTextureSamplerBinding {
		{texture = ground.tex, sampler = r.terrain_sampler},
		{texture = r.flat_normal_tex, sampler = r.mesh_sampler},
		{texture = r.shadow_tex, sampler = r.shadow_sampler},
		{texture = index.tex, sampler = r.shadow_sampler},
	}
	sdl.BindGPUFragmentSamplers(r.frame_pass, 0, &fb[0], 4)
}

// draw_terrain_near textures a streamed per-cell terrain mesh `m` (world-space verts, real normals)
// through the SHARED terrain.frag — the ground array + per-cell index + noise blend — so near terrain
// blends like the distant tier instead of showing hard per-quadrant texture seams. One draw, no
// instancing, no vertex height sampler (the mesh already holds real Z).
draw_terrain_near :: proc(r: ^Renderer, m: Mesh, ground, index: Texture, u: Terrain_Uniforms) {
	if m.vbuf == nil || m.ibuf == nil || ground.tex == nil || index.tex == nil {
		return
	}
	uu := u
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &uu, u32(size_of(uu)))
	mp := Material_Params{}
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 1, &mp, u32(size_of(mp)))

	bind_pipeline(r, r.frame_pass, r.terrain_near_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_terrain_textures(r, ground, index)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

@(private)
make_terrain_near_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	// terrain_near.vert: 0 samplers + 1 uniform buffer (set 1). terrain.frag (shared): 4 samplers + 2 UBOs.
	vshader := create_shader(r.device, TERRAIN_NEAR_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, TERRAIN_FRAG_SPV, .FRAGMENT, 4, 2)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
	}
	attrs := mesh_vertex_attrs()
	color_target := sdl.GPUColorTargetDescription{format = r.scene_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 4,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .GREATER, enable_depth_test = true, enable_depth_write = true}, // reversed-Z
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

@(private)
make_terrain_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	// terrain.vert: 1 sampler (set 0: height) + 1 uniform buffer (set 1). terrain.frag: 4 samplers
	// (set 2: ground array + normal + shadow + index) + 2 uniform buffers (set 3: lighting + material).
	vshader := create_shader(r.device, TERRAIN_VERT_SPV, .VERTEX, 1, 1)
	fshader := create_shader(r.device, TERRAIN_FRAG_SPV, .FRAGMENT, 4, 2)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	// Slot 0 = unit-patch vertex (Mesh_Vertex layout, loc 0-3); slot 1 = per-instance placement (loc 4).
	buffers := [2]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
		{slot = 1, pitch = u32(size_of(Terrain_Instance)), input_rate = .INSTANCE},
	}
	base := mesh_vertex_attrs()
	attrs := [5]sdl.GPUVertexAttribute {
		base[0],
		base[1],
		base[2],
		base[3],
		{location = 4, buffer_slot = 1, format = .FLOAT4, offset = 0},
	}
	color_target := sdl.GPUColorTargetDescription{format = r.scene_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 2,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 5,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .GREATER, enable_depth_test = true, enable_depth_write = true}, // reversed-Z
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
