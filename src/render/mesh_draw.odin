package render

// General mesh path (ROADMAP Iteration 1, Milestone B3): upload arbitrary geometry and draw
// it fullbright with a per-object MVP + model matrix. This is the path real NIF meshes
// (src/formats/nif) render through, generalizing past the Phase-0 cube.

import smath "../math"
import sdl "vendor:sdl3"

MESH_VERT_SPV :: #load("shaders/mesh.vert.spv")
MESH_FRAG_SPV :: #load("shaders/mesh.frag.spv")
EFFECT_VERT_SPV :: #load("shaders/effect.vert.spv")
EFFECT_FRAG_SPV :: #load("shaders/effect.frag.spv")
HIGHLIGHT_FRAG_SPV :: #load("shaders/highlight.frag.spv")

// (hole skinned-pipeline :tags (render unclaimed) :sev blocker) no skinned pipeline — Mesh_Vertex carries no bone indices or weights, and nif/nodes.odin pulls a skin partition for its TRIANGLES only, drawing the mesh in bind pose. No actor, creature, armour or banner can ever move.
// Mesh_Vertex is the general vertex: position + normal + diffuse UV + tangent. The fullbright
// shaders read only position + UV; normal and tangent (snorm8, the authored NIF tangent with
// w = bitangent handedness ±1) stay in the data for a lit renderer. Build vertices with
// mesh_vertex() — direct literals are only for position(+uv)-only geometry (water planes,
// portal quads, wire debug).
Mesh_Vertex :: struct {
	pos:     smath.Vec3, // offset 0
	uv:      [2]f32,     // offset 12
	normal:  [4]i8,      // offset 20 — snorm8 xyz (w unused)
	tangent: [4]i8,      // offset 24 — snorm8 xyz + w = handedness (±1 encodes exactly)
}
#assert(size_of(Mesh_Vertex) == 28)

// mesh_vertex packs f32 inputs into the compact vertex (see Mesh_Vertex). Inputs need not
// be perfectly unit — components clamp; the shaders renormalize.
mesh_vertex :: #force_inline proc(pos: smath.Vec3, normal: smath.Vec3, uv: [2]f32, tangent: [4]f32 = {1, 0, 0, 1}) -> Mesh_Vertex {
	return {
		pos     = pos,
		uv      = uv,
		normal  = {snorm8(normal.x), snorm8(normal.y), snorm8(normal.z), 0},
		tangent = {snorm8(tangent.x), snorm8(tangent.y), snorm8(tangent.z), snorm8(tangent.w)},
	}
}

@(private)
snorm8 :: #force_inline proc(v: f32) -> i8 {
	c := clamp(v, -1, 1) * 127
	return i8(c + 0.5) if c >= 0 else i8(c - 0.5) // round to nearest (the cast truncates)
}

// Mesh_Uniforms mirrors the mesh.vert UBO (set 1, binding 0): the matrices and the alpha-test
// cutoff (mtl.x).
Mesh_Uniforms :: struct {
	vp:    smath.Mat4,
	model: smath.Mat4,
	mtl:   [4]f32, // x = alpha-test cutoff; y = fade-in
}

// Mesh is an uploaded GPU mesh — opaque handle for the caller.
Mesh :: struct {
	vbuf:        ^sdl.GPUBuffer,
	ibuf:        ^sdl.GPUBuffer,
	index_count: u32,
}

// upload_mesh uploads vertices + 16-bit indices to the GPU in ONE copy pass + submit
// (vs the old two). Release with release_mesh.
upload_mesh :: proc(r: ^Renderer, verts: []Mesh_Vertex, indices: []u16) -> Mesh {
	b := upload_begin(r)
	m := upload_mesh_into(&b, verts, indices)
	upload_end(&b)
	return m
}

// upload_mesh_into records a mesh's vertex + index uploads into an open Upload_Batch —
// so a whole model's shapes (and their textures) land in a single submit. Both buffers
// share the batch's copy pass.
upload_mesh_into :: proc(b: ^Upload_Batch, verts: []Mesh_Vertex, indices: []u16) -> Mesh {
	return {
		vbuf        = upload_buffer_into(b, {.VERTEX}, bytes_of(verts)),
		ibuf        = upload_buffer_into(b, {.INDEX}, bytes_of(indices)),
		index_count = u32(len(indices)),
	}
}

release_mesh :: proc(r: ^Renderer, m: Mesh) {
	if m.vbuf != nil {sdl.ReleaseGPUBuffer(r.device, m.vbuf)}
	if m.ibuf != nil {sdl.ReleaseGPUBuffer(r.device, m.ibuf)}
}

