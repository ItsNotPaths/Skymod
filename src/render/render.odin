package render

// The rendering boundary (ROADMAP Phase 0, step 3 — "the one rule"): everything
// draws through this Renderer; NOTHING outside this package may import the
// SDL3_gpu API. The GPU backend (SDL3_gpu today) lives entirely behind these
// procedures, so it stays a swappable detail.
//
// Phase 0 scope: a device + swapchain, a depth target, and a textured cube
// (step 4) viewed through a caller-supplied view-projection. The real mesh paths
// (Phase 2) build on this same begin_frame / draw / end_frame shape.

import "core:log"
import "core:mem"
import smath "../math"
import sdl "vendor:sdl3"
import imgui "../../vendor/odin-imgui"
import imgui_sdl3 "../../vendor/odin-imgui/imgui_impl_sdl3"
import imgui_sdlgpu3 "../../vendor/odin-imgui/imgui_impl_sdlgpu3"

// SPIR-V built by build/build_shaders.sh (run before `odin build`). Paths are
// relative to this file; the bytes are embedded into the binary via #load.
CUBE_VERT_SPV :: #load("shaders/cube.vert.spv")
CUBE_FRAG_SPV :: #load("shaders/cube.frag.spv")

// Vertex uniform block — mirrors UBO in cube.vert (set 1, binding 0).
Cube_Uniforms :: struct {
	mvp: smath.Mat4,
}

// Renderer holds the SDL3_gpu backend state — opaque to callers.
Renderer :: struct {
	device:           ^sdl.GPUDevice,
	window:           ^sdl.Window,
	swapchain_format: sdl.GPUTextureFormat,

	cube_pipeline:    ^sdl.GPUGraphicsPipeline,
	mesh_pipeline:    ^sdl.GPUGraphicsPipeline, // general position+normal meshes (B3)
	cube_vbuf:        ^sdl.GPUBuffer,
	cube_ibuf:        ^sdl.GPUBuffer,
	cube_index_count: u32,
	texture:          ^sdl.GPUTexture,
	sampler:          ^sdl.GPUSampler,

	// Mesh texturing (B4): a trilinear/repeat sampler for diffuse maps and a 1x1
	// white fallback for shapes without a diffuse texture.
	mesh_sampler:     ^sdl.GPUSampler,
	white_tex:        ^sdl.GPUTexture,

	depth_tex:        ^sdl.GPUTexture,
	depth_w, depth_h: u32,

	// Per-frame state, valid only between begin_frame and end_frame.
	frame_cmd:        ^sdl.GPUCommandBuffer,
	frame_pass:       ^sdl.GPURenderPass,
	swap_w, swap_h:   u32,

	// Dear ImGui (dev tooling / MVP UI). The SDL3 + SDL_gpu backends are imgui's,
	// and live here because the SDL_gpu one drives the device — this package is the
	// only one allowed to. UI *content* is built elsewhere (src/tools) via the
	// imgui core API, which carries no SDL/GPU dependency.
	ui_enabled:       bool,
	ui_draw_data:     ^imgui.DrawData,
}

