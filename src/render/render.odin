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

// (hole sky :tags (render unclaimed) :sev blocker) no sky — `Sky\` models are skipped as "the sky system's job" and no sky system exists. The horizon is a flat clear colour: no dome, sun disk, moons, stars, clouds or aerial perspective.
// (hole view-model :tags (render unclaimed) :sev gap :needs (skinned-pipeline)) no first-person or third-person view model, because there is no skinned path to draw one through.
// SPIR-V built by build/build_shaders.sh (run before `odin build`). Paths are
// relative to this file; the bytes are embedded into the binary via #load.
CUBE_VERT_SPV :: #load("shaders/cube.vert.spv")
CUBE_FRAG_SPV :: #load("shaders/cube.frag.spv")
POST_VERT_SPV :: #load("shaders/post.vert.spv")
POST_FRAG_SPV :: #load("shaders/post.frag.spv")
SHADOW_VERT_SPV :: #load("shaders/shadow.vert.spv")
SHADOW_FRAG_SPV :: #load("shaders/shadow.frag.spv")
SHADOW_ALPHA_FRAG_SPV :: #load("shaders/shadow_alpha.frag.spv")

// SHADOW_RES is the per-cascade shadow-map resolution (square). SHADOW_FORMAT is its depth format.
SHADOW_RES :: u32(2048)
SHADOW_FORMAT :: sdl.GPUTextureFormat.D32_FLOAT

// Shadow_Uniforms mirrors shadow.vert's UBO (set 1, binding 0): the cascade light view-projection
// and the caster's model matrix.
Shadow_Uniforms :: struct {
	light_vp: smath.Mat4,
	model:    smath.Mat4,
	params:   [4]f32, // x = alpha-test cutoff (0 = opaque caster)
}

// Vertex uniform block — mirrors UBO in cube.vert (set 1, binding 0).
Cube_Uniforms :: struct {
	mvp: smath.Mat4,
}

// SHADOW_CASCADES is the number of cascaded shadow-map slices (Phase D). The app's cascade
// math (app/shadows.odin) references this so the two never diverge.
SHADOW_CASCADES :: 3

// MESH_CULL_FRONT_FACE is the winding the opaque culled pipelines (mesh_pipeline_culled /
// obj_pipeline_culled) treat as front-facing. Skyrim NIF triangle lists have consistent winding,
// so backface culling is a straight win on solid geometry — but the winding after our REFR euler
// (transpose) + coordinate convention is empirical: if opaque statics render INSIDE-OUT or vanish
// wholesale after enabling culling, flip this to .CLOCKWISE (single-line, no other change). Two-
// sided draws (foliage/grass/water) ignore it — they use cull NONE.
MESH_CULL_FRONT_FACE :: sdl.GPUFrontFace.COUNTER_CLOCKWISE

// Light_Env is the per-frame scene-lighting block (ROADMAP full-scene-lighting Phase A) —
// the GPU-facing mirror of the `Light` UBO in mesh.frag (set 3, binding 0, the SDL3_gpu
// Vulkan slot for fragment uniform buffers). All-vec4 so std140 layout is padding-free.
// The app fills this from the active lighting profile each frame (lighting.Light_Profile is
// the rich authored form; this is the flattened render form) and calls set_lighting; the
// renderer pushes it once in begin_frame, so every lit-mesh draw that frame reads it.
Light_Env :: struct {
	sun_dir:        [4]f32, // xyz = direction toward the sun (world); w = albedo_lift (gamma)
	sun_color:      [4]f32, // rgb = sun color; w = sun intensity
	ambient_sky:    [4]f32, // rgb = up-facing ambient; w = ambient floor (min light)
	ambient_ground: [4]f32, // rgb = down-facing ambient; w = ambient intensity
	fog_color:      [4]f32, // rgb = fog/horizon color
	fog_params:     [4]f32, // x = start dist, y = end dist, z = height falloff, w = density
	cam_pos:        [4]f32, // xyz = camera world position (fog distance + specular view dir)
	material:       [4]f32, // x = spec_scale, y = normal_strength, z = emissive_scale, w = foliage_spec (global material remap)
	csm_vp:         [SHADOW_CASCADES]smath.Mat4, // cascade light view-projections (shadow sampling)
	csm_splits:     [4]f32, // x,y,z = far radial distance per cascade
	shadow_params:  [4]f32, // x = strength, y = depth bias, z = PCF texel step, w = cascade count (0 = off)
}

// DEFAULT_LIGHT_ENV reproduces the engine's pre-lighting look EXACTLY (flat ambient 0.3 +
// sun 0.7 · N·L, fog off) so any run that never calls set_lighting (e.g. the lodtest /
// doortest harnesses) still renders correctly. The game overrides it from a profile.
DEFAULT_LIGHT_ENV :: Light_Env {
	sun_dir        = {0.4, 0.6, 1.0, 1.0},
	sun_color      = {1, 1, 1, 0.7},
	ambient_sky    = {0.3, 0.3, 0.3, 0.0},
	ambient_ground = {0.3, 0.3, 0.3, 1.0},
	fog_color      = {0.10, 0.11, 0.13, 0},
	fog_params     = {0, 200000, 0, 0}, // density 0 = no fog
	cam_pos        = {0, 0, 0, 0},
	material       = {1, 1, 1, 1}, // spec_scale, normal_strength, emissive_scale, foliage_spec
}

// Material_Params is the per-DRAW material block (mirror of the `Mat` UBO in mesh.frag, set 3
// binding 1) — the shape's authored specular/glossiness/emissive (Skyrim spec-gloss model). The
// per-frame Light_Env.material carries the GLOBAL remap (spec_scale etc.) applied on top.
Material_Params :: struct {
	spec:     [4]f32, // rgb = specular color; w = specular strength
	emissive: [4]f32, // rgb = emissive color; w = emissive multiple
	params:   [4]f32, // x = glossiness
}