// draw_mesh draws `m` fullbright with the given view-projection `vp` and world `model` (the
// shader forms mvp = vp·model). Textured by `diffuse` — a zero Texture (no diffuse) falls back to a 1x1 white map. `alpha_cutoff` in
// [0,1] discards fragments below that diffuse-alpha (0 = opaque) — foliage leaf cutouts.
// `first_index`/`index_count` draw only a sub-range of the index buffer (count 0 = the whole
// mesh) — a BSLODTriShape LOD level's triangle partition. Call between begin/end_frame.
draw_mesh :: proc(
	r: ^Renderer,
	m: Mesh,
	vp, model: smath.Mat4,
	diffuse: Texture,
	alpha_cutoff: f32 = 0,
	first_index: u32 = 0,
	index_count: u32 = 0,
	fade: f32 = 1,
) {
	u := Mesh_Uniforms {
		vp     = vp,
		model  = model,
		mtl    = {alpha_cutoff, fade, 0, 0},
	}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	if m.vbuf == nil || m.ibuf == nil {return} // upload was skipped (GPU-resource pressure) — nothing to draw
	// Opaque geometry (no alpha test) → the backface-culled pipeline; foliage cutouts stay two-sided.
	pl := r.mesh_pipeline_culled if alpha_cutoff == 0 else r.mesh_pipeline
	bind_pipeline(r, r.frame_pass, pl)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_diffuse(r, diffuse)
	count := index_count if index_count > 0 else m.index_count
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, count, 1, first_index, 0, 0)
}

// bind_diffuse binds the diffuse map (slot 0), with the white fallback for a shape with none.
@(private)
bind_diffuse :: proc(r: ^Renderer, diffuse: Texture) {
	tex := diffuse.tex if diffuse.tex != nil else r.white_tex
	tb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.mesh_sampler}
	sdl.BindGPUFragmentSamplers(r.frame_pass, 0, &tb, 1)
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
	if m.vbuf == nil || m.ibuf == nil {return} // upload was skipped (GPU-resource pressure) — nothing to draw
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	bind_pipeline(r, r.frame_pass, r.effect_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_diffuse(r, diffuse)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, m.index_count, 1, 0, 0, 0)
}

// draw_highlight overdraws `m` in the highlight colour (highlight.frag) for the inspect-
// mode hover. Identical setup to draw_mesh (same vert shader), but binds the highlight pipeline (depth LESS_OR_EQUAL,
// no depth write) so it lands exactly over the already-drawn opaque mesh. Call after draw.
draw_highlight :: proc(
	r: ^Renderer,
	m: Mesh,
	vp, model: smath.Mat4,
	diffuse: Texture,
	alpha_cutoff: f32 = 0,
) {
	u := Mesh_Uniforms {
		vp     = vp,
		model  = model,
		mtl    = {alpha_cutoff, 1, 0, 0},
	}
	if m.vbuf == nil || m.ibuf == nil {return} // upload was skipped (GPU-resource pressure) — nothing to draw
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	bind_pipeline(r, r.frame_pass, r.highlight_pipeline)
	vb := sdl.GPUBufferBinding{buffer = m.vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = m.ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	bind_diffuse(r, diffuse)
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
		depth_stencil_state = {compare_op = .GREATER_OR_EQUAL, enable_depth_test = true, enable_depth_write = false}, // reversed-Z
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

// (hole particles :tags (vfx unclaimed) :sev blocker) the FX pipeline draws static additive geometry only — there is no particle system anywhere in src, so every emitter in a NIF is dropped. No fire, smoke, dust, magic or weather precipitation.
// (hole decals :tags (vfx unclaimed) :sev gap) no decals — blood, scorch marks and impact hits have no surface to project onto.
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
	attrs := mesh_vertex_attrs()
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
			num_vertex_attributes = len(attrs),
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		// Depth-tested (occluded by solid geometry) but no depth WRITE (additive FX don't hide
		// each other / what's behind them).
		depth_stencil_state = {compare_op = .GREATER, enable_depth_test = true, enable_depth_write = false}, // reversed-Z (additive FX: test, no write)
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = r.depth_format,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

// mesh_vertex_attrs is the Mesh_Vertex layout the shaders read on buffer slot 0: position(0),
// uv(2). Instanced paths (grass/obj) append their per-instance attrs at location 4+.
@(private)
mesh_vertex_attrs :: proc() -> [2]sdl.GPUVertexAttribute {
	return {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Mesh_Vertex, pos))},
		{location = 2, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Mesh_Vertex, uv))},
	}
}

// make_mesh_pipeline builds the general mesh pipeline with the given cull mode. `cull` = .NONE
// for the two-sided variant (foliage cutouts, and the default first-look path); .BACK for the
// opaque-only variant (mesh_pipeline_culled) that draw_mesh routes solid geometry through. Both
// share mesh.vert/mesh.frag and every other state, so they render identically bar culling.
@(private)
make_mesh_pipeline :: proc(r: ^Renderer, cull: sdl.GPUCullMode) -> ^sdl.GPUGraphicsPipeline {
	// mesh.vert: 1 uniform buffer (set 1). mesh.frag: 1 sampler (diffuse). Counts MUST match the
	// SPIR-V or SDL3_gpu mis-binds / the driver can crash at draw.
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
		// cull .NONE = two-sided (foliage cutout planes seen from both sides); .BACK = opaque-only
		// (front_face = MESH_CULL_FRONT_FACE — flip it there if solid geometry renders inside-out).
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
