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

// NiAlphaProperty flag bits (Skyrim): bit 0 = alpha-blend enable, bit 9 = alpha-test
// enable. The Threshold byte (0-255) is the alpha-test reference value.
NIALPHA_BLEND :: 0x0001
NIALPHA_TEST :: 0x0200

// resolve_alpha follows a shape's alpha-property ref to its NiAlphaProperty block and
// returns the alpha-test cutoff in [0,1] — 0 means opaque (no test). NiAlphaProperty is
// NiObjectNET (name ref, extra-data list, controller) then Flags (u16) + Threshold (u8).
// Alpha-test foliage uses the stored threshold; blend-only materials degrade to a 0.5
// cutout (we don't depth-sort, so translucency becomes alpha-test — fine for leaves/
// grass, the vegetation case). Non-fatal: an absent/!alpha ref → 0 (opaque).
@(private)
resolve_alpha :: proc(data: []u8, h: ^Header, alpha_ref: i32) -> f32 {
	ai := int(alpha_ref)
	if ai < 0 || ai >= int(h.num_blocks) || block_type(h, ai) != "NiAlphaProperty" {
		return 0
	}
	r := Reader{data = block_data(h, data, ai), ok = true}
	_ = read_i32(&r) // Name (string ref)
	n_extra := int(read_u32(&r)) // Num Extra Data List
	if !r.ok || n_extra < 0 || n_extra > MAX_LIST {
		return 0
	}
	for _ in 0 ..< n_extra {
		_ = read_i32(&r) // Extra Data refs
	}
	_ = read_i32(&r) // Controller
	flags := read_u16(&r)
	threshold := read_u8(&r)
	if !r.ok {
		return 0
	}
	if flags & NIALPHA_TEST != 0 {
		return f32(threshold) / 255
	}
	if flags & NIALPHA_BLEND != 0 {
		return 0.5
	}
	return 0
}

// is_effect_shader reports whether a shape's shader is a BSEffectShaderProperty (fire/FX
// — no lit diffuse). The renderer ghosts these instead of drawing them as opaque blocks.
@(private)
is_effect_shader :: proc(h: ^Header, shader_ref: i32) -> bool {
	si := int(shader_ref)
	return si >= 0 && si < int(h.num_blocks) && block_type(h, si) == "BSEffectShaderProperty"
}

// EffectShaderControlledVariable values (nif.xml) for the UV-scroll variables a
// BSEffectShaderPropertyFloatController can animate. We only act on the two OFFSET ones —
// that's the flowing-water / light-beam / fire scroll. Scale (7/9) is left static.
EFFECT_VAR_U_OFFSET :: 6
EFFECT_VAR_V_OFFSET :: 8

// Effect_Shader is what the renderer needs from a BSEffectShaderProperty (fire/water/FX):
// its source-texture path and the per-axis UV scroll speed (UV tiles/sec) derived from the
// shader's float-controller chain. source is owned (cloned into the ambient allocator).
Effect_Shader :: struct {
	source: string,
	scroll: [2]f32,
}

// resolve_effect decodes a BSEffectShaderProperty: the Source Texture path + the UV scroll
// speed from its BSEffectShaderPropertyFloatController chain. Layout (Skyrim LE 20.2.0.7):
// NiObjectNET (name, extra list, controller) then 2 shader-flag words, UV offset+scale, then
// the Source Texture SizedString — BSShaderProperty/NiShadeProperty add nothing at this
// version. Returns zero values if shader_ref isn't an effect shader. NON-FATAL throughout.
@(private)
resolve_effect :: proc(data: []u8, h: ^Header, shader_ref: i32, allocator := context.allocator) -> Effect_Shader {
	context.allocator = allocator
	si := int(shader_ref)
	if si < 0 || si >= int(h.num_blocks) || block_type(h, si) != "BSEffectShaderProperty" {
		return {}
	}
	r := Reader{data = block_data(h, data, si), ok = true}
	_ = read_i32(&r) // Name (string ref)
	n_extra := int(read_u32(&r)) // Num Extra Data List
	if !r.ok || n_extra < 0 || n_extra > MAX_LIST {
		return {}
	}
	for _ in 0 ..< n_extra {
		_ = read_i32(&r) // Extra Data refs
	}
	ctrl_ref := read_i32(&r) // Controller (the float-controller chain root)
	_ = read_u32(&r) // Shader Flags 1
	_ = read_u32(&r) // Shader Flags 2
	_ = read_vec2(&r) // UV Offset
	_ = read_vec2(&r) // UV Scale
	source := read_sized_string(&r) // Source Texture
	if !r.ok {
		return {}
	}
	// Same build-tree-prefix quirk as texture sets (see normalize_texture_path).
	if norm := normalize_texture_path(source); len(norm) != len(source) {
		cloned := strings.clone(norm)
		delete(source)
		source = cloned
	}
	return {source = source, scroll = effect_scroll(data, h, ctrl_ref)}
}

