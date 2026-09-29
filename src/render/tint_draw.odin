package render

// See-through flat-colour shapes (NPC capsules): alpha-blended, depth-tested, no depth write.

import smath "../math"
import sdl "vendor:sdl3"

TINT_VERT_SPV :: #load("shaders/tint.vert.spv")
TINT_FRAG_SPV :: #load("shaders/tint.frag.spv")

// draw_tint draws the index range [first, first+count) of world-space `m` in `color` (rgba,
// straight alpha). Call after the opaque scene.
draw_tint :: proc(r: ^Renderer, m: Mesh, vp: smath.Mat4, color: [4]f32, first, count: u32) {
	if m.vbuf == nil || count == 0 {return}
	vp, color := vp, color
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &vp, size_of(vp))
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 0, &color, size_of(color))
	bind_pipeline(r, r.frame_pass, r.tint_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, count, 1, first, 0, 0)
}

@(private)
make_tint_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, TINT_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, TINT_FRAG_SPV, .FRAGMENT, 0, 1)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
	}
	attrs := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .BYTE4_NORM, offset = u32(offset_of(Mesh_Vertex, normal))},
	}
	color_target := sdl.GPUColorTargetDescription {
		format = r.swapchain_format,
		blend_state = {
			enable_blend = true,
			src_color_blendfactor = .SRC_ALPHA,
			dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
			color_blend_op = .ADD,
			src_alpha_blendfactor = .ONE,
			dst_alpha_blendfactor = .ONE_MINUS_SRC_ALPHA,
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
			num_vertex_attributes = 2,
		},
		// Back faces culled so a capsule's far side doesn't double its alpha.
		rasterizer_state = {fill_mode = .FILL, cull_mode = .BACK, front_face = .COUNTER_CLOCKWISE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .GREATER, enable_depth_test = true, enable_depth_write = false}, // reversed-Z
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
