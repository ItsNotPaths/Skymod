package render

// Cascaded shadow-map caster pass (ROADMAP full-scene-lighting Phase D). Renders shadow casters
// depth-only into the shadow texture array (one layer per cascade) from the sun's point of view,
// on the FRAME command buffer (between frame_acquire and scene_begin), so the depth-array write →
// sampler read happens within ONE command buffer and SDL3_gpu inserts the layout barrier — a
// SEPARATE shadow command buffer faulted the Intel Vulkan driver (cross-submit hazard). Runs that
// skip shadows (interiors, lodtest/doortest) just don't call these, and mesh.frag skips sampling.
//
// Usage per frame (app, after frame_acquire, before scene_begin):
//   for c in 0..<render.SHADOW_CASCADES {
//       render.shadow_cascade(&r, c)
//       ... render.draw_shadow(&r, mesh, light_vp[c], model) ...   // casters, culled by the app
//       render.shadow_cascade_end(&r)
//   }

import smath "../math"
import sdl "vendor:sdl3"

// shadow_cascade opens a depth-only render pass (on the frame command buffer) writing the given
// cascade's layer of the shadow array (cleared to far). Draw casters, then shadow_cascade_end.
shadow_cascade :: proc(r: ^Renderer, cascade: int) {
	depth := sdl.GPUDepthStencilTargetInfo {
		texture     = r.shadow_tex,
		layer       = u8(cascade),
		clear_depth = 1.0,
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	r.shadow_pass = sdl.BeginGPURenderPass(r.frame_cmd, nil, 0, &depth)
	r.bound_pipeline = nil // new pass — bound pipeline state is invalidated
}

// draw_shadow renders `m` depth-only (OPAQUE caster) into the current cascade pass, placed by
// `model` and the cascade's `light_vp`. Opaque statics use model = inst.world·local; terrain uses
// identity; tree canopy hulls (proxies) cast through here too.
draw_shadow :: proc(r: ^Renderer, m: Mesh, light_vp, model: smath.Mat4) {
	if r.shadow_pass == nil || m.vbuf == nil {
		return
	}
	u := Shadow_Uniforms{light_vp = light_vp, model = model}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))
	bind_pipeline(r, r.shadow_pass, r.shadow_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.shadow_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.shadow_pass, ib, ._16BIT)
	sdl.DrawGPUIndexedPrimitives(r.shadow_pass, m.index_count, 1, 0, 0, 0)
}

// draw_shadow_alpha renders `m` depth-only as an ALPHA-TESTED caster: the diffuse `diffuse` is
// sampled and fragments below `cutoff` are discarded, so foliage casts cutout-shaped shadows
// (full mode / blacklisted trees). A zero Texture falls back to white (no discard).
draw_shadow_alpha :: proc(r: ^Renderer, m: Mesh, light_vp, model: smath.Mat4, diffuse: Texture, cutoff: f32) {
	if r.shadow_pass == nil || m.vbuf == nil {
		return
	}
	u := Shadow_Uniforms{light_vp = light_vp, model = model, params = {cutoff, 0, 0, 0}}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))
	bind_pipeline(r, r.shadow_pass, r.shadow_alpha_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.shadow_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.shadow_pass, ib, ._16BIT)
	tex := diffuse.tex if diffuse.tex != nil else r.white_tex
	tb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.mesh_sampler}
	sdl.BindGPUFragmentSamplers(r.shadow_pass, 0, &tb, 1)
	sdl.DrawGPUIndexedPrimitives(r.shadow_pass, m.index_count, 1, 0, 0, 0)
}

shadow_cascade_end :: proc(r: ^Renderer) {
	if r.shadow_pass != nil {
		sdl.EndGPURenderPass(r.shadow_pass)
		r.shadow_pass = nil
	}
}

// make_shadow_pipeline builds the OPAQUE depth-only caster pipeline (shadow.frag = no samplers).
@(private)
make_shadow_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	return make_shadow_pipeline_common(r, SHADOW_FRAG_SPV, 0)
}

// make_shadow_alpha_pipeline builds the ALPHA-TESTED depth-only caster (shadow_alpha.frag samples
// the diffuse, 1 sampler set 2) — for foliage cutout shadows.
@(private)
make_shadow_alpha_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	return make_shadow_pipeline_common(r, SHADOW_ALPHA_FRAG_SPV, 1)
}

// make_shadow_pipeline_common: shadow.vert (1 uniform buffer, set 1) + the given fragment shader
// (num_samplers samplers, set 2). No color target, depth test+write into SHADOW_FORMAT. Vertex
// layout = position (loc 0) + UV (loc 2) so the alpha caster can discard by diffuse alpha.
@(private = "file")
make_shadow_pipeline_common :: proc(r: ^Renderer, frag: []u8, num_samplers: u32) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, SHADOW_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, frag, .FRAGMENT, num_samplers, 0)
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
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Mesh_Vertex, uv))},
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
		// Cull NONE (NIF winding varies; depth is correct either way — acne handled by bias).
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {depth_stencil_format = SHADOW_FORMAT, has_depth_stencil_target = true},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