// effect_scroll walks a BSEffectShaderProperty's controller chain (via Next Controller) and
// sums the U/V-offset scroll speeds (UV tiles/sec) from every
// BSEffectShaderPropertyFloatController driving an OFFSET variable. Controller layout:
// NiTimeController (Next, Flags u16, Frequency, Phase, Start, Stop, Target) + Interpolator
// ref + Controlled Variable (u32). Bounded loop (guards against a malformed cycle).
@(private)
effect_scroll :: proc(data: []u8, h: ^Header, ctrl_ref: i32) -> (scroll: [2]f32) {
	cur := int(ctrl_ref)
	for guard := 0; cur >= 0 && cur < int(h.num_blocks) && guard < 16; guard += 1 {
		is_float_ctrl := block_type(h, cur) == "BSEffectShaderPropertyFloatController"
		r := Reader{data = block_data(h, data, cur), ok = true}
		next := int(read_i32(&r)) // Next Controller
		_ = read_u16(&r) // Flags
		freq := read_f32(&r) // Frequency
		_ = read_f32(&r) // Phase
		_ = read_f32(&r) // Start Time
		_ = read_f32(&r) // Stop Time
		_ = read_i32(&r) // Target
		if is_float_ctrl {
			interp := read_i32(&r) // Interpolator ref
			cvar := read_u32(&r) // Controlled Variable
			if r.ok {
				spd := effect_interp_speed(data, h, interp) * freq
				switch cvar {
				case EFFECT_VAR_U_OFFSET:
					scroll.x += spd
				case EFFECT_VAR_V_OFFSET:
					scroll.y += spd
				}
			}
		}
		if !r.ok {
			break
		}
		cur = next
	}
	return
}

// effect_interp_speed derives a constant scroll rate (value units / sec) from a
// NiFloatInterpolator → NiFloatData linear key ramp: (lastValue−firstValue)/(lastTime−
// firstTime). A 2-key 0→N ramp over T seconds (the flowing-water convention) gives N/T
// tiles/sec; texture WRAP makes the loop seamless. Returns 0 if there's no animated data
// (fewer than 2 keys / a constant pose value) or the chain is malformed.
@(private)
effect_interp_speed :: proc(data: []u8, h: ^Header, interp_ref: i32) -> f32 {
	ii := int(interp_ref)
	if ii < 0 || ii >= int(h.num_blocks) || block_type(h, ii) != "NiFloatInterpolator" {
		return 0
	}
	r := Reader{data = block_data(h, data, ii), ok = true}
	_ = read_f32(&r) // Value (constant pose, used only when Data is null)
	data_ref := int(read_i32(&r)) // NiFloatData ref
	if !r.ok || data_ref < 0 || data_ref >= int(h.num_blocks) || block_type(h, data_ref) != "NiFloatData" {
		return 0
	}
	dr := Reader{data = block_data(h, data, data_ref), ok = true}
	num := int(read_u32(&dr)) // Num Keys
	if !dr.ok || num < 2 || num > MAX_LIST {
		return 0
	}
	// KeyGroup: floats per key by interpolation type (LINEAR 2, QUADRATIC 4, TBC 5; else 2).
	floats_per_key := 2
	switch read_u32(&dr) {
	case 2:
		floats_per_key = 4
	case 3:
		floats_per_key = 5
	}
	t0 := read_f32(&dr)
	v0 := read_f32(&dr)
	for _ in 0 ..< floats_per_key - 2 {
		_ = read_f32(&dr) // rest of key 0 (tangents / TBC)
	}
	for _ in 0 ..< (num - 2) * floats_per_key {
		_ = read_f32(&dr) // skip to the last key
	}
	tN := read_f32(&dr)
	vN := read_f32(&dr)
	if !dr.ok || tN <= t0 {
		return 0
	}
	return (vN - v0) / (tN - t0)
}

// Material is the per-shape lit material from a BSLightingShaderProperty (Skyrim
// specular-glossiness model): specular color/strength, glossiness (Blinn-Phong-ish
// exponent), and emissive color/multiple. The profile reinterprets these at runtime
// (spec_scale, gloss remap, emissive_scale) for modern shading.
Material :: struct {
	spec_color:     [3]f32,
	spec_strength:  f32,
	glossiness:     f32,
	emissive_color: [3]f32,
	emissive_mult:  f32,
}

// DEFAULT_MATERIAL: no specular (strength 0), mild glossiness, no emissive — the safe
// fallback when a shape has no lighting shader / the material scalars don't parse.
DEFAULT_MATERIAL :: Material {
	spec_color     = {1, 1, 1},
	spec_strength  = 0,
	glossiness     = 30,
	emissive_color = {0, 0, 0},
	emissive_mult  = 1,
}

