package dds

// DDS texture parser (ROADMAP Iteration 1, Milestone B4 / §0.5 "read-direct"). DDS
// is already GPU-native — BC1/2/3/5/7 are exactly the block-compressed formats
// Vulkan/SDL3_gpu consume — so we never decode or copy pixels: parse the header,
// classify the format, slice the mip chain in place, and hand those slices to the
// renderer for a direct upload. Pure parser, no engine/GPU deps.
//
// Layout: 4-byte magic "DDS " + a 124-byte DDS_HEADER (with an embedded 32-byte
// DDS_PIXELFORMAT), optionally a 20-byte DDS_HEADER_DXT10 (FourCC "DX10"), then the
// pixel data (mip 0 largest, each subsequent level halved). Little-endian.
// Validated empirically against the real install's Textures BSA (tools/nifdump
// --dds): every format classified, and the computed mip chain must fit the file.

import "core:encoding/endian"

// Format is the GPU-native pixel layout. The renderer maps these (plus an sRGB
// choice per usage) to a concrete SDL_GPUTextureFormat.
Format :: enum {
	Unknown,
	BC1, // DXT1  — 8 bytes/block (RGB, 1-bit alpha)
	BC2, // DXT3  — 16 bytes/block (explicit alpha)
	BC3, // DXT5  — 16 bytes/block (interpolated alpha)
	BC4, // ATI1  — 8 bytes/block (single channel)
	BC5, // ATI2  — 16 bytes/block (two channel; normal maps)
	BC7, // DX10  — 16 bytes/block (high-quality; SE textures)
	RGBA8, // uncompressed 32bpp (channel order normalized to RGBA on upload)
}

// Image is a parsed DDS: format, base dimensions, mip count, and a slice of the
// pixel region (NOT owned — it points into the caller's file bytes).
Image :: struct {
	format:    Format,
	width:     u32,
	height:    u32,
	mip_count: u32,
	bgra:      bool, // uncompressed source is B8G8R8A8 (vs R8G8B8A8)
	data:      []u8, // mip chain, sliced from the input file
}

// Mip is one level of the chain: its dimensions and a slice of Image.data.
Mip :: struct {
	level:  int,
	width:  u32,
	height: u32,
	data:   []u8,
}

DDS_MAGIC :: 0x20534444 // "DDS " little-endian
HEADER_SIZE :: 124
DXT10_SIZE :: 20

DDPF_ALPHAPIXELS :: 0x1
DDPF_FOURCC :: 0x4
DDPF_RGB :: 0x40

// block_bytes is the byte size of one 4x4 block for a compressed format, or 0 for
// uncompressed (use bytes_per_pixel instead).
block_bytes :: proc(f: Format) -> int {
	switch f {
	case .BC1, .BC4:
		return 8
	case .BC2, .BC3, .BC5, .BC7:
		return 16
	case .RGBA8, .Unknown:
		return 0
	}
	return 0
}

// level_bytes is the byte size of one mip level at (w,h) for format f.
level_bytes :: proc(f: Format, w, h: u32) -> int {
	if bb := block_bytes(f); bb > 0 {
		bw := (int(w) + 3) / 4
		bh := (int(h) + 3) / 4
		if bw < 1 {bw = 1}
		if bh < 1 {bh = 1}
		return bw * bh * bb
	}
	return int(w) * int(h) * 4 // RGBA8
}

