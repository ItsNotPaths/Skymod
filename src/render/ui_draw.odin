package render

// Player-UI render path (backend v2): an own SDL3_gpu 2D pipeline that draws the `ui` package's
// screen-space quads — solid rects (over the 1×1 white texture), font-atlas glyphs, and art images —
// into the UI pass, replacing imgui's DrawList for the skinned UI. The app rebuilds a
// vertex/index/batch list each frame (translating ui.Draw_Cmd → UI_Vertex with the right texture per
// run) and hands it over with set_ui_drawlist; render uploads + draws it inside end_frame.
//
// One pipeline draws everything: the fragment shader is vertex_color × texel, the atlas carries
// coverage in alpha, and rects sample white — so the only per-batch state is the bound texture.

import "core:mem"
import sdl "vendor:sdl3"

UI_VERT_SPV :: #load("shaders/ui.vert.spv")
UI_FRAG_SPV :: #load("shaders/ui.frag.spv")
BAR_VERT_SPV :: #load("shaders/bar.vert.spv")
BAR_FRAG_SPV :: #load("shaders/bar.frag.spv")

// UI_Vertex is a 2D UI vertex: screen-pixel position, atlas/image UV, and a normalized RGBA colour.
UI_Vertex :: struct {
	pos: [2]f32,
	uv:  [2]f32,
	col: [4]u8,
}
#assert(size_of(UI_Vertex) == 20)

// Batch_Kind selects which pipeline draws a UI_Batch. Textured = the shared vertex_color × texel
// pipeline (rects/glyphs/images). Bar = the dedicated meter-fill pipeline (glossy sheen shader, no
// texture; the fill params ride in `bar`). Batches draw in list order, so a bar's fill sits between
// its track and frame chrome even though they use different pipelines.
Batch_Kind :: enum {
	Textured,
	Bar,
}

// Bar_Params is the meter-fill shader's per-quad uniform (std140: two vec4s → mirrors bar.frag's UBO).
Bar_Params :: struct {
	fill: [4]f32, // rgba fill tint
	mask: [4]f32, // x = value (fill fraction 0..1); y = grows from (0 left, 1 centre, 2 right); zw reserved
}
#assert(size_of(Bar_Params) == 32)

// UI_Batch is a contiguous run of indices drawn with one pipeline. Textured batches bind `tex`
// (a zero Texture → white); Bar batches push `bar` to the fill shader.
UI_Batch :: struct {
	kind:        Batch_Kind,
	tex:         Texture,
	bar:         Bar_Params,
	first_index: u32,
	index_count: u32,
}

@(private)
UI_Globals :: struct {
	screen: [2]f32,
	_pad:   [2]f32,
}

// set_ui_drawlist copies this frame's UI geometry into the renderer (drawn in end_frame). The slices
// are copied, so the caller may free/reuse its buffers immediately. `screen` is the px space the
// quads were laid out in — the vertex shader divides by exactly this (NOT the raw swapchain size) so
// layout and the pixel→NDC map agree even when the framebuffer differs (HiDPI). An empty list clears.
set_ui_drawlist :: proc(r: ^Renderer, verts: []UI_Vertex, indices: []u32, batches: []UI_Batch, screen: [2]f32) {
	clear(&r.ui2_verts)
	clear(&r.ui2_indices)
	clear(&r.ui2_batches)
	append(&r.ui2_verts, ..verts)
	append(&r.ui2_indices, ..indices)
	append(&r.ui2_batches, ..batches)
	r.ui2_screen = screen
}

// white_texture wraps the renderer's 1×1 white fallback as a Texture handle, for UI rect batches.
white_texture :: proc(r: ^Renderer) -> Texture {
	return Texture{tex = r.white_tex}
}