// resolve_lighting decodes a BSLightingShaderProperty in one pass: the texture set's diffuse
// (slot 0) + normal (slot 1) paths AND the material scalars. Layout (Skyrim LE 20.2.0.7), after
// the Texture Set ref (see texture_set_ref for the head): Emissive Color (vec3), Emissive Multiple
// (f32), Texture Clamp Mode (u32), Alpha (f32), Refraction Strength (f32), Glossiness (f32),
// Specular Color (vec3), Specular Strength (f32). Validated against real NIFs via nifdump. Both
// strings are cloned into the ambient allocator (caller frees). Material defaults if the scalars
// run short; textures resolve independently of the scalar read.
resolve_lighting :: proc(
	data: []u8,
	h: ^Header,
	shader_ref: i32,
	allocator := context.allocator,
) -> (
	diffuse, normal: string,
	mat: Material,
) {
	context.allocator = allocator
	mat = DEFAULT_MATERIAL
	si := int(shader_ref)
	if si < 0 || si >= int(h.num_blocks) || block_type(h, si) != "BSLightingShaderProperty" {
		return "", "", mat
	}
	ts_ref, m, ok := parse_lighting_material(block_data(h, data, si))
	if !ok {
		return "", "", mat
	}
	mat = m
	diffuse, normal = resolve_texset(data, h, ts_ref, allocator)
	return
}

// parse_lighting_material decodes a BSLightingShaderProperty block body: the Texture Set ref
// (head — see texture_set_ref) followed by the material scalars (Skyrim LE layout): Emissive
// Color (vec3), Emissive Multiple (f32), Texture Clamp Mode (u32), Alpha (f32), Refraction
// Strength (f32), Glossiness (f32), Specular Color (vec3), Specular Strength (f32). ok=false if
// the head (through the texture-set ref) overruns; if only the scalars run short, mat keeps
// DEFAULT_MATERIAL but ok stays true (the texture set is still usable). Operates on raw block
// bytes (no Header) so it's unit-testable like texture_set_ref.
parse_lighting_material :: proc(b: []u8) -> (ts_ref: i32, mat: Material, ok: bool) {
	mat = DEFAULT_MATERIAL
	r := Reader{data = b, ok = true}
	_ = read_u32(&r) // Skyrim Shader Type
	_ = read_i32(&r) // Name
	n_extra := int(read_u32(&r))
	if !r.ok || n_extra < 0 || n_extra > MAX_LIST {
		return -1, mat, false
	}
	for _ in 0 ..< n_extra {
		_ = read_i32(&r) // Extra Data refs
	}
	_ = read_i32(&r) // Controller
	_ = read_u32(&r) // Shader Flags 1
	_ = read_u32(&r) // Shader Flags 2
	_ = read_vec2(&r) // UV Offset
	_ = read_vec2(&r) // UV Scale
	ts_ref = read_i32(&r) // Texture Set ref
	if !r.ok {
		return -1, mat, false
	}
	em := read_vec3(&r) // Emissive Color
	em_mult := read_f32(&r) // Emissive Multiple
	_ = read_u32(&r) // Texture Clamp Mode
	_ = read_f32(&r) // Alpha
	_ = read_f32(&r) // Refraction Strength
	gloss := read_f32(&r) // Glossiness
	sc := read_vec3(&r) // Specular Color
	ss := read_f32(&r) // Specular Strength
	if r.ok {
		mat = Material {
			spec_color     = sc,
			spec_strength  = ss,
			glossiness     = gloss,
			emissive_color = em,
			emissive_mult  = em_mult,
		}
	}
	return ts_ref, mat, true
}

// normalize_texture_path strips the absolute build-tree prefix some vanilla SSE assets
// ship — e.g. SwordFern01.nif's diffuse is "skyrimhd\\build\\pc\\data\\textures\\landscape\\
// grass\\SwordFern.dds" (Bethesda re-exported the SSE foliage from their HD build tree
// without relativizing; the real engine snaps to the "textures\\" segment too). Keeps the
// path from its LAST case-insensitive "textures\\" (or "/") on; anything already rooted
// there (or with no textures segment at all) passes through unchanged. Returns a slice
// of the input — caller clones.
@(private)
normalize_texture_path :: proc(p: string) -> string {
	lower := strings.to_lower(p, context.temp_allocator)
	idx := strings.last_index(lower, "textures\\")
	if i2 := strings.last_index(lower, "textures/"); i2 > idx {
		idx = i2
	}
	if idx > 0 {
		return p[idx:]
	}
	return p
}

// resolve_texset reads the diffuse (slot 0) + normal (slot 1) paths from a BSShaderTextureSet
// ref, normalized (see normalize_texture_path). Either may be "" (absent). Cloned into the
// ambient allocator.
@(private)
resolve_texset :: proc(data: []u8, h: ^Header, ts_ref: i32, allocator := context.allocator) -> (diffuse, normal: string) {
	context.allocator = allocator
	ti := int(ts_ref)
	if ti < 0 || ti >= int(h.num_blocks) || block_type(h, ti) != "BSShaderTextureSet" {
		return "", ""
	}
	paths, pok := parse_texture_set(block_data(h, data, ti), context.temp_allocator)
	if !pok {
		return "", ""
	}
	if len(paths) > TEX_DIFFUSE && paths[TEX_DIFFUSE] != "" {
		diffuse = strings.clone(normalize_texture_path(paths[TEX_DIFFUSE]))
	}
	if len(paths) > TEX_NORMAL && paths[TEX_NORMAL] != "" {
		normal = strings.clone(normalize_texture_path(paths[TEX_NORMAL]))
	}
	return
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
	return strings.clone(normalize_texture_path(paths[TEX_DIFFUSE]))
}
