package render

// Player-UI render path (backend v2): an own SDL3_gpu 2D pipeline that draws the `ui` package's
// screen-space quads — solid rects (over the 1×1 white texture), font-atlas glyphs, and art images —
// into the swapchain (post) pass, replacing imgui's DrawList for the skinned UI. The app rebuilds a
// vertex/index/batch list each frame (translating ui.Draw_Cmd → UI_Vertex with the right texture per
// run) and hands it over with set_ui_drawlist; render uploads + draws it inside end_frame.
//
// One pipeline draws everything: the fragment shader is vertex_color × texel, the atlas carries
// coverage in alpha, and rects sample white — so the only per-batch state is the bound texture.

import "core:mem"
import sdl "vendor:sdl3"

UI_VERT_SPV :: #load("shaders/ui.vert.spv")
UI_FRAG_SPV :: #load("shaders/ui.frag.spv")

// UI_Vertex is a 2D UI vertex: screen-pixel position, atlas/image UV, and a normalized RGBA colour.
UI_Vertex :: struct {
	pos: [2]f32,
	uv:  [2]f32,
	col: [4]u8,
}
#assert(size_of(UI_Vertex) == 20)

// UI_Batch is a contiguous run of indices drawn with one bound texture (a zero Texture → white).
UI_Batch :: struct {
	tex:         Texture,
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
// end_frame between the scene pass and the post pass). Returns the staging transfer buffers to free
// after the command buffer is submitted (ui2_release_transfers).
@(private)
ui2_upload :: proc(r: ^Renderer) -> (xfer: [2]^sdl.GPUTransferBuffer) {
	n_idx := len(r.ui2_indices)
	n_vtx := len(r.ui2_verts)
	if n_idx == 0 || n_vtx == 0 {
		return
	}
	ui2_ensure_buffers(r, n_vtx, n_idx)

	vsize := u32(n_vtx * size_of(UI_Vertex))
	vtb := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = vsize})
	vptr := sdl.MapGPUTransferBuffer(r.device, vtb, false)
	mem.copy(vptr, raw_data(r.ui2_verts), int(vsize))
	sdl.UnmapGPUTransferBuffer(r.device, vtb)

	isize := u32(n_idx * size_of(u32))
	itb := sdl.CreateGPUTransferBuffer(r.device, {usage = .UPLOAD, size = isize})
	iptr := sdl.MapGPUTransferBuffer(r.device, itb, false)
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

// ui2_draw issues the UI batches into the post (swapchain) pass. Pushes the drawable size for the
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
	g := UI_Globals{screen = screen}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &g, u32(size_of(g)))

	sdl.BindGPUGraphicsPipeline(pass, r.ui2_pipeline)
	vb := sdl.GPUBufferBinding{buffer = r.ui2_vbuf}
	sdl.BindGPUVertexBuffers(pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = r.ui2_ibuf}
	sdl.BindGPUIndexBuffer(pass, ib, ._32BIT)

	for b in r.ui2_batches {
		if b.index_count == 0 {
			continue
		}
		tex := b.tex.tex if b.tex.tex != nil else r.white_tex
		sb := sdl.GPUTextureSamplerBinding{texture = tex, sampler = r.ui2_sampler}
		sdl.BindGPUFragmentSamplers(pass, 0, &sb, 1)
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
	// Straight-alpha blend over the swapchain (the post pass target has no depth/stencil).
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