// Post_Params is the HDR post/tonemap block (ROADMAP full-scene-lighting Phase B) — the
// GPU mirror of the `Post` UBO in post.frag (set 3). Filled from the active profile's
// tonemap/grade fields each frame (set_post), pushed in the post pass (end_frame).
Post_Params :: struct {
	params: [4]f32, // x = exposure, y = tonemap mode (0 reinhard / 1 ACES / 2 filmic), z = white point, w = contrast
	grade:  [4]f32, // xyz = color filter (tint); w = saturation
}

// DEFAULT_POST is an identity-ish pass (exposure 1, Reinhard, neutral grade) so harnesses
// that never call set_post still resolve the HDR target sensibly.
DEFAULT_POST :: Post_Params {
	params = {1, 0, 1, 1},
	grade  = {1, 1, 1, 1},
}

// Renderer holds the SDL3_gpu backend state — opaque to callers.
Renderer :: struct {
	device:           ^sdl.GPUDevice,
	window:           ^sdl.Window,
	swapchain_format: sdl.GPUTextureFormat,
	scene_format:     sdl.GPUTextureFormat, // offscreen HDR scene color target format (Phase B)

	// HDR pipeline (Phase B): the scene renders into this offscreen RGBA16F target; the post
	// pass (post_pipeline) samples it (hdr_sampler), tonemaps/grades, and writes the swapchain.
	hdr_tex:          ^sdl.GPUTexture,
	hdr_w, hdr_h:     u32,
	hdr_sampler:      ^sdl.GPUSampler,
	post_pipeline:    ^sdl.GPUGraphicsPipeline,
	post:             Post_Params, // active tonemap/grade (set_post); pushed in the post pass

	// Present cache: the post pass + UI compose into THIS owned texture (swapchain format), then it's
	// BLIT to the acquired swapchain image. So the swapchain is always fully written by a real rendered
	// frame — when it's recreated (e.g. a pointer-lock/grab toggle reconfigures the Wayland surface) the
	// fresh, undefined image can never flash (no checkerboard, no black); the blit covers it entirely,
	// showing this frame. present_tex persists, so it's inherently the last good frame.
	present_tex:      ^sdl.GPUTexture,
	present_w, present_h: u32,

	// Cascaded sun shadows (Phase D): a depth texture array (one layer per cascade) the scene
	// renders casters into (depth-only) before the lit pass samples it. shadow_cmd/shadow_pass
	// are valid only between shadow_begin and shadow_end.
	shadow_tex:       ^sdl.GPUTexture,    // D32 depth array, SHADOW_CASCADES layers
	shadow_sampler:   ^sdl.GPUSampler,    // nearest/clamp (manual PCF taps in mesh.frag)
	shadow_pipeline:  ^sdl.GPUGraphicsPipeline, // depth-only opaque caster (shadow.vert/frag)
	shadow_alpha_pipeline: ^sdl.GPUGraphicsPipeline, // alpha-tested caster (foliage cutouts; shadow_alpha.frag)
	shadow_pass:      ^sdl.GPURenderPass, // cascade depth pass (on frame_cmd, before the scene pass)

	cube_pipeline:    ^sdl.GPUGraphicsPipeline,
	mesh_pipeline:    ^sdl.GPUGraphicsPipeline, // general position+normal meshes (B3); two-sided (foliage cutouts)
	mesh_pipeline_culled: ^sdl.GPUGraphicsPipeline, // OPAQUE variant of mesh_pipeline with backface culling — draw_mesh routes alpha_cutoff==0 draws here (solid architecture/statics), halving rasterized back faces; foliage (cutoff>0) stays two-sided on mesh_pipeline
	grass_pipeline:   ^sdl.GPUGraphicsPipeline, // instanced grass clusters (F2 vegetation)
	obj_pipeline:     ^sdl.GPUGraphicsPipeline, // instanced distant static objects (object LOD); two-sided (tree cutouts)
	obj_pipeline_culled: ^sdl.GPUGraphicsPipeline, // OPAQUE instanced variant: backface culling for cutoff==0 batches (rocks/walls)
	terrain_pipeline: ^sdl.GPUGraphicsPipeline, // CDLOD terrain: height-texture-sampled instanced grid patches
	terrain_near_pipeline: ^sdl.GPUGraphicsPipeline, // streamed per-cell terrain meshes, textured via the shared terrain.frag
	water_pipeline:   ^sdl.GPUGraphicsPipeline, // per-cell flat water planes (procedural, transparent)
	effect_pipeline:  ^sdl.GPUGraphicsPipeline, // alpha-blended ghosted effect shapes
	highlight_pipeline: ^sdl.GPUGraphicsPipeline, // inspect-mode hover highlight overdraw
	wire_pipeline:    ^sdl.GPUGraphicsPipeline, // debug collision-hitbox wireframe overlay (--celltest)
	tint_pipeline:    ^sdl.GPUGraphicsPipeline, // see-through flat-colour shapes (NPC capsules)
	cube_vbuf:        ^sdl.GPUBuffer,
	cube_ibuf:        ^sdl.GPUBuffer,
	cube_index_count: u32,
	texture:          ^sdl.GPUTexture,
	sampler:          ^sdl.GPUSampler,

	// Mesh texturing (B4): a trilinear/repeat sampler for diffuse maps and a 1x1
	// white fallback for shapes without a diffuse texture.
	mesh_sampler:     ^sdl.GPUSampler,
	terrain_sampler:  ^sdl.GPUSampler, // trilinear + anisotropic/repeat for the CDLOD ground array (grazing-angle distance)
	white_tex:        ^sdl.GPUTexture,
	flat_normal_tex:  ^sdl.GPUTexture, // 1x1 {128,128,255} tangent-space "up" — fallback for shapes with no normal map

	depth_tex:        ^sdl.GPUTexture,
	depth_w, depth_h: u32,
	depth_format:     sdl.GPUTextureFormat, // depth(+stencil) target format, chosen at init

	// Open-interiors stencil portals (EXPERIMENTAL): mark the doorway opening into the
	// stencil buffer, reset that region's depth to far, then draw the interior there
	// behind a stencil test. See portal_draw.odin.
	portal_mark_pipeline:  ^sdl.GPUGraphicsPipeline, // door quad → stencil = 1
	portal_reset_pipeline: ^sdl.GPUGraphicsPipeline, // depth → far where stencil == 1
	mesh_stencil_pipeline: ^sdl.GPUGraphicsPipeline, // mesh path, drawn only where stencil == 1

	// Active scene lighting (full-scene-lighting Phase A). Set via set_lighting from the
	// app's current profile; pushed to the fragment lighting UBO once per begin_frame.
	// Initialized to DEFAULT_LIGHT_ENV so harnesses that never set it still render lit.
	lighting:         Light_Env,

	// Redundant-bind elimination: the pipeline currently bound in the active pass. Draw procs bind
	// through bind_pipeline, which skips the SDL call when the requested pipeline is already current
	// — the near mesh path re-selected the SAME pipeline on every shape. Reset to nil at each pass
	// begin (a new BeginGPURenderPass invalidates bound state), so a cross-pass reuse never skips.
	bound_pipeline:   ^sdl.GPUGraphicsPipeline,

	// Per-frame state, valid only between begin_frame and end_frame.
	frame_cmd:        ^sdl.GPUCommandBuffer,
	frame_pass:       ^sdl.GPURenderPass,
	frame_swap_tex:   ^sdl.GPUTexture, // acquired swapchain image (post pass targets it in end_frame)
	swap_w, swap_h:   u32,

	// Dear ImGui (dev tooling / MVP UI). The SDL3 + SDL_gpu backends are imgui's,
	// and live here because the SDL_gpu one drives the device — this package is the
	// only one allowed to. UI *content* is built elsewhere (src/tools) via the
	// imgui core API, which carries no SDL/GPU dependency.
	ui_enabled:       bool,
	ui_draw_data:     ^imgui.DrawData,
	// Is a Dear ImGui frame currently open (NewFrame called, not yet Render/EndFrame'd)? Tracks the
	// lifecycle so it stays balanced even when a load-screen loop (loadui_frame) re-enters ui_new_frame
	// in the MIDDLE of a game_frame that already opened a frame — ui_new_frame closes a superseded
	// frame; frame_acquire only Renders one that's actually open. (Interior/city/F9 loads hit this.)
	ui_frame_open:    bool,

	// Player-facing UI (backend v2): an own SDL3_gpu 2D pipeline that draws the `ui` package's
	// textured/coloured quads (solid rects over white_tex, glyphs over the font atlas, art images)
	// into the swapchain (post) pass — replacing imgui's DrawList for the skinned UI. The vertex /
	// index data is rebuilt each frame (set_ui_drawlist) and uploaded + drawn in end_frame.
	ui2_pipeline:     ^sdl.GPUGraphicsPipeline,
	ui2_bar_pipeline: ^sdl.GPUGraphicsPipeline, // meter-fill (glossy sheen) pipeline; Bar batches
	ui2_sampler:      ^sdl.GPUSampler, // linear/clamp for the atlas + images
	ui2_vbuf:         ^sdl.GPUBuffer,
	ui2_ibuf:         ^sdl.GPUBuffer,
	ui2_vcap:         int, // current GPU vertex-buffer capacity (vertices)
	ui2_icap:         int, // current GPU index-buffer capacity (indices)
	ui2_verts:        [dynamic]UI_Vertex,
	ui2_indices:      [dynamic]u32,
	ui2_batches:      [dynamic]UI_Batch,
	ui2_screen:       [2]f32, // px space the UI was laid out in (the vertex shader's pixel→NDC divisor)
}

