package render

// Debug wireframe overlay (physics hitbox view). Draws an already-world-space Mesh as green
// wireframe triangles (fill_mode = LINE), depth-tested so the hitboxes read against the lit
// scene. Reuses Mesh_Vertex buffers (the shader reads only position). Not a shipping path —
// driven by the --celltest collision debug toggle.

import sdl "vendor:sdl3"

WIRE_VERT_SPV :: #load("shaders/wire.vert.spv")
WIRE_FRAG_SPV :: #load("shaders/wire.frag.spv")

@(private)
Wire_Uniforms :: struct {
	vp: matrix[4, 4]f32,
}

// draw_wire renders `m` (world-space verts) as a green wireframe with the given view-proj.
// Call between begin_frame and end_frame, after the opaque scene.
draw_wire :: proc(r: ^Renderer, m: Mesh, vp: matrix[4, 4]f32) {
	if m.vbuf == nil || m.index_count == 0 {
		return
	}
	u := Wire_Uniforms{vp = vp}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, size_of(u))
	bind_pipeline(r, r.frame_pass, r.wire_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

@(private)
make_wire_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, WIRE_VERT_SPV, .VERTEX, 0, 1) // 1 uniform buffer (vp)
	fshader := create_shader(r.device, WIRE_FRAG_SPV, .FRAGMENT, 0, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
	}
	attrs := [1]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, pos))},
	}
	color_target := sdl.GPUColorTargetDescription{format = r.scene_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 1,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = 1,
		},
		rasterizer_state = {fill_mode = .LINE, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		// X-RAY: no depth test, so hitboxes draw OVER the lit scene — a dynamic clutter box sits exactly
		// inside its visual mesh (coincident), so a depth-tested wire would be fully occluded/z-fought and
		// invisible. Drawing on top shows every collision box through the models (the whole point of the view).
		depth_stencil_state = {enable_depth_test = false, enable_depth_write = false},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
