package esm

// The visual records' data blocks: EFSH DATA, IPCT DATA and DODT, and IMAD's keyframe curves.
// Field order is xEdit's (wbDefinitionsTES5); validated on SE Skyrim.esm.

// Alpha_Ramp is how a shader layer's alpha rises, holds and falls, in seconds.
Alpha_Ramp :: struct {
	fade_in, full, fade_out: f32,
	persistent_ratio:        f32, // the alpha it holds at after fading, 0..1
	pulse_amplitude:         f32,
	pulse_frequency:         f32,
	full_ratio:              f32,
}

// Blend is a D3D blend setup: modes, operation and depth test as the CK numbers them.
Blend :: struct {
	src, dest, op, z_test: u32,
}

// EFSH DATA flags (the u32 at 384; the u8 at 0 is unused).
EFSH_NO_MEMBRANE :: 0x0000_0001
EFSH_NO_PARTICLES :: 0x0000_0008
EFSH_EDGE_INVERSE :: 0x0000_0010
EFSH_SKIN_ONLY :: 0x0000_0020
EFSH_IGNORE_ALPHA :: 0x0000_0040
EFSH_PROJECT_UVS :: 0x0000_0080
EFSH_LIGHTING :: 0x0000_0200
EFSH_NO_WEAPONS :: 0x0000_0400
EFSH_PARTICLE_ANIMATED :: 0x0000_8000
EFSH_BLOOD_GEOMETRY :: 0x0100_0000

// Effect_Shader_Data is an EFSH's DATA without its two form IDs (addon models, ambient sound).
// Colors are r, g, b, unused.
Effect_Shader_Data :: struct {
	flags:    u32, // EFSH_*
	membrane: Blend,
	fill:     struct {
		color_keys:  [3][4]u8,
		key_scales:  [3]f32,
		key_times:   [3]f32,
		color_scale: f32,
		ramp:        Alpha_Ramp,
		anim_speed:  [2]f32, // u, v
		scale:       [2]f32, // u, v
	},
	edge:     struct {
		falloff:     f32,
		color:       [4]u8,
		ramp:        Alpha_Ramp,
		width:       f32, // alpha units
		width_color: [4]u8,
	},
	particle: struct {
		blend:                 Blend,
		birth_ramp_up:         f32,
		full_birth_time:       f32,
		birth_ramp_down:       f32,
		full_birth_ratio:      f32,
		persistent_count:      f32,
		lifetime, lifetime_var: f32,
		normal_speed, normal_speed_var, normal_accel: f32,
		velocity, acceleration: [3]f32,
		scale_keys, scale_key_times: [2]f32,
		color_keys:            [3][4]u8,
		color_alphas:          [3]f32,
		color_times:           [3]f32,
		rotation, rotation_var:             f32, // degrees
		rotation_speed, rotation_speed_var: f32, // degrees a second
		birth_offset, birth_offset_var:     f32,
		texture_count:         [2]u32, // u, v
		start_frame, start_frame_var, end_frame, loop_start, loop_start_var, frame_count, frame_count_var: u32,
	},
	holes:    struct {
		start_time, end_time, start_val, end_val: f32,
	},
	addon:    struct {
		fade_in, fade_out, scale_start, scale_end, scale_in, scale_out: f32,
	},
	explosion_wind_speed: f32,
}

EFSH_ADDON_MODELS_AT :: 244 // DEBR
EFSH_AMBIENT_SOUND_AT :: 308 // SNDR (SOUN on old form versions)

// Seq reads a data block in order; past its end every read is 0, so a shorter older block
// decodes with its newer fields zero.
@(private = "file")
Seq :: struct {
	d:  []u8,
	at: int,
}

@(private = "file")
seq_u32 :: proc(s: ^Seq) -> (v: u32) {
	if s.at + 4 <= len(s.d) {v = rd32(s.d, s.at)}
	s.at += 4
	return
}

@(private = "file")
seq_f32 :: proc(s: ^Seq) -> f32 {return transmute(f32)seq_u32(s)}

@(private = "file")
seq_color :: proc(s: ^Seq) -> [4]u8 {return transmute([4]u8)seq_u32(s)}

@(private = "file")
seq_f32s :: proc(s: ^Seq, out: []f32) {for &v in out {v = seq_f32(s)}}

