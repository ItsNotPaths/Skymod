package nif

// NIF material/texture parsing (ROADMAP Iteration 1, Milestone B4). The static-mesh
// material chain: a NiTriShape references a BSLightingShaderProperty, which
// references a BSShaderTextureSet, which holds the actual texture *paths* (diffuse,
// normal, ...). We capture the diffuse path per shape so the renderer can VFS-read
// the DDS and texture the mesh.
//
// Layout is Skyrim LE (20.2.0.7, BS 83). Texture-set strings are SizedStrings (the
// real paths), NOT header string-table indices. Validated empirically against the
// real install (tools/nifdump): resolved refs must land on the expected block types
// and the diffuse strings must read as `textures\...\.dds`.

import "core:strings"

// BSShaderTextureSet slot order (Skyrim). Slot 0 is the diffuse map; the rest are
// captured-but-unused until the lit pass needs them.
TEX_DIFFUSE :: 0
TEX_NORMAL :: 1

// MAX_TEXTURES caps the texture-set count read from (possibly misaligned) data.
@(private)
MAX_TEXTURES :: 64

// parse_texture_set decodes a BSShaderTextureSet block (raw bytes from block_data):
// a u32 count then that many length-prefixed texture paths. Returns the paths
// (each cloned into the ambient allocator). Caller frees with destroy_texture_set.
parse_texture_set :: proc(b: []u8, allocator := context.allocator) -> (paths: []string, ok: bool) {
	context.allocator = allocator
	r := Reader{data = b, ok = true}
	n := int(read_u32(&r))
	if !r.ok || n < 0 || n > MAX_TEXTURES {
		return nil, false
	}
	out := make([]string, n)
	for i in 0 ..< n {
		out[i] = read_sized_string(&r)
	}
	if !r.ok {
		destroy_texture_set(out)
		return nil, false
	}
	return out, true
}

destroy_texture_set :: proc(paths: []string) {
	for s in paths {
		delete(s)
	}
	delete(paths)
}

// texture_set_ref reads the BSShaderTextureSet ref out of a BSLightingShaderProperty
// block. Layout (Skyrim LE, BS 83), verified empirically against real NIFs: a
// leading Skyrim Shader Type (uint) comes FIRST, then NiObjectNET (name ref,
// extra-data list, controller), then two shader-flag words, UV offset+scale, then
// the Texture Set ref. Returns -1 on overrun. Validate the returned ref's block type
// is "BSShaderTextureSet" before trusting it (see resolve_diffuse).
texture_set_ref :: proc(b: []u8) -> (ref: i32, ok: bool) {
	r := Reader{data = b, ok = true}
	_ = read_u32(&r) // Skyrim Shader Type (leading, before NiObjectNET)
	_ = read_i32(&r) // Name (string ref)
	n_extra := int(read_u32(&r)) // Num Extra Data List
	if !r.ok || n_extra < 0 || n_extra > MAX_LIST {
		return -1, false
	}
	for _ in 0 ..< n_extra {
		_ = read_i32(&r) // Extra Data refs
	}
	_ = read_i32(&r) // Controller
	_ = read_u32(&r) // Shader Flags 1
	_ = read_u32(&r) // Shader Flags 2
	_ = read_vec2(&r) // UV Offset
	_ = read_vec2(&r) // UV Scale
	ref = read_i32(&r) // Texture Set ref
	if !r.ok {
		return -1, false
	}
	return ref, true
}

// resolve_diffuse follows a shape's shader_ref → BSLightingShaderProperty → texture
// set → slot 0, returning the diffuse path (cloned into the ambient allocator) or ""
// if the chain is absent/effect-shader/empty. Non-fatal: a missing texture just
// renders untextured.
@(private)
resolve_diffuse :: proc(data: []u8, h: ^Header, shader_ref: i32, allocator := context.allocator) -> string {
	context.allocator = allocator
	si := int(shader_ref)
	if si < 0 || si >= int(h.num_blocks) {
		return ""
	}
	if block_type(h, si) != "BSLightingShaderProperty" {
		return "" // e.g. BSEffectShaderProperty — no diffuse slot in this layout
	}
	ts_ref, ok := texture_set_ref(block_data(h, data, si))
	if !ok {
		return ""
	}
	ti := int(ts_ref)
	if ti < 0 || ti >= int(h.num_blocks) || block_type(h, ti) != "BSShaderTextureSet" {
		return ""
	}
	paths, pok := parse_texture_set(block_data(h, data, ti), context.temp_allocator)
	if !pok || len(paths) <= TEX_DIFFUSE || paths[TEX_DIFFUSE] == "" {
		return ""
	}
	return strings.clone(paths[TEX_DIFFUSE])
}