// init claims `window` (from the platform layer) for a new SDL3_gpu device and
// builds the Phase-0 pipeline + cube resources. Returns ok=false, with a logged
// reason, on failure.
init :: proc(window: ^sdl.Window) -> (r: Renderer, ok: bool) {
	// Prefer the high-performance, HARDWARE-accelerated GPU. On hybrid boxes (discrete + iGPU, or a
	// software rasterizer like llvmpipe present) the bare CreateGPUDevice can land on the small-VRAM
	// iGPU / CPU renderer, which then runs out of device memory at high render distance ("Failed to
	// bind memory for buffer"). REQUIRE_HARDWARE_ACCELERATION rules out llvmpipe; PREFERLOWPOWER=false
	// asks for the discrete part; VERBOSE makes SDL log the physical device it selected. Fall back to
	// the simple path if the properties device can't be created (e.g. a genuinely software-only host).
	device: ^sdl.GPUDevice
	if props := sdl.CreateProperties(); props != 0 {
		sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_SHADERS_SPIRV_BOOLEAN, true)
		sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_DEBUGMODE_BOOLEAN, ODIN_DEBUG)
		sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_PREFERLOWPOWER_BOOLEAN, false)
		sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_VULKAN_REQUIRE_HARDWARE_ACCELERATION_BOOLEAN, true)
		sdl.SetBooleanProperty(props, sdl.PROP_GPU_DEVICE_CREATE_VERBOSE_BOOLEAN, true)
		device = sdl.CreateGPUDeviceWithProperties(props)
		sdl.DestroyProperties(props)
	}
	if device == nil {
		device = sdl.CreateGPUDevice({.SPIRV}, ODIN_DEBUG, nil) // fallback (software-only host, or older SDL)
	}
	if device == nil {
		log.errorf("render: CreateGPUDevice failed: %s", sdl.GetError())
		return {}, false
	}
	log.infof("render: GPU driver = %s", sdl.GetGPUDeviceDriver(device))
	if !sdl.ClaimWindowForGPUDevice(device, window) {
		log.errorf("render: ClaimWindowForGPUDevice failed: %s", sdl.GetError())
		sdl.DestroyGPUDevice(device)
		return {}, false
	}

	r.device = device
	r.window = window
	r.swapchain_format = sdl.GetGPUSwapchainTextureFormat(device, window)
	r.scene_format = pick_scene_format(device) // offscreen HDR (RGBA16F) target for the post pass
	r.lighting = DEFAULT_LIGHT_ENV
	r.post = DEFAULT_POST

	// Depth target carries a STENCIL aspect (for the open-interiors portals). Prefer the
	// widely-supported D24_S8; fall back to D32F_S8, then plain D32F if a driver somehow
	// lacks a packed stencil format (portals then no-op, but the rest renders).
	r.depth_format = pick_depth_format(device)

	r.cube_pipeline = make_cube_pipeline(&r)
	if r.cube_pipeline == nil {
		log.errorf("render: cube pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.mesh_pipeline = make_mesh_pipeline(&r, .NONE)
	r.mesh_pipeline_culled = make_mesh_pipeline(&r, .BACK)
	if r.mesh_pipeline == nil || r.mesh_pipeline_culled == nil {
		log.errorf("render: mesh pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.grass_pipeline = make_grass_pipeline(&r)
	if r.grass_pipeline == nil {
		log.errorf("render: grass pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.obj_pipeline = make_obj_pipeline(&r, .NONE)
	r.obj_pipeline_culled = make_obj_pipeline(&r, .BACK)
	if r.obj_pipeline == nil || r.obj_pipeline_culled == nil {
		log.errorf("render: obj pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.terrain_pipeline = make_terrain_pipeline(&r)
	if r.terrain_pipeline == nil {
		log.errorf("render: terrain pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.terrain_near_pipeline = make_terrain_near_pipeline(&r)
	if r.terrain_near_pipeline == nil {
		log.errorf("render: terrain-near pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.water_pipeline = make_water_pipeline(&r)
	if r.water_pipeline == nil {
		log.errorf("render: water pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.effect_pipeline = make_effect_pipeline(&r)
	if r.effect_pipeline == nil {
		log.errorf("render: effect pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	r.highlight_pipeline = make_highlight_pipeline(&r)
	r.wire_pipeline = make_wire_pipeline(&r)
	r.tint_pipeline = make_tint_pipeline(&r)
	if r.highlight_pipeline == nil {
		log.errorf("render: highlight pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	// Stencil-portal pipelines (open interiors). Only buildable when the depth target has a
	// stencil aspect; on a stencil-less fallback they stay nil and the portal draws no-op.
	if has_stencil(r.depth_format) {
		r.portal_mark_pipeline = make_portal_mark_pipeline(&r)
		r.portal_reset_pipeline = make_portal_reset_pipeline(&r)
		r.mesh_stencil_pipeline = make_mesh_stencil_pipeline(&r)
		if r.portal_mark_pipeline == nil ||
		   r.portal_reset_pipeline == nil ||
		   r.mesh_stencil_pipeline == nil {
			log.errorf("render: portal pipeline failed: %s", sdl.GetError())
			shutdown(&r)
			return {}, false
		}
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
	// Terrain ground array: trilinear + anisotropic so distant terrain stays sharp at grazing
	// angles instead of smearing/aliasing (the diffuse mesh_sampler is trilinear but isotropic).
	r.terrain_sampler = sdl.CreateGPUSampler(
		device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .LINEAR,
			address_mode_u = .REPEAT,
			address_mode_v = .REPEAT,
			enable_anisotropy = true,
			max_anisotropy = 8,
			max_lod = 1000,
		},
	)
	r.white_tex = make_white_texture(device)
	r.flat_normal_tex = make_flat_normal_texture(device)

	// HDR post: a linear/clamp sampler for the offscreen scene target + the tonemap pipeline.
	r.hdr_sampler = sdl.CreateGPUSampler(
		device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
		},
	)
	r.post_pipeline = make_post_pipeline(&r)
	if r.post_pipeline == nil {
		log.errorf("render: post pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	// Cascaded shadow maps: a depth texture array (one layer per cascade) + a nearest/clamp
	// sampler (manual PCF in the shader) + the depth-only caster pipeline.
	r.shadow_tex = sdl.CreateGPUTexture(
		device,
		{
			type = .D2_ARRAY,
			format = SHADOW_FORMAT,
			usage = {.DEPTH_STENCIL_TARGET, .SAMPLER},
			width = SHADOW_RES,
			height = SHADOW_RES,
			layer_count_or_depth = u32(SHADOW_CASCADES),
			num_levels = 1,
			sample_count = ._1,
		},
	)
	r.shadow_sampler = sdl.CreateGPUSampler(
		device,
		{min_filter = .NEAREST, mag_filter = .NEAREST, address_mode_u = .CLAMP_TO_EDGE, address_mode_v = .CLAMP_TO_EDGE},
	)
	r.shadow_pipeline = make_shadow_pipeline(&r)
	r.shadow_alpha_pipeline = make_shadow_alpha_pipeline(&r)
	if r.shadow_tex == nil ||
	   r.shadow_sampler == nil ||
	   r.shadow_pipeline == nil ||
	   r.shadow_alpha_pipeline == nil {
		log.errorf("render: shadow resources failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}

	// Player UI (v2): LINEAR/clamp sampler, NO mips. Glyphs bake at their display size (font's live
	// atlas), so text samples ~1:1 — no minified mip chain (that's what made small text wobble). Plus
	// the 2D quad pipeline.
	r.ui2_sampler = sdl.CreateGPUSampler(
		device,
		{
			min_filter = .LINEAR,
			mag_filter = .LINEAR,
			mipmap_mode = .NEAREST,
			address_mode_u = .CLAMP_TO_EDGE,
			address_mode_v = .CLAMP_TO_EDGE,
			max_lod = 0,
		},
	)
	r.ui2_pipeline = make_ui_pipeline(&r)
	if r.ui2_pipeline == nil {
		log.errorf("render: ui pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}
	r.ui2_bar_pipeline = make_bar_pipeline(&r)
	if r.ui2_bar_pipeline == nil {
		log.errorf("render: bar pipeline failed: %s", sdl.GetError())
		shutdown(&r)
		return {}, false
	}
	return r, true
}

shutdown :: proc(r: ^Renderer) {
	if r.sampler != nil {sdl.ReleaseGPUSampler(r.device, r.sampler)}
	if r.texture != nil {sdl.ReleaseGPUTexture(r.device, r.texture)}
	if r.mesh_sampler != nil {sdl.ReleaseGPUSampler(r.device, r.mesh_sampler)}
	if r.terrain_sampler != nil {sdl.ReleaseGPUSampler(r.device, r.terrain_sampler)}
	if r.white_tex != nil {sdl.ReleaseGPUTexture(r.device, r.white_tex)}
	if r.flat_normal_tex != nil {sdl.ReleaseGPUTexture(r.device, r.flat_normal_tex)}
	if r.hdr_tex != nil {sdl.ReleaseGPUTexture(r.device, r.hdr_tex)}
	if r.present_tex != nil {sdl.ReleaseGPUTexture(r.device, r.present_tex)}
	if r.hdr_sampler != nil {sdl.ReleaseGPUSampler(r.device, r.hdr_sampler)}
	if r.post_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.post_pipeline)}
	if r.ui2_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.ui2_pipeline)}
	if r.ui2_bar_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.ui2_bar_pipeline)}
	if r.ui2_sampler != nil {sdl.ReleaseGPUSampler(r.device, r.ui2_sampler)}
	if r.ui2_vbuf != nil {sdl.ReleaseGPUBuffer(r.device, r.ui2_vbuf)}
	if r.ui2_ibuf != nil {sdl.ReleaseGPUBuffer(r.device, r.ui2_ibuf)}
	delete(r.ui2_verts)
	delete(r.ui2_indices)
	delete(r.ui2_batches)
	if r.shadow_tex != nil {sdl.ReleaseGPUTexture(r.device, r.shadow_tex)}
	if r.shadow_sampler != nil {sdl.ReleaseGPUSampler(r.device, r.shadow_sampler)}
	if r.shadow_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.shadow_pipeline)}
	if r.shadow_alpha_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.shadow_alpha_pipeline)}
	if r.depth_tex != nil {sdl.ReleaseGPUTexture(r.device, r.depth_tex)}
	if r.cube_vbuf != nil {sdl.ReleaseGPUBuffer(r.device, r.cube_vbuf)}
	if r.cube_ibuf != nil {sdl.ReleaseGPUBuffer(r.device, r.cube_ibuf)}
	if r.cube_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.cube_pipeline)}
	if r.mesh_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.mesh_pipeline)}
	if r.mesh_pipeline_culled != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.mesh_pipeline_culled)}
	if r.grass_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.grass_pipeline)}
	if r.obj_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.obj_pipeline)}
	if r.obj_pipeline_culled != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.obj_pipeline_culled)}
	if r.terrain_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.terrain_pipeline)}
	if r.terrain_near_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.terrain_near_pipeline)}
	if r.water_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.water_pipeline)}
	if r.effect_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.effect_pipeline)}
	if r.highlight_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.highlight_pipeline)}
	if r.wire_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.wire_pipeline)}
	if r.tint_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.tint_pipeline)}
	if r.portal_mark_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.portal_mark_pipeline)}
	if r.portal_reset_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.portal_reset_pipeline)}
	if r.mesh_stencil_pipeline != nil {sdl.ReleaseGPUGraphicsPipeline(r.device, r.mesh_stencil_pipeline)}
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