// effect_shader_data decodes an EFSH DATA (400 bytes; 344 and 396 in older records).
effect_shader_data :: proc(d: []u8) -> (e: Effect_Shader_Data) {
	s := Seq{d, 4} // flags u8 + 3 unused
	p := &e.particle
	e.membrane.src, e.membrane.op, e.membrane.z_test = seq_u32(&s), seq_u32(&s), seq_u32(&s)
	e.fill.color_keys[0] = seq_color(&s)
	fill := &e.fill.ramp
	fill.fade_in, fill.full, fill.fade_out, fill.persistent_ratio = seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s)
	fill.pulse_amplitude, fill.pulse_frequency = seq_f32(&s), seq_f32(&s)
	seq_f32s(&s, e.fill.anim_speed[:])
	e.edge.falloff = seq_f32(&s)
	e.edge.color = seq_color(&s)
	edge := &e.edge.ramp
	edge.fade_in, edge.full, edge.fade_out, edge.persistent_ratio = seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s)
	edge.pulse_amplitude, edge.pulse_frequency = seq_f32(&s), seq_f32(&s)
	fill.full_ratio, edge.full_ratio = seq_f32(&s), seq_f32(&s)
	e.membrane.dest = seq_u32(&s)
	p.blend.src, p.blend.op, p.blend.z_test, p.blend.dest = seq_u32(&s), seq_u32(&s), seq_u32(&s), seq_u32(&s)
	p.birth_ramp_up, p.full_birth_time, p.birth_ramp_down = seq_f32(&s), seq_f32(&s), seq_f32(&s)
	p.full_birth_ratio, p.persistent_count = seq_f32(&s), seq_f32(&s)
	p.lifetime, p.lifetime_var = seq_f32(&s), seq_f32(&s)
	p.normal_speed, p.normal_accel = seq_f32(&s), seq_f32(&s)
	seq_f32s(&s, p.velocity[:])
	seq_f32s(&s, p.acceleration[:])
	seq_f32s(&s, p.scale_keys[:])
	seq_f32s(&s, p.scale_key_times[:])
	for &c in p.color_keys {c = seq_color(&s)}
	seq_f32s(&s, p.color_alphas[:])
	seq_f32s(&s, p.color_times[:])
	p.normal_speed_var = seq_f32(&s)
	p.rotation, p.rotation_var = seq_f32(&s), seq_f32(&s)
	p.rotation_speed, p.rotation_speed_var = seq_f32(&s), seq_f32(&s)
	s.at += 4 // addon models (EFSH_ADDON_MODELS_AT)
	h := &e.holes
	h.start_time, h.end_time, h.start_val, h.end_val = seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s)
	e.edge.width = seq_f32(&s)
	e.edge.width_color = seq_color(&s)
	e.explosion_wind_speed = seq_f32(&s)
	p.texture_count = {seq_u32(&s), seq_u32(&s)}
	a := &e.addon
	a.fade_in, a.fade_out, a.scale_start, a.scale_end, a.scale_in, a.scale_out = seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s)
	s.at += 4 // ambient sound (EFSH_AMBIENT_SOUND_AT)
	e.fill.color_keys[1], e.fill.color_keys[2] = seq_color(&s), seq_color(&s)
	seq_f32s(&s, e.fill.key_scales[:])
	seq_f32s(&s, e.fill.key_times[:])
	e.fill.color_scale = seq_f32(&s)
	p.birth_offset, p.birth_offset_var = seq_f32(&s), seq_f32(&s)
	p.start_frame, p.start_frame_var, p.end_frame = seq_u32(&s), seq_u32(&s), seq_u32(&s)
	p.loop_start, p.loop_start_var, p.frame_count, p.frame_count_var = seq_u32(&s), seq_u32(&s), seq_u32(&s), seq_u32(&s)
	e.flags = seq_u32(&s)
	seq_f32s(&s, e.fill.scale[:])
	return
}

// Impact_Data is an IPCT's DATA.
Impact_Data :: struct {
	duration:         f32,
	orientation:      u32, // 0 surface normal, 1 projectile vector, 2 projectile reflection
	angle_threshold:  f32,
	placement_radius: f32,
	sound_level:      u32,
	no_decal:         bool,
	result:           u8, // 0 default, 1 destroy, 2 bounce, 3 impale, 4 stick
}

impact_data :: proc(d: []u8) -> (i: Impact_Data) {
	s := Seq{d, 0}
	i.duration, i.orientation, i.angle_threshold, i.placement_radius = seq_f32(&s), seq_u32(&s), seq_f32(&s), seq_f32(&s)
	i.sound_level = seq_u32(&s)
	if len(d) >= 22 {i.no_decal, i.result = d[20] & 1 != 0, d[21]}
	return
}

// Decal is a DODT: the decal an impact leaves.
Decal :: struct {
	min_width, max_width, min_height, max_height: f32,
	depth, shininess, parallax_scale:             f32,
	parallax_passes:                              u8,
	flags:                                        u8, // 1 parallax, 2 alpha blending, 4 alpha testing, 8 no subtextures
	color:                                        [4]u8,
}

