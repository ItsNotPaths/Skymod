package render

// Stencil portals (ROADMAP open interiors). Render the interior cell behind a load door
// THROUGH the doorway opening, with no load screen, using the stencil buffer as a mask:
//
//   1. draw the exterior scene normally (stencil cleared to 0 by begin_frame);
//   2. draw_portal_mark  — the doorway quad, depth-tested so a nearer wall hides it; where
//      it passes, write stencil = 1 (the visible opening). No color, no depth write;
//   3. draw_portal_reset — stamp depth = FAR (1.0) where stencil == 1, so the interior
//      isn't depth-rejected by whatever exterior geometry sat behind the door;
//   4. draw_mesh_stencil  — the interior meshes (from a virtual camera relayed through the
//      door), drawn ONLY where stencil == 1, depth-tested normally among themselves.
//
// These pipelines exist only when the depth target carries a stencil aspect (see
// pick_depth_format); on a stencil-less fallback they are nil and the portal draws no-op.

import smath "../math"
import sdl "vendor:sdl3"

PORTAL_VERT_SPV :: #load("shaders/portal.vert.spv")
PORTAL_FRAG_SPV :: #load("shaders/portal.frag.spv")
PORTAL_FAR_FRAG_SPV :: #load("shaders/portal_far.frag.spv")

// PORTAL_STENCIL_REF is the stencil value the doorway region is marked with (and the value
// the depth-reset + interior draws test for). Any non-zero value works.
PORTAL_STENCIL_REF :: u8(1)

// Portal_Uniforms mirrors the portal.vert UBO (set 1, binding 0): just the MVP for the quad.
Portal_Uniforms :: struct {
	mvp: smath.Mat4,
}

// portals_enabled reports whether the stencil-portal pipelines were built (the depth target
// has a stencil aspect). Callers should skip portal draws when false.
portals_enabled :: proc(r: ^Renderer) -> bool {
	return r.portal_mark_pipeline != nil
}

// draw_portal_mark marks the doorway quad into the stencil buffer (= PORTAL_STENCIL_REF)
// where it is the nearest surface (depth-tested, no depth write). `quad` is a world-space
// doorway rectangle (build it with upload_mesh); `vp` is the exterior camera's view-proj.
draw_portal_mark :: proc(r: ^Renderer, quad: Mesh, vp: smath.Mat4) {
	draw_portal_quad(r, r.portal_mark_pipeline, quad, vp)
}

// draw_portal_reset stamps depth = FAR across the marked (stencil == ref) doorway region so
// the interior drawn next clears the exterior depth behind the door. Call after draw_portal_mark.
draw_portal_reset :: proc(r: ^Renderer, quad: Mesh, vp: smath.Mat4) {
	draw_portal_quad(r, r.portal_reset_pipeline, quad, vp)
}

@(private = "file")
draw_portal_quad :: proc(r: ^Renderer, pipeline: ^sdl.GPUGraphicsPipeline, quad: Mesh, vp: smath.Mat4) {
	if pipeline == nil {
		return
	}
	u := Portal_Uniforms{mvp = vp}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))
	sdl.SetGPUStencilReference(r.frame_pass, PORTAL_STENCIL_REF)
	bind_pipeline(r, r.frame_pass, pipeline)
	vb := sdl.GPUBufferBinding{buffer = quad.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = quad.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, quad.index_count, 1, 0, 0, 0)
}