// parse reads a DDS file. data is sliced (not copied) from `file`, so `file` must
// outlive the returned Image. Returns ok=false on a bad magic / unsupported format.
parse :: proc(file: []u8) -> (img: Image, ok: bool) {
	if len(file) < 4 + HEADER_SIZE {
		return {}, false
	}
	if rd32(file, 0) != DDS_MAGIC {
		return {}, false
	}
	// DDS_HEADER fields (offsets relative to the header start at file+4): dwHeight@8,
	// dwWidth@12, dwMipMapCount@24.
	img.height = rd32(file, 4 + 8)
	img.width = rd32(file, 4 + 12)
	mips := rd32(file, 4 + 24)
	img.mip_count = mips if mips > 0 else 1

	// DDS_PIXELFORMAT at header offset 72 → file offset 4+72 = 76.
	pf := 4 + 72
	pf_flags := rd32(file, pf + 4)
	fourcc := rd32(file, pf + 8)

	data_off := 4 + HEADER_SIZE
	if pf_flags & DDPF_FOURCC != 0 {
		switch fourcc {
		case fourcc_of("DXT1"):
			img.format = .BC1
		case fourcc_of("DXT3"):
			img.format = .BC2
		case fourcc_of("DXT5"):
			img.format = .BC3
		case fourcc_of("ATI1"), fourcc_of("BC4U"):
			img.format = .BC4
		case fourcc_of("ATI2"), fourcc_of("BC5U"):
			img.format = .BC5
		case fourcc_of("DX10"):
			if len(file) < data_off + DXT10_SIZE {
				return {}, false
			}
			dxgi := rd32(file, data_off)
			data_off += DXT10_SIZE
			img.format = dxgi_format(dxgi)
			if img.format == .Unknown {
				return {}, false
			}
			img.bgra = dxgi == 87 || dxgi == 88 // B8G8R8A8_UNORM / _SRGB → channels swapped
		case:
			return {}, false // unsupported FourCC
		}
	} else if pf_flags & DDPF_RGB != 0 {
		// Uncompressed 32bpp. Skyrim authored these B8G8R8A8 (the D3D9 default).
		bitcount := rd32(file, pf + 12)
		if bitcount != 32 {
			return {}, false
		}
		img.format = .RGBA8
		img.bgra = rd32(file, pf + 16) == 0x00ff0000 // R mask in the high byte → BGRA
	} else {
		return {}, false
	}

	if data_off > len(file) {
		return {}, false
	}
	img.data = file[data_off:]
	ok = true
	return
}

// mip_chain slices Image.data into its levels. Truncates (and logs nothing — caller
// can compare len) if the file is shorter than the full chain. Caller frees the
// slice (the Mip.data sub-slices alias Image.data, so don't free those).
mip_chain :: proc(img: Image, allocator := context.allocator) -> []Mip {
	out := make([dynamic]Mip, 0, int(img.mip_count), allocator)
	w, h := img.width, img.height
	off := 0
	for lvl in 0 ..< int(img.mip_count) {
		n := level_bytes(img.format, w, h)
		if off + n > len(img.data) {
			break // file shorter than the declared chain
		}
		append(&out, Mip{level = lvl, width = w, height = h, data = img.data[off:off + n]})
		off += n
		w = max(w / 2, 1)
		h = max(h / 2, 1)
	}
	return out[:]
}

// --- internals ---

@(private)
fourcc_of :: proc(s: string) -> u32 {
	return u32(s[0]) | u32(s[1]) << 8 | u32(s[2]) << 16 | u32(s[3]) << 24
}

// dxgi_format maps the DXT10 DXGI_FORMAT enum to ours (the subset we handle).
@(private)
dxgi_format :: proc(d: u32) -> Format {
	switch d {
	case 71, 72:
		return .BC1 // BC1_UNORM / _SRGB
	case 74, 75:
		return .BC2
	case 77, 78:
		return .BC3
	case 80, 81:
		return .BC4
	case 83, 84:
		return .BC5
	case 98, 99:
		return .BC7
	case 28, 29:
		return .RGBA8 // R8G8B8A8_UNORM / _SRGB
	case 87, 88:
		return .RGBA8 // B8G8R8A8_UNORM / _SRGB — parse() flags img.bgra so upload picks BGRA
	}
	return .Unknown
}

@(private)
rd32 :: proc(b: []u8, off: int) -> u32 {
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return v
}