// frame_acquire acquires the frame command buffer + swapchain image and ensures the offscreen
// targets, but opens NO render pass yet. Returns false when no image is available (minimized) —
// skip the rest of the frame. The SHADOW passes (shadow_cascade/draw_shadow/…) run on this command
// buffer AFTER frame_acquire and BEFORE scene_begin, so the depth-array write → sampler read happens
// within ONE command buffer and SDL3_gpu inserts the barrier (a separate shadow cmd buffer faulted
// the Intel driver). Then call scene_begin to open the lit pass.
frame_acquire :: proc(r: ^Renderer) -> bool {
	// Finalize the UI's draw data first (balances ui_new_frame even on a dropped frame).
	// PrepareDrawData must run on the cmd buffer BEFORE the passes that consume it. Only Render an
	// actually-open frame: a mid-frame load loop may have already closed this game_frame's imgui frame
	// (see ui_new_frame), in which case there's nothing to render (no stale overlay drawn this frame).
	if r.ui_enabled && r.ui_frame_open {
		imgui.Render()
		r.ui_draw_data = imgui.GetDrawData()
		r.ui_frame_open = false
	} else {
		r.ui_draw_data = nil
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
	r.frame_swap_tex = tex
	r.frame_cmd = cmd
	ensure_depth(r, w, h)
	ensure_hdr(r, w, h)
	ensure_present(r, w, h)

	if r.ui_enabled && r.ui_draw_data != nil {
		imgui_sdlgpu3.PrepareDrawData(r.ui_draw_data, cmd)
	}
	return true
}

// scene_begin opens the lit scene pass into the offscreen HDR target (cleared to `clear`) +
// pushes the per-frame lighting. Call after frame_acquire (and after any shadow passes).
scene_begin :: proc(r: ^Renderer, clear: [4]f32) {
	color := sdl.GPUColorTargetInfo {
		texture     = r.hdr_tex,
		clear_color = {clear[0], clear[1], clear[2], clear[3]},
		load_op     = .CLEAR,
		store_op    = .STORE,
	}
	depth := sdl.GPUDepthStencilTargetInfo {
		texture          = r.depth_tex,
		clear_depth      = 0.0, // reversed-Z: far plane = 0 (see perspective_rh_zo_rev)
		load_op          = .CLEAR,
		store_op         = .DONT_CARE,
		stencil_load_op  = .CLEAR,
		stencil_store_op = .STORE,
		clear_stencil    = 0,
	}
	r.frame_pass = sdl.BeginGPURenderPass(r.frame_cmd, &color, 1, &depth)
	r.bound_pipeline = nil // new pass — bound pipeline state is invalidated

	// Per-frame lighting UBO (set 3, binding 0); persists across pipeline binds for the whole
	// command buffer. NOTE: water.frag reuses fragment slot 0 — water draws after lit geometry.
	env := r.lighting
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 0, &env, u32(size_of(env)))
}

