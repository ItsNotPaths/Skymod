package render

// Instanced grass draw (ROADMAP Section F2 vegetation). One instanced draw call paints
// every scattered cluster of ONE grass type in ONE cell: the base cluster mesh (a small
// NIF, shared via the asset cache) replicated by a per-instance buffer of world placements.
// The fragment stage is mesh.frag (shared) — grass blades are alpha-test cutouts, so this
// rides the same transparency path as foliage. Wind lives in grass.vert (see there).

import smath "../math"
import sdl "vendor:sdl3"

GRASS_VERT_SPV :: #load("shaders/grass.vert.spv")

// Grass_Instance is one scattered cluster placement (vertex buffer slot 1, per-instance).
// Compact: a world position + packed yaw/scale/wind-phase. Hashed per cluster at scatter.
Grass_Instance :: struct {
	pos:   smath.Vec3, // offset 0  — world position on the terrain
	yps:   smath.Vec3, // offset 12 — x=yaw (about Z), y=scale, z=wind phase
}
#assert(size_of(Grass_Instance) == 24)

// Wind is the reusable wind state (grass + trees/foliage; cloth later). A physics sim
// (HDT-SMP-style) would later drive or replace the procedural sway in the vertex shaders.
Wind :: struct {
	dir:        [2]f32, // horizontal direction (need not be normalized)
	strength:   f32,    // tip displacement scale (× height)
	speed:      f32,    // oscillation rate (radians/sec)
	height_cap: f32,    // clamp the height used for amplitude (0 = uncapped) — keeps tall
	                    // shrubs/ferns from over-waving while short flora still scale up
}

// Grass_Uniforms mirrors the grass.vert UBO (set 1, binding 0). Scene lighting is in the
// per-frame fragment lighting UBO (set 3, shared mesh.frag); this carries only the matrices,
// the alpha cutoff (mtl.x), and the wind.
Grass_Uniforms :: struct {
	vp:          smath.Mat4,
	model_local: smath.Mat4,
	mtl:         [4]f32, // x = alpha-test cutoff
	wind:        [4]f32, // xy = direction; z = strength; w = speed
	params:      [4]f32, // x = time (seconds)
}

// Grass_Instances is an uploaded scatter buffer — an opaque handle (like Mesh/Texture)
// so callers outside this package never name the SDL3_gpu buffer type.
Grass_Instances :: struct {
	buf:   ^sdl.GPUBuffer,
	count: int,
}

// upload_grass_instances uploads a scatter buffer to the GPU (release with
// release_grass_instances). A zero-count handle for an empty slice.
upload_grass_instances :: proc(r: ^Renderer, instances: []Grass_Instance) -> Grass_Instances {
	if len(instances) == 0 {
		return {}
	}
	return {buf = upload_buffer(r.device, {.VERTEX}, bytes_of(instances)), count = len(instances)}
}

release_grass_instances :: proc(r: ^Renderer, gi: Grass_Instances) {
	if gi.buf != nil {
		sdl.ReleaseGPUBuffer(r.device, gi.buf)
	}
}

// draw_grass instanced-draws the clusters in `gi` of the base mesh `m`, with view-
// projection `vp` and the grass NIF's internal `model_local`, textured by `diffuse`
// (alpha-tested at `alpha_cutoff`), swaying under `wind` at `time` seconds. Scene lighting
// comes from the per-frame lighting UBO (set_lighting). Call between begin_frame and end_frame.
draw_grass :: proc(
	r: ^Renderer,
	m: Mesh,
	gi: Grass_Instances,
	vp, model_local: smath.Mat4,
	diffuse: Texture,
	alpha_cutoff: f32,
	wind: Wind,
	time: f32,
	normal: Texture = {},
	mat: Material_Params = {},
) {
	if gi.buf == nil || gi.count == 0 {
		return
	}
	u := Grass_Uniforms {
		vp          = vp,
		model_local = model_local,
		mtl         = {alpha_cutoff, 0, 0, 0},
		wind        = {wind.dir.x, wind.dir.y, wind.strength, wind.speed},
		params      = {time, 0, 0, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))
	mp := mat
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 1, &mp, u32(size_of(mp)))

	bind_pipeline(r, r.frame_pass, r.grass_pipeline)
	binds := [2]sdl.GPUBufferBinding{{buffer = m.vbuf}, {buffer = gi.buf}}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &binds[0], 2)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_lit_textures(r, diffuse, normal)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, u32(gi.count), 0, 0, 0)
}

@(private)
make_grass_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	// grass.vert: 1 uniform buffer (set 1). mesh.frag (shared): 2 samplers (set 2) + 2 uniform
	// buffers (set 3: lighting + material). Counts MUST match the SPIR-V or the driver can crash.
	vshader := create_shader(r.device, GRASS_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, MESH_FRAG_SPV, .FRAGMENT, 3, 2)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	// Slot 0 = base mesh vertex (loc 0-3, incl. tangent); slot 1 = grass instance (loc 4-5).
	buffers := [2]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
		{slot = 1, pitch = u32(size_of(Grass_Instance)), input_rate = .INSTANCE},
	}
	base := mesh_vertex_attrs()
	attrs := [6]sdl.GPUVertexAttribute {
		base[0],
		base[1],
		base[2],
		base[3],
		{location = 4, buffer_slot = 1, format = .FLOAT3, offset = u32(offset_of(Grass_Instance, pos))},
		{location = 5, buffer_slot = 1, format = .FLOAT3, offset = u32(offset_of(Grass_Instance, yps))},
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
			num_vertex_attributes = 6,
		},
		// Two-sided (grass blades viewed from any side) + depth test/write (alpha-test
		// discards keep depth correct without sorting).
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
