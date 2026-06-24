package render

// General mesh path (ROADMAP Iteration 1, Milestone B3): upload arbitrary
// position+normal geometry and draw it with a per-object MVP + model matrix under
// simple N·L shading. This is the path real NIF meshes (src/formats/nif) render
// through, generalizing past the Phase-0 cube.

import smath "../math"
import sdl "vendor:sdl3"

MESH_VERT_SPV :: #load("shaders/mesh.vert.spv")
MESH_FRAG_SPV :: #load("shaders/mesh.frag.spv")
EFFECT_VERT_SPV :: #load("shaders/effect.vert.spv")
EFFECT_FRAG_SPV :: #load("shaders/effect.frag.spv")
HIGHLIGHT_FRAG_SPV :: #load("shaders/highlight.frag.spv")

// Mesh_Vertex is the general vertex: position + normal + diffuse UV.
Mesh_Vertex :: struct {
	pos:    smath.Vec3, // offset 0
	normal: smath.Vec3, // offset 12
	uv:     [2]f32,     // offset 24
}
#assert(size_of(Mesh_Vertex) == 32)

// Mesh_Uniforms mirrors the mesh.vert UBO (set 1, binding 0). light_dir.w carries the
// alpha-test cutoff (the light is a direction, so w was free) — avoids a separate
// fragment uniform buffer (and the descriptor-count fiddliness that comes with it).
// The shader builds mvp itself (vp·model) so it can displace the world position for
// wind before projecting; wind/params drive the shared vegetation sway (zero = no-op).
Mesh_Uniforms :: struct {
	vp:        smath.Mat4,
	model:     smath.Mat4,
	light_dir: [4]f32, // xyz = direction toward light; w = alpha-test cutoff
	wind:      [4]f32, // xy = global wind direction; z = strength; w = speed
	params:    [4]f32, // x = time (seconds); y = per-draw phase
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

// draw_mesh draws `m` with the given view-projection `vp` and world `model` (the shader
// forms mvp = vp·model, and uses model to place + transform normals), lit by `light_dir`
// (world-space direction toward the light), textured by `diffuse`. A zero Texture (no
// diffuse) falls back to a 1x1 white map, so the mesh shows plain shading. `alpha_cutoff`
// in [0,1] discards fragments below that diffuse-alpha (0 = opaque) — foliage leaf
// cutouts. `first_index`/`index_count` draw only a sub-range of the index buffer (count
// 0 = the whole mesh) — a BSLODTriShape LOD level's triangle partition. `wind`/`time`/
// `phase` drive the vegetation sway (zero wind = no displacement). Call between
// begin/end_frame.
draw_mesh :: proc(
	r: ^Renderer,
	m: Mesh,
	vp, model: smath.Mat4,
	light_dir: smath.Vec3,
	diffuse: Texture,
	alpha_cutoff: f32 = 0,
	first_index: u32 = 0,
	index_count: u32 = 0,
	wind: Wind = {},
	time: f32 = 0,
	phase: f32 = 0,
) {
	u := Mesh_Uniforms {
		vp        = vp,
		model     = model,
		light_dir = {light_dir.x, light_dir.y, light_dir.z, alpha_cutoff},
		wind      = {wind.dir.x, wind.dir.y, wind.strength, wind.speed},
		params    = {time, phase, wind.height_cap, 0},
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
	count := index_count if index_count > 0 else m.index_count
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, count, 1, first_index, 0, 0)
}

// Effect_Uniforms mirrors the effect.vert UBO (set 1, binding 0). anim packs the effect's
// UV scroll: xy = scroll speed (tiles/sec, from the BSEffectShaderProperty controller),
// z = elapsed time — the shader slides the UV by anim.xy·anim.z.
Effect_Uniforms :: struct {
	vp:    smath.Mat4,
	model: smath.Mat4,
	anim:  [4]f32,
}

// draw_effect draws `m` as an ADDITIVE effect (BSEffectShaderProperty FX: flowing water,
// fire, light beams): the source `diffuse` scrolled by `scroll` (UV tiles/sec) at `time`
// seconds, additively blended over the scene (effect_pipeline: SRC_ALPHA→ONE, depth-tested,
// no depth write). Draw AFTER opaque geometry. Call between begin_frame and end_frame.
draw_effect :: proc(r: ^Renderer, m: Mesh, vp, model: smath.Mat4, diffuse: Texture, scroll: [2]f32 = {}, time: f32 = 0) {
	u := Effect_Uniforms {
		vp    = vp,
		model = model,
		anim  = {scroll.x, scroll.y, time, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	sdl.BindGPUGraphicsPipeline(r.frame_pass, r.effect_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	tex := diffuse.tex if diffuse.tex != nil else r.white_tex
	tb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.mesh_sampler}
	sdl.BindGPUFragmentSamplers(r.frame_pass, 0, &tb, 1)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

// draw_highlight overdraws `m` in the highlight colour (highlight.frag) for the inspect-
// mode hover. Identical setup to draw_mesh (same vert shader, so pass the SAME wind/time/
// phase to track a swaying mesh), but binds the highlight pipeline (depth LESS_OR_EQUAL,
// no depth write) so it lands exactly over the already-drawn opaque mesh. Call after draw.
draw_highlight :: proc(
	r: ^Renderer,
	m: Mesh,
	vp, model: smath.Mat4,
	light_dir: smath.Vec3,
	diffuse: Texture,
	alpha_cutoff: f32 = 0,
	wind: Wind = {},
	time: f32 = 0,
	phase: f32 = 0,
) {
	u := Mesh_Uniforms {
		vp        = vp,
		model     = model,
		light_dir = {light_dir.x, light_dir.y, light_dir.z, alpha_cutoff},
		wind      = {wind.dir.x, wind.dir.y, wind.strength, wind.speed},
		params    = {time, phase, wind.height_cap, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	sdl.BindGPUGraphicsPipeline(r.frame_pass, r.highlight_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	tex := diffuse.tex if diffuse.tex != nil else r.white_tex
	tb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.mesh_sampler}
	sdl.BindGPUFragmentSamplers(r.frame_pass, 0, &tb, 1)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

// make_highlight_pipeline mirrors the mesh pipeline (mesh.vert + 1 sampler) but with the
// highlight fragment shader, depth compare LESS_OR_EQUAL + no depth WRITE, so it overdraws
// the already-rendered hovered model at the same depth without disturbing it.
@(private)
make_highlight_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, MESH_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, HIGHLIGHT_FRAG_SPV, .FRAGMENT, 1, 0)
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
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS_OR_EQUAL, enable_depth_test = true, enable_depth_write = false},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

// make_effect_pipeline builds the FX pipeline: effect.vert (UV-scroll, 1 uniform buffer) +
// effect.frag (1 sampler). ADDITIVE blend (SRC_ALPHA→ONE, the canonical Skyrim FX alpha)
// with depth test but no depth WRITE, so flowing water / fire / light beams glow over the
// opaque scene without occluding it or each other.
@(private)
make_effect_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, EFFECT_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, EFFECT_FRAG_SPV, .FRAGMENT, 1, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
	}
	// effect.vert reads position + UV (normal is in the vertex but unused).
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, normal))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Mesh_Vertex, uv))},
	}
	color_target := sdl.GPUColorTargetDescription {
		format = r.swapchain_format,
		blend_state = {
			enable_blend = true,
			src_color_blendfactor = .SRC_ALPHA,
			dst_color_blendfactor = .ONE,
			color_blend_op = .ADD,
			src_alpha_blendfactor = .SRC_ALPHA,
			dst_alpha_blendfactor = .ONE,
			alpha_blend_op = .ADD,
		},
	}
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
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		// Depth-tested (occluded by solid geometry) but no depth WRITE (additive FX don't hide
		// each other / what's behind them).
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = false},
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
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