// begin_frame is the convenience for callers that don't render shadows (interiors, the lodtest /
// doortest harnesses): acquire + open the scene pass in one call.
begin_frame :: proc(r: ^Renderer, clear: [4]f32) -> bool {
	if !frame_acquire(r) {
		return false
	}
	scene_begin(r, clear)
	return true
}

// set_lighting sets the per-frame scene lighting (sun, ambient, fog, material lift, camera
// position for fog). Call once per frame BEFORE begin_frame, which pushes it. Cheap (a small
// struct copy); the GPU upload is a sub-kilobyte push — live profile editing costs nothing.
set_lighting :: proc(r: ^Renderer, env: Light_Env) {
	r.lighting = env
}

// set_post sets the per-frame HDR post / tonemap parameters (exposure, operator, white point,
// contrast, saturation, color filter). Call before begin_frame; pushed in the post pass.
set_post :: proc(r: ^Renderer, post: Post_Params) {
	r.post = post
}

end_frame :: proc(r: ^Renderer) {
	// Close the scene pass (HDR target), then resolve it to the swapchain through the post /
	// tonemap pass. Dear ImGui draws last, into the post (swapchain) pass — so the UI is NOT
	// tonemapped/graded.
	sdl.EndGPURenderPass(r.frame_pass)

	// Upload this frame's player-UI quads (recorded into THIS command buffer's own copy pass,
	// between the scene pass and the post pass, so SDL3_gpu orders the write before the draw).
	ui_xfer := ui2_upload(r)

	// Compose into the owned present-cache texture, NOT the swapchain directly, then blit it below. The
	// fullscreen triangle covers every pixel, so DONT_CARE is fine here (it's our texture).
	swap := sdl.GPUColorTargetInfo {
		texture  = r.present_tex,
		load_op  = .DONT_CARE,
		store_op = .STORE,
	}
	post_pass := sdl.BeginGPURenderPass(r.frame_cmd, &swap, 1, nil)
	sdl.BindGPUGraphicsPipeline(post_pass, r.post_pipeline)
	sb := sdl.GPUTextureSamplerBinding{texture = r.hdr_tex, sampler = r.hdr_sampler}
	sdl.BindGPUFragmentSamplers(post_pass, 0, &sb, 1)
	pp := r.post
	sdl.PushGPUFragmentUniformData(r.frame_cmd, 0, &pp, u32(size_of(pp)))
	sdl.DrawGPUPrimitives(post_pass, 3, 1, 0, 0) // fullscreen triangle (no vertex buffer)

	// Player UI (v2) draws over the resolved scene, before imgui (dev overlays stay on top).
	ui2_draw(r, post_pass)

	if r.ui_enabled && r.ui_draw_data != nil {
		imgui_sdlgpu3.RenderDrawData(r.ui_draw_data, r.frame_cmd, post_pass, nil)
	}
	sdl.EndGPURenderPass(post_pass)

	// Blit the fully-composed frame onto the acquired swapchain image. This is what guarantees the
	// swapchain is ALWAYS covered by a real rendered frame — a just-recreated (undefined) swapchain image
	// can never flash a checkerboard/garbage, because the blit overwrites every pixel with this frame.
	blit := sdl.GPUBlitInfo {
		source = {texture = r.present_tex, w = r.present_w, h = r.present_h},
		destination = {texture = r.frame_swap_tex, w = r.swap_w, h = r.swap_h},
		load_op = .DONT_CARE, // the blit region is the whole swapchain
		filter = .NEAREST,    // 1:1 same-size copy
	}
	sdl.BlitGPUTexture(r.frame_cmd, blit)

	_ = sdl.SubmitGPUCommandBuffer(r.frame_cmd)
	ui2_release_transfers(r, ui_xfer)
	r.frame_pass = nil
	r.frame_cmd = nil
	r.frame_swap_tex = nil
	r.ui_draw_data = nil
}