// init claims `window` (from the platform layer) for a new SDL3_gpu device and
// builds the Phase-0 pipeline + cube resources. Returns ok=false, with a logged
// reason, on failure.
init :: proc(window: ^sdl.Window) -> (r: Renderer, ok: bool) {
	device := sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil)
	if device == nil {
		log.errorf("render: CreateGPUDevice failed: %s", sdl.GetError())
		return {}, false
	}
	if !sdl.ClaimWindowForGPUDevice(device, window) {
		log.errorf("render: ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		sdl.DestroyGPUDevice(device)
		return {}, false
	}

	r.device = device
	r.window = window
	r.swapchain_format = sdl.GetGPUSwapchainTextureFormat(device, window)

	r.cube_pipeline = make_cube_pipeline(&r)
	if r.cube_pipeline == nil {
		log.errorf("render: cube pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.mesh_pipeline = make_mesh_pipeline(&r)
	if r.mesh_pipeline == nil {
		log.errorf("render: mesh pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	verts, indices := build_cube(1.0)
	r.cube_vbuf = upload_buffer(device, {.VERTEX}, bytes_of(verts[:]))
	r.cube_ibuf = upload_buffer(device, {.INDEX}, bytes_of(indices[:]))
	r.cube_index_count = u32(len(indices))

	r.texture = make_checker_texture(device)
	r.sampler = sdl.CreateGPUSampler(
		device,
		{
			min_filter = .NEAREST,
			mag_filter = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
		},
	)

	// Diffuse maps: trilinear filtering across the mip chain, UVs wrap (Skyrim UVs
	// tile). The white fallback lets draw_mesh texture untextured shapes uniformly.
	r.mesh_sampler = sdl.CreateGPUSampler(
		device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .LINEAR,
			address_mode_u = .REPEAT,
			address_mode_v = .REPEAT,
			max_lod = 1000,
		},
	)
	r.white_tex = make_white_texture(device)
	return r, true
}

shutdown :: proc(r: ^Renderer) {
	if r.sampler != nil {sdl.ReleaseGPUSampler(r.device, r.sampler)}
	if r.texture != nil {sdl.ReleaseGPUTexture(r.device, r.texture)}
	if r.mesh_sampler != nil {sdl.ReleaseGPUSampler(r.device, r.mesh_sampler)}
	if r.white_tex != nil {sdl.ReleaseGPUTexture(r.device, r.white_tex)}
	if r.depth_tex != nil {sdl.ReleaseGPUTexture(r.device, r.depth_tex)}
	if r.cube_vbuf != nil {sdl.ReleaseGPUBuffer(r.device, r.cube_vbuf)}
	if r.cube_ibuf != nil {sdl.ReleaseGPUBuffer(r.device, r.cube_ibuf)}
	if r.cube_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.cube_pipeline)}
	if r.mesh_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.mesh_pipeline)}
	if r.device != nil && r.window != nil {sdl.ReleaseWindowFromGPUDevice(r.device, r.window)}
	if r.device != nil {sdl.DestroyGPUDevice(r.device)}
	r^ = {}
}

// aspect is the current drawable aspect ratio. Valid after begin_frame has run at
// least once this frame (it records the swapchain size).
aspect :: proc(r: ^Renderer) -> f32 {
	if r.swap_h == 0 {
		return 1
	}
	return f32(r.swap_w) / f32(r.swap_h)
}

// begin_frame acquires the swapchain image and opens a render pass that clears the
// color target to `clear` (RGBA, 0..1) and the depth buffer to 1.0. Returns false
// when no image is available this frame (e.g. minimized) — skip drawing and do NOT
// call end_frame.
begin_frame :: proc(r: ^Renderer, clear: [4]f32) -> bool {
	// Finalize the UI's draw data first (balances ui_new_frame even on a dropped
	// frame). PrepareDrawData (below) must run on the cmd buffer BEFORE the pass.
	if r.ui_enabled {
		imgui.Render()
		r.ui_draw_data = imgui.GetDrawData()
	}

	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	if cmd == nil {
		log.errorf("render: AcquireGPUCommandBuffer failed: %s", sdl.GetError())
		return false
	}

	tex: ^sdl.GPUTexture
	w, h: u32
	if !sdl.WaitAndAcquireGPUSwapchainTexture(cmd, r.window, &tex, &w, &h) || tex == nil {
		_ = sdl.SubmitGPUCommandBuffer(cmd)
		return false
	}
	r.swap_w, r.swap_h = w, h
	ensure_depth(r, w, h)

	if r.ui_enabled && r.ui_draw_data != nil {
		imgui_sdlgpu3.PrepareDrawData(r.ui_draw_data, cmd)
	}

	color := sdl.GPUColorTargetInfo {
		texture     = tex,
		clear_color = {clear[0], clear[1], clear[2], clear[3]},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	depth := sdl.GPUDepthStencilTargetInfo {
		texture     = r.depth_tex,
		clear_depth = 1.0,
		load_op     = .CLEAR,
		store_op    = .DONT_CARE,
	}
	r.frame_cmd = cmd
	r.frame_pass = sdl.BeginGPURenderPass(cmd, &color, 1, &depth)
	return true
}

end_frame :: proc(r: ^Renderer) {
	// Dear ImGui draws last, on top of the scene, into the same pass.
	if r.ui_enabled && r.ui_draw_data != nil {
		imgui_sdlgpu3.RenderDrawData(r.ui_draw_data, r.frame_cmd, r.frame_pass, nil)
	}
	sdl.EndGPURenderPass(r.frame_pass)
	_ = sdl.SubmitGPUCommandBuffer(r.frame_cmd)
	r.frame_pass = nil
	r.frame_cmd = nil
	r.ui_draw_data = nil
}

// --- Dear ImGui lifecycle (the SDL3 + SDL_gpu backends live here because the
// SDL_gpu one drives the device). UI content is built in src/tools. ---

ui_init :: proc(r: ^Renderer) {
	imgui.CHECKVERSION()
	imgui.CreateContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}
	imgui.StyleColorsDark()

	imgui_sdl3.InitForSDLGPU(r.window)
	init_info := imgui_sdlgpu3.InitInfo {
		Device               = r.device,
		ColorTargetFormat    = r.swapchain_format,
		MSAASamples          = ._1,
		SwapchainComposition = .SDR,
		PresentMode          = .VSYNC,
	}
	imgui_sdlgpu3.Init(&init_info)
	r.ui_enabled = true
}