// draw_mesh_stencil draws `m` exactly like draw_mesh (same mesh.vert/frag, alpha
// cutoff) but through the mesh_stencil_pipeline, which renders ONLY where the stencil equals
// PORTAL_STENCIL_REF — i.e. inside the marked doorway opening. Use it to draw an interior
// cell's shapes with the relayed virtual-camera `vp`. Call after draw_portal_reset.
draw_mesh_stencil :: proc(
	r: ^Renderer,
	m: Mesh,
	vp, model: smath.Mat4,
	diffuse: Texture,
	alpha_cutoff: f32 = 0,
) {
	if r.mesh_stencil_pipeline == nil || m.vbuf == nil || m.ibuf == nil {
		return
	}
	u := Mesh_Uniforms {
		vp     = vp,
		model  = model,
		mtl    = {alpha_cutoff, 1, 0, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))
	sdl.SetGPUStencilReference(r.frame_pass, PORTAL_STENCIL_REF)
	bind_pipeline(r, r.frame_pass, r.mesh_stencil_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_diffuse(r, diffuse)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

// --- pipelines (SDL3_gpu only beyond this line) ---

// portal_quad_vertex_input describes the doorway quad's vertex layout: it reuses the
// Mesh_Vertex buffer (so upload_mesh builds it) but binds only position (location 0).
@(private = "file")
portal_quad_buffers := [1]sdl.GPUVertexBufferDescription {
	{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
}
@(private = "file")
portal_quad_attrs := [1]sdl.GPUVertexAttribute {
	{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, pos))},
}

// no_color_target is a swapchain-format color target with all channel writes masked off —
// the portal mark/reset passes touch only depth + stencil.
@(private = "file")
no_color_target :: proc(r: ^Renderer) -> sdl.GPUColorTargetDescription {
	return {
		format = r.swapchain_format,
		blend_state = {enable_color_write_mask = true, color_write_mask = {}},
	}
}

// make_portal_mark_pipeline: draw the quad, depth-test LESS (no write); where it passes,
// REPLACE stencil with the reference value. ALWAYS stencil-compare means the gate is purely
// the depth test (door must be the nearest surface), so depth_fail keeps stencil at 0.
@(private)
make_portal_mark_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, PORTAL_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, PORTAL_FRAG_SPV, .FRAGMENT, 0, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	mark := sdl.GPUStencilOpState {
		compare_op    = .ALWAYS,
		pass_op       = .REPLACE, // passed depth + stencil → write the reference
		fail_op       = .KEEP,
		depth_fail_op = .KEEP, // door occluded by a nearer wall → leave stencil 0
	}
	color := no_color_target(r)
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &portal_quad_buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &portal_quad_attrs[0],
			num_vertex_attributes = 1,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {
			compare_op = .GREATER, // reversed-Z (door must be the nearest surface)
			enable_depth_test = true,
			enable_depth_write = false,
			enable_stencil_test = true,
			compare_mask = 0xFF,
			write_mask = 0xFF,
			front_stencil_state = mark,
			back_stencil_state = mark,
		},
		target_info = {
			color_target_descriptions = &color,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

// make_portal_reset_pipeline: where stencil == ref, write depth = FAR (portal_far.frag's
// gl_FragDepth = 1.0). Depth compare ALWAYS + write on; stencil is tested (EQUAL ref) but
// not modified, so the interior pass still sees the marked region.
@(private)
make_portal_reset_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, PORTAL_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, PORTAL_FAR_FRAG_SPV, .FRAGMENT, 0, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	keep := sdl.GPUStencilOpState {
		compare_op    = .EQUAL,
		pass_op       = .KEEP,
		fail_op       = .KEEP,
		depth_fail_op = .KEEP,
	}
	color := no_color_target(r)
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &portal_quad_buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &portal_quad_attrs[0],
			num_vertex_attributes = 1,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {
			compare_op = .ALWAYS,
			enable_depth_test = true,
			enable_depth_write = true,
			enable_stencil_test = true,
			compare_mask = 0xFF,
			write_mask = 0x00, // don't disturb the marks
			front_stencil_state = keep,
			back_stencil_state = keep,
		},
		target_info = {
			color_target_descriptions = &color,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

// make_mesh_stencil_pipeline mirrors make_mesh_pipeline (mesh.vert + mesh.frag, depth LESS
// test+write, cull NONE) but adds a stencil test EQUAL ref — so interior geometry renders
// only inside the marked doorway opening. Stencil is read, not written.
@(private)
make_mesh_stencil_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, MESH_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, MESH_FRAG_SPV, .FRAGMENT, 1, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	keep := sdl.GPUStencilOpState {
		compare_op    = .EQUAL,
		pass_op       = .KEEP,
		fail_op       = .KEEP,
		depth_fail_op = .KEEP,
	}
	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
	}
	attrs := mesh_vertex_attrs()
	color_target := sdl.GPUColorTargetDescription{format = r.swapchain_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = len(attrs),
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {
			compare_op = .GREATER, // reversed-Z
			enable_depth_test = true,
			enable_depth_write = true,
			enable_stencil_test = true,
			compare_mask = 0xFF,
			write_mask = 0x00,
			front_stencil_state = keep,
			back_stencil_state = keep,
		},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