// --- Dear ImGui lifecycle (the SDL3 + SDL_gpu backends live here because the
// SDL_gpu one drives the device). UI content is built in src/tools. ---

// EMBED_IMGUI_INI is the dev-panel window layout, BAKED into the binary (like shaders). It's all
// dev-tool chrome that never needs to be edited/persisted, so we ship a good default and disable
// imgui's loose imgui.ini entirely (see ui_init) — nothing is written beside the exe.
@(private = "file")
EMBED_IMGUI_INI :: #load("imgui_layout.ini", string)

ui_init :: proc(r: ^Renderer) {
	imgui.CHECKVERSION()
	imgui.CreateContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .DockingEnable}
	// Load the window layout from the embedded copy, and set IniFilename=nil so imgui neither reads
	// nor writes a loose imgui.ini in the cwd (layouts don't persist across runs — the baked default
	// is the source of truth).
	io.IniFilename = nil
	imgui.LoadIniSettingsFromMemory(cstring(raw_data(EMBED_IMGUI_INI)), uint(len(EMBED_IMGUI_INI)))
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
	// A frame is still open (a mid-game_frame load loop is starting its own screen before the outer
	// frame reached frame_acquire's Render) — close and discard it so this NewFrame doesn't assert.
	if r.ui_frame_open {
		imgui.EndFrame()
		r.ui_frame_open = false
	}
	imgui_sdlgpu3.NewFrame()
	imgui_sdl3.NewFrame()
	imgui.NewFrame()
	r.ui_frame_open = true
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