// ui2_ensure_buffers grows the persistent vertex/index GPU buffers to hold at least n elements.
// Release-then-recreate is safe (SDL defers the free until the GPU is done with the old buffer) and
// rare (the menu's geometry is bounded; it only grows once).
@(private)
ui2_ensure_buffers :: proc(r: ^Renderer, nverts, nindices: int) {
	if nverts > r.ui2_vcap {
		if r.ui2_vbuf != nil {sdl.ReleaseGPUBuffer(r.device, r.ui2_vbuf)}
		cap := max(nverts, 1024)
		r.ui2_vbuf = sdl.CreateGPUBuffer(r.device, {usage = {.VERTEX}, size = u32(cap * size_of(UI_Vertex))})
		r.ui2_vcap = cap
	}
	if nindices > r.ui2_icap {
		if r.ui2_ibuf != nil {sdl.ReleaseGPUBuffer(r.device, r.ui2_ibuf)}
		cap := max(nindices, 1536)
		r.ui2_ibuf = sdl.CreateGPUBuffer(r.device, {usage = {.INDEX}, size = u32(cap * size_of(u32))})
		r.ui2_icap = cap
	}
}

// ui2_upload records this frame's vertex/index upload into r.frame_cmd's own copy pass (called in
// end_frame between the scene pass and the UI pass). Returns the staging transfer buffers to free
// after the command buffer is submitted (ui2_release_transfers).
@(private)
ui2_upload :: proc(r: ^Renderer) -> (xfer: [2]^sdl.GPUTransferBuffer) {
	n_idx := len(r.ui2_indices)
	n_vtx := len(r.ui2_verts)
	if n_idx == 0 || n_vtx == 0 {
		return
	}
	ui2_ensure_buffers(r, n_vtx, n_idx)

	// Under GPU-memory pressure (e.g. a huge render-distance load) any of the persistent buffers or
	// the staging transfers / their maps can come back nil. Bail cleanly rather than memcpy into a
	// null mapping and crash — ui2_draw already skips when the buffers are nil, so the UI just misses
	// this frame and recovers once memory frees. (The mesh path logs the underlying reason.)
	vsize := u32(n_vtx * size_of(UI_Vertex))
	isize := u32(n_idx * size_of(u32))
	vtb := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = vsize})
	itb := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = isize})
	vptr := sdl.MapGPUTransferBuffer(r.device, vtb, false) if vtb != nil else nil
	iptr := sdl.MapGPUTransferBuffer(r.device, itb, false) if itb != nil else nil
	if r.ui2_vbuf == nil || r.ui2_ibuf == nil || vptr == nil || iptr == nil {
		if vtb != nil {sdl.ReleaseGPUTransferBuffer(r.device, vtb)}
		if itb != nil {sdl.ReleaseGPUTransferBuffer(r.device, itb)}
		return
	}
	mem.copy(vptr, raw_data(r.ui2_verts), int(vsize))
	sdl.UnmapGPUTransferBuffer(r.device, vtb)
	mem.copy(iptr, raw_data(r.ui2_indices), int(isize))
	sdl.UnmapGPUTransferBuffer(r.device, itb)

	cp := sdl.BeginGPUCopyPass(r.frame_cmd)
	sdl.UploadToGPUBuffer(cp, {transfer_buffer = vtb, offset = 0}, {buffer = r.ui2_vbuf, offset = 0, size = vsize}, false)
	sdl.UploadToGPUBuffer(cp, {transfer_buffer = itb, offset = 0}, {buffer = r.ui2_ibuf, offset = 0, size = isize}, false)
	sdl.EndGPUCopyPass(cp)
	return {vtb, itb}
}

@(private)
ui2_release_transfers :: proc(r: ^Renderer, xfer: [2]^sdl.GPUTransferBuffer) {
	for tb in xfer {
		if tb != nil {sdl.ReleaseGPUTransferBuffer(r.device, tb)}
	}
}