// ui_shutdown must run BEFORE shutdown() (the backends need the device alive).
ui_shutdown :: proc(r: ^Renderer) {
	if !r.ui_enabled {
		return
	}
	imgui_sdlgpu3.Shutdown()
	imgui_sdl3.Shutdown()
	imgui.DestroyContext()
	r.ui_enabled = false
}

// ui_process_event forwards an SDL event into Dear ImGui. Wire it as platform's
// event hook so the UI sees mouse/keyboard (signature matches platform.Event_Hook).
ui_process_event :: proc(ev: ^sdl.Event) {
	_ = imgui_sdl3.ProcessEvent(ev)
}

// ui_new_frame opens a Dear ImGui frame. Call once per frame BEFORE building UI
// widgets (src/tools) and before begin_frame.
ui_new_frame :: proc(r: ^Renderer) {
	if !r.ui_enabled {
		return
	}
	imgui_sdlgpu3.NewFrame()
	imgui_sdl3.NewFrame()
	imgui.NewFrame()
}

// ui_capturing reports whether Dear ImGui wants the mouse / keyboard this frame,
// so the caller can stop the camera reacting while the UI is in use. Valid after
// ui_new_frame.
ui_capturing :: proc(r: ^Renderer) -> (mouse, keyboard: bool) {
	if !r.ui_enabled {
		return false, false
	}
	io := imgui.GetIO()
	return io.WantCaptureMouse, io.WantCaptureKeyboard
}

// draw_cube renders the Phase-0 textured cube with `view_proj` (the caller's
// camera matrix; model is identity). Call between begin_frame and end_frame.
draw_cube :: proc(r: ^Renderer, view_proj: smath.Mat4) {
	u := Cube_Uniforms{mvp = view_proj}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	sdl.BindGPUGraphicsPipeline(r.frame_pass, r.cube_pipeline)
	vb := sdl.GPUBufferBinding{buffer = r.cube_vbuf}
	sdl.BindGPUVertexBuffers(r.frame_pass, 0, &vb, 1)
	ib := sdl.GPUBufferBinding{buffer = r.cube_ibuf}
	sdl.BindGPUIndexBuffer(r.frame_pass, ib, ._16BIT)
	tb := sdl.GPUTextureSamplerBinding{texture = r.texture, sampler = r.sampler}
	sdl.BindGPUFragmentSamplers(r.frame_pass, 0, &tb, 1)
	sdl.DrawGPUIndexedPrimitives(r.frame_pass, r.cube_index_count, 1, 0, 0, 0)
}

// --- internals (SDL3_gpu only beyond this line) ---