// ui_typing reports whether an ImGui text field (the console) has the keyboard.
ui_typing :: proc(r: ^Renderer) -> bool {
	return r.ui_enabled && imgui.GetIO().WantTextInput
}

// draw_cube renders the Phase-0 textured cube with `view_proj` (the caller's
// camera matrix; model is identity). Call between begin_frame and end_frame.
draw_cube :: proc(r: ^Renderer, view_proj: smath.Mat4) {
	u := Cube_Uniforms{mvp = view_proj}
	sdl.PushGPUVertexUniformData(r.frame_cmd, 0, &u, u32(size_of(u)))

	bind_pipeline(r, r.frame_pass, r.cube_pipeline)
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
			format = r.depth_format,
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

// pick_scene_format chooses the offscreen scene color format. Prefer RGBA16F (real HDR — lit
// values can exceed 1.0 before tonemap), fall back to RGBA8 (LDR, still tonemapped). Both must
// support COLOR_TARGET + SAMPLER (rendered to, then sampled by the post pass).
@(private)
pick_scene_format :: proc(device: ^sdl.GPUDevice) -> sdl.GPUTextureFormat {
	if sdl.GPUTextureSupportsFormat(device, .R16G16B16A16_FLOAT, .D2, {.COLOR_TARGET, .SAMPLER}) {
		return .R16G16B16A16_FLOAT
	}
	return .R8G8B8A8_UNORM
}

// ensure_hdr (re)creates the offscreen HDR scene target at the swapchain size — the scene
// renders here, the post pass samples it. Rebuilt on resize.
@(private)
ensure_hdr :: proc(r: ^Renderer, w, h: u32) {
	if r.hdr_tex != nil && r.hdr_w == w && r.hdr_h == h {
		return
	}
	if r.hdr_tex != nil {
		sdl.ReleaseGPUTexture(r.device, r.hdr_tex)
	}
	r.hdr_tex = sdl.CreateGPUTexture(
		r.device,
		{
			type = .D2,
			format = r.scene_format,
			usage = {.COLOR_TARGET, .SAMPLER},
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	r.hdr_w, r.hdr_h = w, h
}

// ensure_present (re)creates the present-cache texture (swapchain format) at the drawable size. The
// post pass renders into it and it's blitted to the swapchain — see the `present_tex` field comment.
ensure_present :: proc(r: ^Renderer, w, h: u32) {
	if r.present_tex != nil && r.present_w == w && r.present_h == h {
		return
	}
	if r.present_tex != nil {
		sdl.ReleaseGPUTexture(r.device, r.present_tex)
	}
	r.present_tex = sdl.CreateGPUTexture(
		r.device,
		{
			type = .D2,
			format = r.swapchain_format,
			usage = {.COLOR_TARGET, .SAMPLER}, // COLOR_TARGET: the post pass writes it; SAMPLER: the blit reads it
			width = w,
			height = h,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	r.present_w, r.present_h = w, h
}

// make_post_pipeline builds the HDR resolve/tonemap pipeline: post.vert (fullscreen triangle,
// no vertex input) + post.frag (1 sampler set 2 = the HDR scene target; 1 uniform buffer set 3
// = the tonemap/grade params). Targets the swapchain, no depth, no blend (overwrites).
@(private)
make_post_pipeline :: proc(r: ^Renderer) -> ^sdl.GPUGraphicsPipeline {
	vshader := create_shader(r.device, POST_VERT_SPV, .VERTEX, 0, 0)
	fshader := create_shader(r.device, POST_FRAG_SPV, .FRAGMENT, 1, 1)
	if vshader == nil || fshader == nil {
		return nil
	}
	defer sdl.ReleaseGPUShader(r.device, vshader)
	defer sdl.ReleaseGPUShader(r.device, fshader)

	color_target := sdl.GPUColorTargetDescription{format = r.swapchain_format}
	info := sdl.GPUGraphicsPipelineCreateInfo {
		vertex_shader = vshader,
		fragment_shader = fshader,
		primitive_type = .TRIANGLELIST,
		rasterizer_state = {fill_mode = .FILL, cull_mode = .NONE},
		multisample_state = {sample_count = ._1},
		// No depth target in the post pass.
		target_info = {color_target_descriptions = &color_target, num_color_targets = 1},
	}
	return sdl.CreateGPUGraphicsPipeline(r.device, info)
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
	color_target := sdl.GPUColorTargetDescription{format = r.scene_format}
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

// pick_depth_format chooses the depth(+stencil) target format. We render REVERSED-Z (see
// perspective_rh_zo_rev), whose precision win needs a FLOAT depth buffer — so prefer
// D32F_S8 (float depth + the stencil the open-interiors portals need). D24_UNORM_S8 is the
// fallback (reversed-Z still valid, just less of the float-precision gain); plain D32F is the
// last resort (no stencil → portals disabled).
@(private)
pick_depth_format :: proc(device: ^sdl.GPUDevice) -> sdl.GPUTextureFormat {
	for f in ([?]sdl.GPUTextureFormat{.D32_FLOAT_S8_UINT, .D24_UNORM_S8_UINT}) {
		if sdl.GPUTextureSupportsFormat(device, f, .D2, {.DEPTH_STENCIL_TARGET}) {
			return f
		}
	}
	return .D32_FLOAT
}

// has_stencil reports whether `f` carries a stencil aspect (so the portal pipelines can be built).
@(private)
has_stencil :: proc(f: sdl.GPUTextureFormat) -> bool {
	return f == .D24_UNORM_S8_UINT || f == .D32_FLOAT_S8_UINT
}

// bind_pipeline binds `pl` on `pass`, skipping the SDL call when it is already the current pipeline
// (redundant-bind elimination — see Renderer.bound_pipeline). Callers MUST reset r.bound_pipeline to
// nil at the start of every render pass (scene_begin / shadow_cascade) so a freed-then-reused pass
// pointer can never make a needed rebind be skipped.
@(private)
bind_pipeline :: proc(r: ^Renderer, pass: ^sdl.GPURenderPass, pl: ^sdl.GPUGraphicsPipeline) {
	if r.bound_pipeline == pl {
		return
	}
	sdl.BindGPUGraphicsPipeline(pass, pl)
	r.bound_pipeline = pl
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

// Upload_Batch coalesces many buffer/texture uploads into ONE command buffer +
// copy pass + submit. SDL3_gpu charges real driver overhead per submit, so doing a
// whole model's meshes + textures (or a frame's worth) in one batch beats the old
// per-buffer acquire/submit dance. Open with upload_begin, record via the *_into
// procs, close with upload_end (which submits once and frees every staging buffer —
// safe after submit: SDL defers the actual free until the copy completes).
Upload_Batch :: struct {
	device:    ^sdl.GPUDevice,
	cmd:       ^sdl.GPUCommandBuffer,
	pass:      ^sdl.GPUCopyPass,
	transfers: [dynamic]^sdl.GPUTransferBuffer,
}

upload_begin :: proc(r: ^Renderer) -> Upload_Batch {
	cmd := sdl.AcquireGPUCommandBuffer(r.device)
	return {device = r.device, cmd = cmd, pass = sdl.BeginGPUCopyPass(cmd)}
}

// gpu_drain blocks until the GPU finishes all submitted work, so SDL can reclaim the staging
// (transfer) buffers that upload_end only RELEASES — SDL defers the actual free until the copy
// completes. In the per-frame path a frame boundary provides that drain; but a big SYNCHRONOUS
// load (the render-distance bubble) submits thousands of per-mesh uploads with NO frame between
// them, so their deferred-free staging accumulates and exhausts the host-visible heap — which
// then fails even tiny binds ("Failed to bind memory for buffer") while VRAM sits mostly free.
// Call periodically inside such a loop to bound how much staging is in flight at once.
gpu_drain :: proc(r: ^Renderer) {
	_ = sdl.WaitForGPUIdle(r.device)
}

upload_end :: proc(b: ^Upload_Batch) {
	sdl.EndGPUCopyPass(b.pass)
	_ = sdl.SubmitGPUCommandBuffer(b.cmd)
	for tb in b.transfers {
		sdl.ReleaseGPUTransferBuffer(b.device, tb)
	}
	delete(b.transfers)
	b^ = {}
}

// upload_buffer_into records one buffer upload into an open batch and returns the
// (already-valid) GPU buffer handle. The staging buffer is retained by the batch and
// freed at upload_end.
upload_buffer_into :: proc(b: ^Upload_Batch, usage: sdl.GPUBufferUsageFlags, data: []byte) -> ^sdl.GPUBuffer {
	size := u32(len(data))
	if size == 0 {
		return nil
	}
	// Any of these can fail under GPU-resource pressure — notably at high render distance, where
	// the synchronous bubble load allocates a vbuf+ibuf per terrain patch across hundreds of cells
	// and can hit the driver's max allocation count / VRAM. A nil return here used to reach the
	// mem.copy below and segfault; instead bail cleanly (the caller's mesh just won't render) and
	// log the driver reason so the limit is visible. Callers must tolerate a nil buffer (draws skip).
	buf := sdl.CreateGPUBuffer(b.device, {usage = usage, size = size})
	tb := sdl.CreateGPUTransferBuffer(b.device, {usage = .UPLOAD, size = size})
	ptr := sdl.MapGPUTransferBuffer(b.device, tb, false) if tb != nil else nil
	if buf == nil || tb == nil || ptr == nil {
		log.errorf("render: buffer upload failed (size %d bytes): %s", size, sdl.GetError())
		if tb != nil {sdl.ReleaseGPUTransferBuffer(b.device, tb)}
		if buf != nil {sdl.ReleaseGPUBuffer(b.device, buf)}
		return nil
	}
	mem.copy(ptr, raw_data(data), int(size))
	sdl.UnmapGPUTransferBuffer(b.device, tb)
	sdl.UploadToGPUBuffer(b.pass, {transfer_buffer = tb, offset = 0}, {buffer = buf, offset = 0, size = size}, false)
	append(&b.transfers, tb)
	return buf
}

// upload_buffer is the one-shot convenience (its own command buffer + submit) for the
// single-buffer callers — the cube, instance scatter buffers, etc.
@(private)
upload_buffer :: proc(
	device: ^sdl.GPUDevice,
	usage: sdl.GPUBufferUsageFlags,
	data: []byte,
) -> ^sdl.GPUBuffer {
	b := Upload_Batch{device = device, cmd = sdl.AcquireGPUCommandBuffer(device)}
	b.pass = sdl.BeginGPUCopyPass(b.cmd)
	buf := upload_buffer_into(&b, usage, data)
	upload_end(&b)
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

	upload_texture_pixels(device, tex, pixels[:], SIZE, SIZE)
	return tex
}

// bytes_of reinterprets a typed slice as a raw byte slice for GPU upload.
@(private)
bytes_of :: proc(s: []$T) -> []byte {
	return (cast([^]byte)raw_data(s))[:len(s) * size_of(T)]
}