// ui2_draw issues the UI batches into the UI pass. Pushes the drawable size for the
// pixel→clip map, binds the shared pipeline + per-frame buffers, then draws each batch with its
// texture (white fallback for rects).
@(private)
ui2_draw :: proc(r: ^Renderer, pass: ^sdl.GPURenderPass) {
	if len(r.ui2_indices) == 0 || r.ui2_vbuf == nil || r.ui2_ibuf == nil {
		return
	}
	screen := r.ui2_screen
	if screen.x <= 0 || screen.y <= 0 {
		screen = {f32(r.swap_w), f32(r.swap_h)} // fall back to the framebuffer if unset
	}
	// The pixel→NDC screen size is set=1 binding=0 in BOTH the ui and bar vertex shaders, so this one
	// push serves either pipeline for the whole frame.
	g := UI_Globals{screen = screen}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &g, u32(size_of(g)))

	vb := sdl.GPUBufferBinding{buffer = r.ui2_vbuf}
	sdl.BindGPUVertexBuffers(pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = r.ui2_ibuf}
	sdl.BindGPUIndexBuffer(pass, ib, ._32BIT)

	// Track the bound pipeline so we only rebind on a kind change (bars are rare — usually one run of
	// textured batches with the odd bar spliced in). Painter's order is preserved: batches draw in
	// list order regardless of pipeline.
	cur := Batch_Kind.Textured
	sdl.BindGPUGraphicsPipeline(pass, r.ui2_pipeline)
	bound_any := false

	for b in r.ui2_batches {
		if b.index_count == 0 {
			continue
		}
		if b.kind != cur || !bound_any {
			switch b.kind {
			case .Textured:
				sdl.BindGPUGraphicsPipeline(pass, r.ui2_pipeline)
			case .Bar:
				sdl.BindGPUGraphicsPipeline(pass, r.ui2_bar_pipeline)
			}
			cur = b.kind
			bound_any = true
		}
		switch b.kind {
		case .Textured:
			tex := b.tex.tex if b.tex.tex != nil else r.white_tex
			sb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.ui2_sampler}
			sdl.BindGPUFragmentSamplers(pass, 0, &sb, 1)
		case .Bar:
			bp := b.bar
			sdl.PushGPUFragmentUniformData(r.frame_cmd, 0, &bp, u32(size_of(bp)))
		}
		sdl.DrawGPUIndexedPrimitives(pass, b.index_count, 1, b.first_index, 0, 0)
	}
}

@(private)
make_ui_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, UI_VERT_SPV, .VERTEX, 0, 1) // 1 uniform buffer (screen size)
	fshader := create_shader(r.device, UI_FRAG_SPV, .FRAGMENT, 1, 0) // 1 sampler
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(UI_Vertex)), input_rate = .VERTEX},
	}
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(UI_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(UI_Vertex, uv))},
		{location = 2, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(UI_Vertex, col))},
	}
	// Straight-alpha blend over present_tex (the UI pass has no depth/stencil).
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
			num_vertex_attributes = 3,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &color_target, num_color_targets = 1},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

// make_bar_pipeline builds the meter-fill pipeline: same UI_Vertex layout + straight-alpha blend as
// the shared UI pipeline, but the fragment stage is bar.frag (a synthesized glossy cylinder fill, no
// sampler, one uniform buffer of Bar_Params at set=3). The vertex stage is bar.vert (same screen-size
// UBO at set=1 as ui.vert), so ui2_draw's single vertex-uniform push serves both pipelines.
@(private)
make_bar_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, BAR_VERT_SPV, .VERTEX, 0, 1) // 1 uniform buffer (screen size)
	fshader := create_shader(r.device, BAR_FRAG_SPV, .FRAGMENT, 0, 1) // 0 samplers, 1 uniform buffer (Bar_Params)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(UI_Vertex)), input_rate = .VERTEX},
	}
	attrs := [3]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(UI_Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(UI_Vertex, uv))},
		{location = 2, buffer_slot = 0, format = .UBYTE4_NORM, offset = u32(offset_of(UI_Vertex, col))},
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
			num_vertex_attributes = 3,
		},
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		target_info = {color_target_descriptions = &color_target, num_color_targets = 1},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}