@(private)
ensure_depth :: proc(r: ^Renderer, w, h: u32) {
	if r.depth_tex != nil && r.depth_w == w && r.depth_h == h {
		return
	}
	if r.depth_tex != nil {
		sdl.ReleaseGPUTexture(r.device, r.depth_tex)
	}
	r.depth_tex = sdl.CreateGPUTexture(
		r.device,
		{
			type = .D2,
			format = .D32_FLOAT,
			usage = {.DEPTH_STENCIL_TARGET},
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	r.depth_w, r.depth_h = w, h
}

@(private)
make_cube_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	// Descriptor counts MUST match the SPIR-V: cube.vert has 1 uniform buffer
	// (set 1), cube.frag has 1 sampler (set 2). SDL3_gpu mis-binds (and the driver
	// can crash at draw) if these are wrong.
	vshader := create_shader(r.device, CUBE_VERT_SPV, .VERTEX, 0, 1)
	fshader := create_shader(r.device, CUBE_FRAG_SPV, .FRAGMENT, 1, 0)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	buffers := [1]sdl.GPUVertexBufferDescription {
		{slot = 0, pitch = u32(size_of(Vertex)), input_rate = .VERTEX},
	}
	attrs := [2]sdl.GPUVertexAttribute {
		{location = 0, buffer_slot = 0, format = .FLOAT3, offset = u32(offset_of(Vertex, pos))},
		{location = 1, buffer_slot = 0, format = .FLOAT2, offset = u32(offset_of(Vertex, uv))},
	}
	color_target := sdl.GPUColorTargetDescription{format = r.swapchain_format}
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
		rasterizer_state = {fill_mode = .FILL, cull_mode = .BACK, front_face = .COUNTER_CLOCKWISE},
		multisample_state = {sample_count = ._1},
		depth_stencil_state = {compare_op = .LESS, enable_depth_test = true, enable_depth_write = true},
		target_info = {
			color_target_descriptions = &color_target,
			num_color_targets = 1,
			depth_stencil_format = .D32_FLOAT,
			has_depth_stencil_target = true,
		},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
}

@(private)
create_shader :: proc(
	device: ^sdl.GPUDevice,
	code: []u8,
	stage: sdl.GPUShaderStage,
	num_samplers, num_uniform_buffers: u32,
) -> ^sdl.GPUShader {
	info := sdl.GPUShaderCreateInfo {
		code_size           = uint(len(code)),
		code                = raw_data(code),
		entrypoint          = "main",
		format              = {.SPIRV},
		stage               = stage,
		num_samplers        = num_samplers,
		num_uniform_buffers = num_uniform_buffers,
	}
	return sdl.CreateGPUShader(device, info)
}

// upload_buffer creates a GPU buffer of `usage` and fills it via a staging
// transfer buffer + copy pass (the standard SDL3_gpu upload dance).
@(private)
upload_buffer :: proc(
	device: ^sdl.GPUDevice,
	usage: sdl.GPUBufferUsageFlags,
	data: []byte,
) -> ^sdl.GPUBuffer {
	size := u32(len(data))
	buf := sdl.CreateGPUBuffer(device, {usage = usage, size = size})

	tb := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	ptr := sdl.MapGPUTransferBuffer(device, tb, false)
	mem.copy(ptr, raw_data(data), int(size))
	sdl.UnmapGPUTransferBuffer(device, tb)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUBuffer(cp, {transfer_buffer = tb, offset = 0}, {buffer = buf, offset = 0, size = size}, false)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	sdl.ReleaseGPUTransferBuffer(device, tb)
	return buf
}

// make_checker_texture builds a small procedural checkerboard (synthetic — no
// game assets) so the cube's UVs are visibly textured.
@(private)
make_checker_texture :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUTexture {
	SIZE :: 256
	CHECK :: 32
	pixels: [SIZE * SIZE * 4]u8
	for y in 0 ..< SIZE {
		for x in 0 ..< SIZE {
			i := (y * SIZE + x) * 4
			if ((x / CHECK) + (y / CHECK)) & 1 == 0 {
				pixels[i + 0], pixels[i + 1], pixels[i + 2] = 210, 210, 215
			} else {
				pixels[i + 0], pixels[i + 1], pixels[i + 2] = 70, 80, 95
			}
			pixels[i + 3] = 255
		}
	}

	tex := sdl.CreateGPUTexture(
		device,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = SIZE,
			height = SIZE,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)

	size := u32(len(pixels))
	tb := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = size})
	ptr := sdl.MapGPUTransferBuffer(device, tb, false)
	mem.copy(ptr, raw_data(pixels[:]), int(size))
	sdl.UnmapGPUTransferBuffer(device, tb)

	cmd := sdl.AcquireGPUCommandBuffer(device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		cp,
		{transfer_buffer = tb, offset = 0, pixels_per_row = SIZE, rows_per_layer = SIZE},
		{texture = tex, w = SIZE, h = SIZE, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	sdl.ReleaseGPUTransferBuffer(device, tb)
	return tex
}

// bytes_of reinterprets a typed slice as a raw byte slice for GPU upload.
@(private)
bytes_of :: proc(s: []$T) -> []byte {
	return (cast([^]byte)raw_data(s))[:len(s) * size_of(T)]
}
