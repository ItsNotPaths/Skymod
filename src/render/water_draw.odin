package render

// Stopgap water (per-cell flat plane). Each exterior cell with water draws ONE quad at
// its XCLW height (resolved in gamedb); the depth buffer does the masking for free —
// where terrain rises above the plane it occludes it, where terrain dips below the water
// blends over it. No geometry waves, no normal-map asset, no reflection pass: the look is
// fully PROCEDURAL in water.frag (analytic sum-of-sines normal → fresnel-to-sky + sun
// specular). Drawn in a transparent pass AFTER opaque geometry.
//
// SHARED-LIGHT SEAM: Water_Uniforms carries a minimal scene-light block (sun dir + camera)
// deliberately shaped like the lighting subsystem's eventual UBO, so landing full lighting
// is "populate the block" — not "rewrite this shader's light handling".

import smath "../math"
import sdl "vendor:sdl3"

WATER_VERT_SPV :: #load("shaders/water.vert.spv")
WATER_FRAG_SPV :: #load("shaders/water.frag.spv")

// (hole water-palette :tags (render unclaimed) :sev gap) the palette is hardcoded — WATR is decoded by nothing, so every lake, river and sea shares one look, and there is no reflection pass.
// Water_Uniforms mirrors the water.vert (set 1) + water.frag (set 3) UBO — pushed to both
// stages. All-vec4 so std140 layout is padding-free.
Water_Uniforms :: struct {
	vp:      smath.Mat4,
	cam:     [4]f32, // xyz = camera world position (view dir for fresnel/specular)
	sun:     [4]f32, // xyz = direction toward the sun (the shared-light seam)
	deep:    [4]f32, // rgb = deep-water color; a = base (top-down) opacity
	shallow: [4]f32, // rgb = horizon/sky tint reflected at grazing angles
	params:  [4]f32, // x = time (seconds)
}

// Stopgap water palette (replaced later by the WATR record's authored colors). Deep teal
// seen from above, a lighter sky tint reflected at the horizon.
WATER_DEEP :: [4]f32{0.02, 0.09, 0.12, 0.55}
WATER_SHALLOW :: [4]f32{0.35, 0.55, 0.65, 1.0}

// draw_water draws a cell's flat water quad `m` (world-space verts) under view-projection
// `vp`, with the camera at `cam_pos`, rippling at `time` seconds. The sun direction comes
// from the active scene lighting (set_lighting) — the shared-light seam now populated.
// Transparent pass (depth-tested, no depth write): call AFTER opaque geometry. NOTE: water.frag
// uses fragment uniform slot 0 (same as the lighting UBO), so this overwrites it for any later
// fragment-UBO draw — fine, since water draws after all lit-mesh opaque geometry.
draw_water :: proc(r: ^Renderer, m: Mesh, vp: smath.Mat4, cam_pos: smath.Vec3, time: f32) {
	if r.water_pipeline == nil || m.vbuf == nil {
		return
	}
	sun := r.lighting.sun_dir
	u := Water_Uniforms {
		vp      = vp,
		cam     = {cam_pos.x, cam_pos.y, cam_pos.z, 0},
		sun     = {sun[0], sun[1], sun[2], 0},
		deep    = WATER_DEEP,
		shallow = WATER_SHALLOW,
		params  = {time, 0, 0, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	bind_pipeline(r, r.frame_pass, r.water_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

// make_water_pipeline builds the water pipeline: water.vert (1 uniform buffer, set 1) +
// water.frag (1 uniform buffer, set 3, no sampler). Alpha-blended, depth-tested but NO
// depth write (water is translucent and must not occlude). The quad reuses Mesh_Vertex
// (only position is read; normal/uv ignored).
@(private)
make_water_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, WATER_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, WATER_FRAG_SPV, .FRAGMENT, 0, 1)
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
	color_target := sdl.GPUColorTargetDescription {
		format = r.scene_format,
		blend_state = {
			enable_blend = true,
			src_color_blendfactor = .SRC_ALPHA,
			dst_color_blendfactor = .ONE_MINUS_SRC_ALPHA,
			color_blend_op = .ADD,
			src_alpha_blendfactor = .SRC_ALPHA,
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
			num_vertex_attributes = 1,
		},
		// Two-sided (the surface is seen from above and from underwater) + depth test but
		// no write (translucent — must not occlude what's behind it).
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .GREATER, enable_depth_test = true, enable_depth_write = false}, // reversed-Z (translucent: test, no write)
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
