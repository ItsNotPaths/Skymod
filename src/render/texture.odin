package render

// GPU texture upload (ROADMAP Iteration 1, Milestone B4 / §0.5 "read-direct"). DDS
// BCn data is GPU-native, so the caller (assetdb/demo) parses a DDS into a neutral
// (format + mip-slice) description and hands it here for a direct block upload — no
// pixel decode. This package owns SDL3_gpu; the format enum below is render's own so
// the parser layer (src/formats/dds) stays free of any GPU dependency.

import "core:mem"
import sdl "vendor:sdl3"

// Texture is an uploaded GPU texture — opaque handle. A zero value (tex==nil) means
// "no texture"; draw_mesh treats that as the white fallback.
Texture :: struct {
	tex: ^sdl.GPUTexture,
}

// Tex_Format is render's neutral pixel format (mirrors the BCn / RGBA8 set the DDS
// parser classifies). srgb is chosen per-usage by the caller (diffuse = true).
Tex_Format :: enum {
	BC1,
	BC2,
	BC3,
	BC4,
	BC5,
	BC7,
	RGBA8,
	BGRA8, // uncompressed 32bpp with B/R swapped (Skyrim's D3D9-default uncompressed maps)
}

// Tex_Mip is one mip level: its dimensions and a slice of the (tightly-packed) source
// bytes for that level.
Tex_Mip :: struct {
	width:  u32,
	height: u32,
	data:   []u8,
}

// upload_texture creates a sampled GPU texture from a mip chain in its own copy pass +
// submit. mips[0] is the base level. Returns a zero Texture on bad input. Release with
// release_texture.
upload_texture :: proc(r: ^Renderer, format: Tex_Format, srgb: bool, mips: []Tex_Mip) -> Texture {
	b := upload_begin(r)
	t := upload_texture_into(&b, format, srgb, mips)
	upload_end(&b)
	return t
}

// upload_texture_into records a texture's full mip chain into an open Upload_Batch (every
// level in the shared copy pass), so a whole model's meshes + textures land in one submit.
upload_texture_into :: proc(b: ^Upload_Batch, format: Tex_Format, srgb: bool, mips: []Tex_Mip) -> Texture {
	if len(mips) == 0 || mips[0].width == 0 || mips[0].height == 0 {
		return {}
	}
	tex := sdl.CreateGPUTexture(
		b.device,
		{
			type = .D2,
			format = to_sdl_format(format, srgb),
			usage = {.SAMPLER},
			width = mips[0].width,
			height = mips[0].height,
			layer_count_or_depth = 1,
			num_levels = u32(len(mips)),
			sample_count = ._1,
		},
	)
	if tex == nil {
		return {}
	}

	total := 0
	for m in mips {
		total += len(m.data)
	}
	tb := sdl.CreateGPUTransferBuffer(b.device, {usage = .UPLOAD, size = u32(total)})
	dst := sdl.MapGPUTransferBuffer(b.device, tb, false)
	off := 0
	offsets := make([]int, len(mips), context.temp_allocator)
	for m, i in mips {
		offsets[i] = off
		mem.copy(rawptr(uintptr(dst) + uintptr(off)), raw_data(m.data), len(m.data))
		off += len(m.data)
	}
	sdl.UnmapGPUTransferBuffer(b.device, tb)

	compressed := format != .RGBA8 && format != .BGRA8
	for m, i in mips {
		// Vulkan requires the transfer row length to be a multiple of the block size
		// for compressed formats; the DDS mip data is tightly packed at that stride.
		ppr := m.width
		rpl := m.height
		if compressed {
			ppr = round_up4(m.width)
			rpl = round_up4(m.height)
		}
		sdl.UploadToGPUTexture(
			b.pass,
			{transfer_buffer = tb, offset = u32(offsets[i]), pixels_per_row = ppr, rows_per_layer = rpl},
			{texture = tex, mip_level = u32(i), w = m.width, h = m.height, d = 1},
			false,
		)
	}
	append(&b.transfers, tb)
	return {tex = tex}
}

// tex_valid reports whether a Texture holds a real GPU texture (vs the zero/fallback).
tex_valid :: proc(t: Texture) -> bool {
	return t.tex != nil
}

release_texture :: proc(r: ^Renderer, t: Texture) {
	if t.tex != nil {
		sdl.ReleaseGPUTexture(r.device, t.tex)
	}
}

// --- internals ---

@(private)
to_sdl_format :: proc(f: Tex_Format, srgb: bool) -> sdl.GPUTextureFormat {
	switch f {
	case .BC1:
		return .BC1_RGBA_UNORM_SRGB if srgb else .BC1_RGBA_UNORM
	case .BC2:
		return .BC2_RGBA_UNORM_SRGB if srgb else .BC2_RGBA_UNORM
	case .BC3:
		return .BC3_RGBA_UNORM_SRGB if srgb else .BC3_RGBA_UNORM
	case .BC4:
		return .BC4_R_UNORM // no sRGB variant
	case .BC5:
		return .BC5_RG_UNORM // no sRGB variant
	case .BC7:
		return .BC7_RGBA_UNORM_SRGB if srgb else .BC7_RGBA_UNORM
	case .RGBA8:
		return .R8G8B8A8_UNORM_SRGB if srgb else .R8G8B8A8_UNORM
	case .BGRA8:
		return .B8G8R8A8_UNORM_SRGB if srgb else .B8G8R8A8_UNORM
	}
	return .R8G8B8A8_UNORM
}

@(private)
round_up4 :: proc(v: u32) -> u32 {
	return (v + 3) & ~u32(3)
}

// make_white_texture builds the 1x1 opaque-white fallback bound for untextured
// shapes (so the diffuse-sampling shader shows plain shading).
@(private)
make_white_texture :: proc(device: ^sdl.GPUDevice) -> ^sdl.GPUTexture {
	tex := sdl.CreateGPUTexture(
		device,
		{
			type = .D2,
			format = .R8G8B8A8_UNORM,
			usage = {.SAMPLER},
			width = 1,
			height = 1,
			layer_count_or_depth = 1,
			num_levels = 1,
			sample_count = ._1,
		},
	)
	px := [4]u8{255, 255, 255, 255}
	tb := sdl.CreateGPUTransferBuffer(device, {usage = .UPLOAD, size = 4})
	dst := sdl.MapGPUTransferBuffer(device, tb, false)
	mem.copy(dst, raw_data(px[:]), 4)
	sdl.UnmapGPUTransferBuffer(device, tb)
	cmd := sdl.AcquireGPUCommandBuffer(device)
	cp := sdl.BeginGPUCopyPass(cmd)
	sdl.UploadToGPUTexture(
		cp,
		{transfer_buffer = tb, offset = 0, pixels_per_row = 1, rows_per_layer = 1},
		{texture = tex, w = 1, h = 1, d = 1},
		false,
	)
	sdl.EndGPUCopyPass(cp)
	_ = sdl.SubmitGPUCommandBuffer(cmd)
	sdl.ReleaseGPUTransferBuffer(device, tb)
	return tex
}
