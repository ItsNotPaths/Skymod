package plugin

// Record views of the visual records. Paths are under textures\ or meshes\ as the record has them.

import "../formats/esm"

Effect_Shader :: struct {
	using header:     Header,
	fill_texture:     Span(u8),
	particle_texture: Span(u8),
	holes_texture:    Span(u8),
	membrane_palette: Span(u8),
	particle_palette: Span(u8),
	data:             esm.Effect_Shader_Data,
	addon_models:     Form_ID, // DEBR
	ambient_sound:    Form_ID, // SNDR, or SOUN in older records
}

Art_Object :: struct {
	using header: Header,
	model:        Span(u8),
	kind:         u32, // 0 magic casting, 1 magic hit, 2 enchantment
}

Impact :: struct {
	using header: Header,
	model:        Span(u8),
	data:         esm.Impact_Data,
	decal:        esm.Decal,
	has_decal:    bool,
	texture_sets: [2]Form_ID, // TXST: primary, secondary
	sounds:       [2]Form_ID,
	hazard:       Form_ID,
}

// Impact_Entry is the impact an IPDS plays on a surface of `material` (MATT).
Impact_Entry :: struct {
	material, impact: Form_ID,
}

Impact_Set :: struct {
	using header: Header,
	entries:      Span(Impact_Entry),
}

// Image_Space_Modifier is an IMAD. Curve times are 0..1 of the duration; an empty curve leaves
// its value alone.
Image_Space_Modifier :: struct {
	using header: Header,
	info:         esm.Imod_Info,
	curves:       [esm.Imod_Curve]Span(esm.Keyframe),
	tint:         Span(esm.Color_Keyframe),
	fade:         Span(esm.Color_Keyframe),
}

Visual_Effect :: struct {
	using header: Header,
	art, shader:  Form_ID,
	flags:        u32, // 1 face target, 2 attach to camera, 4 inherit rotation
}