decal :: proc(d: []u8) -> (dc: Decal) {
	s := Seq{d, 0}
	dc.min_width, dc.max_width, dc.min_height, dc.max_height = seq_f32(&s), seq_f32(&s), seq_f32(&s), seq_f32(&s)
	dc.depth, dc.shininess, dc.parallax_scale = seq_f32(&s), seq_f32(&s), seq_f32(&s)
	if len(d) >= 36 {
		dc.parallax_passes, dc.flags = d[28], d[29]
		dc.color = {d[32], d[33], d[34], d[35]}
	}
	return
}

// Keyframe is one (time, value) point of an IMAD curve; time is 0..1 of the duration.
Keyframe :: struct {
	time, value: f32,
}

// Color_Keyframe is one point of an IMAD color curve: r, g, b, a.
Color_Keyframe :: struct {
	time:  f32,
	color: [4]f32,
}

// Imod_Curve names an IMAD float curve. The HDR and cinematic values each have a multiply and an
// add curve.
Imod_Curve :: enum u8 {
	Eye_Adapt_Speed_Mult, Eye_Adapt_Speed_Add,
	Bloom_Blur_Radius_Mult, Bloom_Blur_Radius_Add,
	Bloom_Threshold_Mult, Bloom_Threshold_Add,
	Bloom_Scale_Mult, Bloom_Scale_Add,
	Target_Lum_Min_Mult, Target_Lum_Min_Add,
	Target_Lum_Max_Mult, Target_Lum_Max_Add,
	Sunlight_Scale_Mult, Sunlight_Scale_Add,
	Sky_Scale_Mult, Sky_Scale_Add,
	Saturation_Mult, Saturation_Add,
	Brightness_Mult, Brightness_Add,
	Contrast_Mult, Contrast_Add,
	Blur_Radius,
	Double_Vision,
	Motion_Blur,
	Radial_Blur_Strength, Radial_Blur_Ramp_Up, Radial_Blur_Start, Radial_Blur_Ramp_Down, Radial_Blur_Down_Start,
	Dof_Strength, Dof_Distance, Dof_Range,
}

// IMOD_CURVE_TAGS is the subrecord each curve is in: mult n in "\xnnIAD", its add in n+0x40.
@(rodata)
IMOD_CURVE_TAGS := [Imod_Curve]string {
	.Eye_Adapt_Speed_Mult = "\x00IAD", .Eye_Adapt_Speed_Add = "@IAD",
	.Bloom_Blur_Radius_Mult = "\x01IAD", .Bloom_Blur_Radius_Add = "AIAD",
	.Bloom_Threshold_Mult = "\x02IAD", .Bloom_Threshold_Add = "BIAD",
	.Bloom_Scale_Mult = "\x03IAD", .Bloom_Scale_Add = "CIAD",
	.Target_Lum_Min_Mult = "\x04IAD", .Target_Lum_Min_Add = "DIAD",
	.Target_Lum_Max_Mult = "\x05IAD", .Target_Lum_Max_Add = "EIAD",
	.Sunlight_Scale_Mult = "\x06IAD", .Sunlight_Scale_Add = "FIAD",
	.Sky_Scale_Mult = "\x07IAD", .Sky_Scale_Add = "GIAD",
	.Saturation_Mult = "\x11IAD", .Saturation_Add = "QIAD",
	.Brightness_Mult = "\x12IAD", .Brightness_Add = "RIAD",
	.Contrast_Mult = "\x13IAD", .Contrast_Add = "SIAD",
	.Blur_Radius = "BNAM",
	.Double_Vision = "VNAM",
	.Motion_Blur = "NAM4",
	.Radial_Blur_Strength = "RNAM", .Radial_Blur_Ramp_Up = "SNAM", .Radial_Blur_Start = "UNAM",
	.Radial_Blur_Ramp_Down = "NAM1", .Radial_Blur_Down_Start = "NAM2",
	.Dof_Strength = "WNAM", .Dof_Distance = "XNAM", .Dof_Range = "YNAM",
}

// Imod_Info is an IMAD's DNAM without its keyframe counts (the curves' lengths say them).
Imod_Info :: struct {
	animatable:        bool,
	duration:          f32,
	radial_use_target: bool,
	radial_center:     [2]f32,
	dof_use_target:    bool,
	dof_flags:         u8, // 1 mode front, 2 mode back, 4 no sky
}

// imod_info reads an IMAD's DNAM: animatable u32@0, duration f32@4, radial blur use target u32@200,
// center f32@204/208, DoF use target u8@224, DoF flags u8@225. ok=false when short.
imod_info :: proc(d: []u8) -> (i: Imod_Info, ok: bool) {
	if len(d) < 226 {return {}, false}
	i.animatable = rd32(d, 0) & 1 != 0
	i.duration = transmute(f32)rd32(d, 4)
	i.radial_use_target = rd32(d, 200) != 0
	i.radial_center = {transmute(f32)rd32(d, 204), transmute(f32)rd32(d, 208)}
	i.dof_use_target, i.dof_flags = d[224] != 0, d[225]
	return i, true
}
