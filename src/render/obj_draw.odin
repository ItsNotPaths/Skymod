package render

// Instanced static-object draw (ROADMAP object-LOD tier 2). Distant statics repeat a lot
// (rocks, walls, trees), so each unique model is drawn ONCE per cell as N GPU instances
// from a per-instance world-matrix buffer — instead of one draw per placement. Coarser
// geometry comes from a truncated index range (the BSLODTriShape PREFIX rule); the
// fragment stage is the shared mesh.frag (alpha-test for tree leaves). Mirrors the grass
// path; opaque handles keep callers off the SDL3_gpu types.

import smath "../math"
import sdl "vendor:sdl3"

OBJ_VERT_SPV :: #load("shaders/obj.vert.spv")

// Obj_Instance is one placement's full world matrix (vertex buffer slot 1, per-instance,
// uploaded as four vec4 columns). Computed CPU-side via smath.trs (proven placement).
Obj_Instance :: struct {
	world: smath.Mat4,
}
#assert(size_of(Obj_Instance) == 64)

// Obj_Instances is an uploaded placement buffer — opaque handle (buffer + count).
Obj_Instances :: struct {
	buf:   ^sdl.GPUBuffer,
	count: int,
}

// Obj_Uniforms mirrors the obj.vert UBO (set 1, binding 0).
Obj_Uniforms :: struct {
	vp:          smath.Mat4,
	model_local: smath.Mat4,
	mtl:         [4]f32, // x = alpha-test cutoff; y = fade-in
}

upload_obj_instances :: proc(r: ^Renderer, instances: []Obj_Instance) -> Obj_Instances {
	if len(instances) == 0 {
		return {}
	}
	return {buf = upload_buffer(r.device, {.VERTEX}, bytes_of(instances)), count = len(instances)}
}

// upload_obj_instances_into records an instance-buffer upload into an OPEN Upload_Batch (one
// command buffer + submit for the whole batch). Use it to upload many buffers at once — e.g. the
// load-time object-LOD bake's per-quad buffers — instead of a submit per buffer (which would
// hammer the driver). Pair with render.upload_begin / upload_end.
upload_obj_instances_into :: proc(b: ^Upload_Batch, instances: []Obj_Instance) -> Obj_Instances {
	if len(instances) == 0 {
		return {}
	}
	return {buf = upload_buffer_into(b, {.VERTEX}, bytes_of(instances)), count = len(instances)}
}

release_obj_instances :: proc(r: ^Renderer, oi: Obj_Instances) {
	if oi.buf != nil {
		sdl.ReleaseGPUBuffer(r.device, oi.buf)
	}
}

// draw_obj instanced-draws the placements in `oi` of base mesh `m`, with view-projection
// `vp` and the NIF shape's internal `model_local`, textured by `diffuse` (alpha-tested at
// `alpha_cutoff`). `index_count` (0 = whole mesh) selects a coarse LOD level's triangle prefix.
// Call between begin_frame and end_frame.
draw_obj :: proc(
	r: ^Renderer,
	m: Mesh,
	oi: Obj_Instances,
	vp, model_local: smath.Mat4,
	diffuse: Texture,
	alpha_cutoff: f32,
	index_count: u32,
	fade: f32 = 1,
	first_instance: u32 = 0,
	inst_count: u32 = 0, // 0 = all of oi; else draw a sub-range [first_instance, +inst_count) of a merged buffer
) {
	if oi.buf == nil || oi.count == 0 || m.vbuf == nil || m.ibuf == nil {
		return
	}
	u := Obj_Uniforms {
		vp          = vp,
		model_local = model_local,
		mtl         = {alpha_cutoff, fade, 0, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	// Opaque batches (rocks/walls, no alpha test) → backface-culled; tree/leaf batches stay two-sided.
	bind_pipeline(r, r.frame_pass, r.obj_pipeline_culled if alpha_cutoff == 0 else r.obj_pipeline)
	binds := [2]sdl.GPUBufferBinding{{buffer = m.vbuf}, {buffer = oi.buf}}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &binds[0], 2)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_diffuse(r, diffuse)
	count := index_count if index_count > 0 else m.index_count
	// inst_count/first_instance let one merged instance buffer be drawn as per-model sub-ranges
	// (cross-cell batching): the per-instance attributes are fetched at (first_instance + i), so
	// each model's draw reads only its own contiguous block. 0 = the whole buffer (single-cell use).
	n := inst_count if inst_count > 0 else u32(oi.count)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, count, n, 0, 0, first_instance)
}

// make_obj_pipeline builds the instanced distant-object pipeline with the given cull mode. `cull`
// = .NONE two-sided (tree/leaf cutout batches); .BACK for the opaque-only variant
// (obj_pipeline_culled) that draw_obj routes cutoff==0 batches through.
@(private)
make_obj_pipeline :: proc(r: ^Renderer, cull: sdl.GPUCullMode) -> ^sdl.GPUGraphicsPipeline {
	// obj.vert: 1 uniform buffer (set 1). mesh.frag (shared): 1 sampler.
	vshader := create_shader(r.device, OBJ_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, MESH_FRAG_SPV, .FRAGMENT, 1, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	// Slot 0 = base mesh vertex (loc 0, 2); slot 1 = per-instance world matrix (4 vec4 columns,
	// loc 4-7).
	buffers := [2]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Mesh_Vertex)), input_rate = .VERTEX},
		{slot = 1, pitch = u32(size_of(Obj_Instance)), input_rate = .INSTANCE},
	}
	base := mesh_vertex_attrs()
	attrs := [6]sdl.GPUVertexAttribute {
		base[0],
		base[1],
		{location = 4, buffer_slot = 1, format = .FLOAT4, offset = 0},
		{location = 5, buffer_slot = 1, format = .FLOAT4, offset = 16},
		{location = 6, buffer_slot = 1, format = .FLOAT4, offset = 32},
		{location = 7, buffer_slot = 1, format = .FLOAT4, offset = 48},
	}
	color_target := sdl.GPUColorTargetDescription{format = r.swapchain_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		vertex_input_state = {
			vertex_buffer_descriptions = &buffers[0],
			num_vertex_buffers = 2,
			vertex_attributes = &attrs[0],
			num_vertex_attributes = len(attrs),
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = cull, front_face = MESH_CULL_FRONT_FACE},
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
