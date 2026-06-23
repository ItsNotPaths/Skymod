package render

// General mesh path (ROADMAP Iteration 1, Milestone B3): upload arbitrary
// position+normal geometry and draw it with a per-object MVP + model matrix under
// simple N·L shading. This is the path real NIF meshes (src/formats/nif) render
// through, generalizing past the Phase-0 cube.

import smath "../math"
import sdl "vendor:sdl3"

MESH_VERT_SPV :: #load("shaders/mesh.vert.spv")
MESH_FRAG_SPV :: #load("shaders/mesh.frag.spv")

// Mesh_Vertex is the general vertex: position + normal + diffuse UV.
Mesh_Vertex :: struct {
	pos:    smath.Vec3, // offset 0
	normal: smath.Vec3, // offset 12
	uv:     [2]f32,     // offset 24
}
#assert(size_of(Mesh_Vertex) == 32)

// Mesh_Uniforms mirrors the mesh.vert UBO (set 1, binding 0).
Mesh_Uniforms :: struct {
	mvp:       smath.Mat4,
	model:     smath.Mat4,
	light_dir: [4]f32,
}

// Mesh is an uploaded GPU mesh — opaque handle for the caller.
Mesh :: struct {
	vbuf:        ^sdl.GPUBuffer,
	ibuf:        ^sdl.GPUBuffer,
	index_count: u32,
}

// upload_mesh uploads vertices + 16-bit indices to the GPU. Release with
// release_mesh.
upload_mesh :: proc(r: ^Renderer, verts: []Mesh_Vertex, indices: []u16) -> Mesh {
	m: Mesh
	m.vbuf = upload_buffer(r.device, {.VERTEX}, bytes_of(verts))
	m.ibuf = upload_buffer(r.device, {.INDEX}, bytes_of(indices))
	m.index_count = u32(len(indices))
	return m
}

release_mesh :: proc(r: ^Renderer, m: Mesh) {
	if m.vbuf != nil {sdl.ReleaseGPUBuffer(r.device, m.vbuf)}
	if m.ibuf != nil {sdl.ReleaseGPUBuffer(r.device, m.ibuf)}
}

// draw_mesh draws `m` with the given clip-space MVP and world `model` (used to
// transform normals), lit by `light_dir` (world-space direction toward the light),
// textured by `diffuse`. A zero Texture (no diffuse) falls back to a 1x1 white map,
// so the mesh shows plain shading. Call between begin_frame and end_frame.
draw_mesh :: proc(r: ^Renderer, m: Mesh, mvp, model: smath.Mat4, light_dir: smath.Vec3, diffuse: Texture) {
	u := Mesh_Uniforms {
		mvp       = mvp,
		model     = model,
		light_dir = {light_dir.x, light_dir.y, light_dir.z, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	sdl.BindGPUGraphicsPipeline(r.frame_pass, r.mesh_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	tex := diffuse.tex if diffuse.tex != nil else r.white_tex
	tb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.mesh_sampler}
	sdl.BindGPUFragmentSamplers(r.frame_pass, 0, &tb, 1)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

@(private)
make_mesh_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	// mesh.vert: 1 uniform buffer (set 1). mesh.frag: 1 sampler (set 2). Counts MUST
	// match the SPIR-V or SDL3_gpu mis-binds / the driver can crash at draw.
	vshader := create_shader(r.device, MESH_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, MESH_FRAG_SPV, .FRAGMENT, 1, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
	}
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Mesh_Vertex, uv))},
	}
	color_target := sdl.GPUColorTargetDescription{format = r.swapchain_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 3,
		},
		// No back-face culling: NIF winding varies, and for a first look we'd rather
		// see every triangle than risk an inside-out mesh vanishing.
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = .D32_FLOAT,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
