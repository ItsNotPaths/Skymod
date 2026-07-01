package lighting

// Lighting profiles (ROADMAP full-scene-lighting, Phase A). A Light_Profile is the
// complete, authored description of a lighting "look" — sun, ambient, fog, tonemap,
// material reinterpretation, shadows — every value variabilized so it can be tuned
// live and saved. This is the ENB/CS-preset analogue: a single static global look
// (day/night curves would later make each value a function of game-time).
//
// This is a LEAF package: pure data + text IO, NO SDL/GPU (like settings/smath/slog).
// The renderer has its own GPU-facing `Light_Env` (all-vec4, std140) that the app fills
// from the active profile each frame; this package never imports render.
//
// FILE FORMAT: a profile is a FOLDER, not a flat file —
//   profiles/<name>/profile.txt   (these scalars + colors, "key = value" per line)
//   profiles/<name>/grade.png      (optional color-grade LUT — Phase B; absent = no grade)
// because color grading is an IMAGE (a 3D LUT), so a profile needs more than one file.
// Two profiles ship BAKED (#load'd into the binary); user profiles are discovered on disk.
//
// DARK-ALBEDO CALIBRATION: Skyrim diffuse maps are authored low-albedo expecting the
// Creation Engine's bright lighting + HDR adaptation to lift them. Defaults here are
// calibrated against that (a generous ambient + an `albedo_lift`), NOT a neutral-grey
// PBR assumption — otherwise presets read muddy/black.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import smath "../math"

Vec3 :: smath.Vec3

// Tonemap is the post-stage operator (Phase B — stored now so the file format is stable).
Tonemap :: enum {
	Reinhard,
	ACES,
	Filmic,
	None, // passthrough (no curve) — the fullbright dev preset
}

// Veg_Shadows is how vegetation casts sun shadows (Phase D2): Off = foliage casts none; Proxy =
// trees cast a cheap low-poly canopy hull (plants skip); Full = trees + plants cast real
// alpha-tested cutout shadows (accurate, expensive). Opaque geometry + terrain always cast.
Veg_Shadows :: enum {
	Off,
	Proxy,
	Full,
}

// Light_Profile is the full authored lighting look. Phase A actively uses sun / ambient /
// fog / sky + the material `albedo_lift`; the tonemap/grade and shadow fields are stored
// and round-tripped now (forward-compatible sidecars) and wired in Phases B/D.
Light_Profile :: struct {
	name: string, // display name (folder name for sidecars; baked names are fixed)

	// --- Sun (primary directional light) ---
	sun_dir:       Vec3, // direction TOWARD the sun (world space; normalized on use)
	sun_color:     Vec3, // linear RGB
	sun_intensity: f32,

	// --- Hemispheric ambient (sky-up vs ground-down) + a floor so nothing goes black ---
	ambient_sky:       Vec3,
	ambient_ground:    Vec3,
	ambient_intensity: f32,
	ambient_floor:     f32, // minimum light level (counters dark-authored albedo)

	// --- Fog (distance + height) ---
	fog_color:          Vec3,
	fog_start:          f32, // world units where fog begins
	fog_end:            f32, // world units where fog saturates
	fog_height_falloff: f32, // per-unit height attenuation (0 = uniform fog)
	fog_density:        f32, // 0 = no fog … 1 = full

	sky_color: Vec3, // clear / background color (also the fog target at the horizon)

	// --- Tonemap / color grading (Phase B) ---
	exposure:     f32,
	tonemap:      Tonemap,
	contrast:     f32,
	saturation:   f32,
	white_point:  f32,
	color_filter: Vec3, // multiplicative tint

	// --- Material response (reinterpret CE-tuned values for modern shading) ---
	albedo_lift:     f32, // gamma on sampled diffuse (<1 brightens darks; counters dark authoring)
	spec_scale:      f32, // global specular strength (Phase C)
	foliage_spec:    f32, // specular multiplier for alpha-tested cutouts (leaves/grass/plants) — Skyrim
	                      // over-authors foliage spec; 1 = faithful (shiny), <1 mattes it (Phase C)
	gloss_min:       f32, // authored-glossiness → roughness remap endpoints (Phase C)
	gloss_max:       f32,
	emissive_scale:  f32, // (Phase C)
	normal_strength: f32, // normal-map intensity (Phase C)

	// --- Shadows (Phase D) ---
	shadow_strength: f32, // 0 = off … 1 = fully dark shadows
	shadow_bias:     f32, // depth bias (acne vs peter-panning)
	shadow_softness: f32, // PCF kernel scale — higher = softer edges (vanilla soft/weak, realistic sharp)
	veg_shadows:     Veg_Shadows, // vegetation shadow casting tier (off/proxy/full)
}

// DEFAULTS reproduces the engine's CURRENT look exactly (flat ambient 0.3 + sun 0.7 ·
// N·L), so adopting the lighting system is a zero-regression baseline; baked profiles
// diverge from here. Any key missing from a file backfills from this.
DEFAULTS :: Light_Profile {
	name              = "default",
	sun_dir           = {0.4, 0.6, 1.0},
	sun_color         = {1, 1, 1},
	sun_intensity     = 0.7,
	ambient_sky       = {0.3, 0.3, 0.3},
	ambient_ground    = {0.3, 0.3, 0.3},
	ambient_intensity = 1.0,
	ambient_floor     = 0.0,
	fog_color         = {0.10, 0.11, 0.13},
	fog_start         = 0,
	fog_end           = 200000,
	fog_height_falloff = 0,
	fog_density       = 0, // off by default (no regression)
	sky_color         = {0.10, 0.11, 0.13},
	exposure          = 1.0,
	tonemap           = .ACES,
	contrast          = 1.0,
	saturation        = 1.0,
	white_point       = 1.0,
	color_filter      = {1, 1, 1},
	albedo_lift       = 1.0,
	spec_scale        = 1.0,
	foliage_spec      = 1.0, // faithful (Skyrim's shiny foliage); realistic profile lowers it
	gloss_min         = 0.0,
	gloss_max         = 1.0,
	emissive_scale    = 1.0,
	normal_strength   = 1.0,
	shadow_strength   = 0.0, // off by default (harnesses / unset profiles); profiles enable it
	shadow_bias       = 0.0015,
	shadow_softness   = 1.5,
	veg_shadows       = .Full, // real/accurate default; proxy is the low-spec opt-in
}

// Baked profiles embedded in the binary (#load, like shaders). vanilla = close to the
// engine's current/CE look; realistic = a punchier directional + fog + lifted darks.
VANILLA_BAKED :: #load("baked/vanilla.txt", string)
REALISTIC_BAKED :: #load("baked/realistic.txt", string)
// fullbright = a dev/low-spec preset: no sun, flat full ambient, no shadows/fog/spec, passthrough
// tonemap → the raw textures on screen, and the CSM passes skip entirely (the big perf win).
FULLBRIGHT_BAKED :: #load("baked/fullbright.txt", string)

// SUBDIR is the on-disk profiles folder (beside the exe) scanned for sidecar profiles.
SUBDIR :: "profiles"
FILE_NAME :: "profile.txt"

// baked returns the two embedded profiles, already parsed. The caller owns the returned
// slice (delete it); the profiles' `name` strings are static (baked-text constants
// supply them, but we set them explicitly so they don't depend on the file).
baked :: proc(allocator := context.allocator) -> []Light_Profile {
	out := make([]Light_Profile, 3, allocator)
	out[0] = parse(VANILLA_BAKED)
	out[0].name = "vanilla"
	out[1] = parse(REALISTIC_BAKED)
	out[1].name = "realistic"
	out[2] = parse(FULLBRIGHT_BAKED)
	out[2].name = "fullbright"
	return out
}

// parse builds a Light_Profile from "key = value" text, starting from DEFAULTS so any
// absent key keeps its default (forward/backward-compatible sidecars). Unknown keys are
// ignored. Numbers are base-10 floats; colors/vectors are "x, y, z".
parse :: proc(text: string) -> Light_Profile {
	p := DEFAULTS
	apply_text(&p, text)
	return p
}

// apply_text overlays "key = value" lines onto an EXISTING profile — each present key overrides,
// each absent key keeps p's current value. This is the LAYERING primitive: a lighting mod's
// (possibly partial) txt applies on top of the base ⊕ lower-priority mods. Unknown keys ignored.
apply_text :: proc(p: ^Light_Profile, text: string) {
	it := text
	for raw in strings.split_lines_iterator(&it) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(line[:eq])
		val := strings.trim_space(line[eq + 1:])
		apply_kv(p, key, val)
	}
}

// load reads <base>/profiles/<name>/profile.txt into a profile. `name` is BORROWED (stored
// as p.name) — the caller owns it (e.g. an app-side names list). ok=false if the file is
// missing/unreadable. A profile holds NO heap-owned strings, so there is nothing to destroy.
load :: proc(base, name: string) -> (p: Light_Profile, ok: bool) {
	path, _ := filepath.join({base, SUBDIR, name, FILE_NAME}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return {}, false
	}
	p = parse(string(data))
	p.name = name
	return p, true
}

// save writes a profile to <base>/profiles/<name>/profile.txt, creating the folder.
// `name` overrides p.name (so "Save As" can fork a baked profile to a new sidecar).
save :: proc(p: ^Light_Profile, base, name: string) -> bool {
	root, _ := filepath.join({base, SUBDIR}, context.temp_allocator)
	dir, _ := filepath.join({base, SUBDIR, name}, context.temp_allocator)
	os.make_directory(root) // ignore "already exists"
	if err := os.make_directory(dir); err != nil && !os.is_dir(dir) {
		return false
	}
	path, _ := filepath.join({dir, FILE_NAME}, context.temp_allocator)
	return os.write_entire_file(path, transmute([]byte)serialize(p, name)) == nil
}

// discover lists the sidecar profile names under <base>/profiles/ (each is a subfolder
// holding a profile.txt). Returns folder names; caller owns the slice + strings.
discover :: proc(base: string, allocator := context.allocator) -> []string {
	context.allocator = allocator
	root, _ := filepath.join({base, SUBDIR}, context.temp_allocator)
	fd, oerr := os.open(root)
	if oerr != nil {
		return {}
	}
	defer os.close(fd)
	infos, rerr := os.read_dir(fd, -1, context.temp_allocator)
	if rerr != nil {
		return {}
	}
	out := make([dynamic]string, allocator)
	for info in infos {
		if info.type != .Directory {
			continue
		}
		marker, _ := filepath.join({info.fullpath, FILE_NAME}, context.temp_allocator)
		if os.exists(marker) {
			append(&out, strings.clone(info.name, allocator))
		}
	}
	return out[:]
}

// --- internals ---

@(private)
apply_kv :: proc(p: ^Light_Profile, key, val: string) {
	switch key {
	case "name":
		// handled by the loader (folder name); ignore in-file
	case "sun_dir":
		p.sun_dir = parse_vec3(val, p.sun_dir)
	case "sun_color":
		p.sun_color = parse_vec3(val, p.sun_color)
	case "sun_intensity":
		p.sun_intensity = parse_f32(val, p.sun_intensity)
	case "ambient_sky":
		p.ambient_sky = parse_vec3(val, p.ambient_sky)
	case "ambient_ground":
		p.ambient_ground = parse_vec3(val, p.ambient_ground)
	case "ambient_intensity":
		p.ambient_intensity = parse_f32(val, p.ambient_intensity)
	case "ambient_floor":
		p.ambient_floor = parse_f32(val, p.ambient_floor)
	case "fog_color":
		p.fog_color = parse_vec3(val, p.fog_color)
	case "fog_start":
		p.fog_start = parse_f32(val, p.fog_start)
	case "fog_end":
		p.fog_end = parse_f32(val, p.fog_end)
	case "fog_height_falloff":
		p.fog_height_falloff = parse_f32(val, p.fog_height_falloff)
	case "fog_density":
		p.fog_density = parse_f32(val, p.fog_density)
	case "sky_color":
		p.sky_color = parse_vec3(val, p.sky_color)
	case "exposure":
		p.exposure = parse_f32(val, p.exposure)
	case "tonemap":
		switch strings.to_lower(val, context.temp_allocator) {
		case "reinhard":
			p.tonemap = .Reinhard
		case "aces":
			p.tonemap = .ACES
		case "filmic":
			p.tonemap = .Filmic
		case "none":
			p.tonemap = .None
		}
	case "contrast":
		p.contrast = parse_f32(val, p.contrast)
	case "saturation":
		p.saturation = parse_f32(val, p.saturation)
	case "white_point":
		p.white_point = parse_f32(val, p.white_point)
	case "color_filter":
		p.color_filter = parse_vec3(val, p.color_filter)
	case "albedo_lift":
		p.albedo_lift = parse_f32(val, p.albedo_lift)
	case "spec_scale":
		p.spec_scale = parse_f32(val, p.spec_scale)
	case "foliage_spec":
		p.foliage_spec = parse_f32(val, p.foliage_spec)
	case "gloss_min":
		p.gloss_min = parse_f32(val, p.gloss_min)
	case "gloss_max":
		p.gloss_max = parse_f32(val, p.gloss_max)
	case "emissive_scale":
		p.emissive_scale = parse_f32(val, p.emissive_scale)
	case "normal_strength":
		p.normal_strength = parse_f32(val, p.normal_strength)
	case "shadow_strength":
		p.shadow_strength = parse_f32(val, p.shadow_strength)
	case "shadow_bias":
		p.shadow_bias = parse_f32(val, p.shadow_bias)
	case "shadow_softness":
		p.shadow_softness = parse_f32(val, p.shadow_softness)
	case "veg_shadows":
		switch strings.to_lower(val, context.temp_allocator) {
		case "off":
			p.veg_shadows = .Off
		case "proxy":
			p.veg_shadows = .Proxy
		case "full":
			p.veg_shadows = .Full
		}
	}
}

// serialize renders a profile to "key = value" text (grouped, with comments), in a fixed
// order. Allocates on the temp allocator (caller writes it immediately). `name` is written
// as a comment header only — the authoritative name is the folder.
serialize :: proc(p: ^Light_Profile, name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# SkyMod lighting profile: ")
	strings.write_string(&b, name)
	strings.write_string(&b, "\n# \"key = value\" per line; '#' starts a comment.\n\n# Sun\n")
	wv(&b, "sun_dir", p.sun_dir)
	wv(&b, "sun_color", p.sun_color)
	wf(&b, "sun_intensity", p.sun_intensity)
	strings.write_string(&b, "\n# Ambient\n")
	wv(&b, "ambient_sky", p.ambient_sky)
	wv(&b, "ambient_ground", p.ambient_ground)
	wf(&b, "ambient_intensity", p.ambient_intensity)
	wf(&b, "ambient_floor", p.ambient_floor)
	strings.write_string(&b, "\n# Fog\n")
	wv(&b, "fog_color", p.fog_color)
	wf(&b, "fog_start", p.fog_start)
	wf(&b, "fog_end", p.fog_end)
	wf(&b, "fog_height_falloff", p.fog_height_falloff)
	wf(&b, "fog_density", p.fog_density)
	wv(&b, "sky_color", p.sky_color)
	strings.write_string(&b, "\n# Tonemap / grading (Phase B)\n")
	wf(&b, "exposure", p.exposure)
	tm := "aces"
	switch p.tonemap {
	case .Reinhard:
		tm = "reinhard"
	case .ACES:
		tm = "aces"
	case .Filmic:
		tm = "filmic"
	case .None:
		tm = "none"
	}
	strings.write_string(&b, "tonemap = ")
	strings.write_string(&b, tm)
	strings.write_byte(&b, '\n')
	wf(&b, "contrast", p.contrast)
	wf(&b, "saturation", p.saturation)
	wf(&b, "white_point", p.white_point)
	wv(&b, "color_filter", p.color_filter)
	strings.write_string(&b, "\n# Material response\n")
	wf(&b, "albedo_lift", p.albedo_lift)
	wf(&b, "spec_scale", p.spec_scale)
	wf(&b, "foliage_spec", p.foliage_spec)
	wf(&b, "gloss_min", p.gloss_min)
	wf(&b, "gloss_max", p.gloss_max)
	wf(&b, "emissive_scale", p.emissive_scale)
	wf(&b, "normal_strength", p.normal_strength)
	strings.write_string(&b, "\n# Shadows (Phase D)\n")
	wf(&b, "shadow_strength", p.shadow_strength)
	wf(&b, "shadow_bias", p.shadow_bias)
	wf(&b, "shadow_softness", p.shadow_softness)
	vs := "proxy"
	switch p.veg_shadows {
	case .Off:
		vs = "off"
	case .Proxy:
		vs = "proxy"
	case .Full:
		vs = "full"
	}
	strings.write_string(&b, "veg_shadows = ")
	strings.write_string(&b, vs)
	strings.write_byte(&b, '\n')
	return strings.to_string(b)
}

// serialize_delta renders ONLY the fields where `p` differs from `base` — the minimal partial txt
// for a "deltas from enabled" lighting mod, which layers on top of the resolved stack below it.
serialize_delta :: proc(p, base: ^Light_Profile, name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "# SkyMod lighting mod (delta): %s\n", name)
	strings.write_string(&b, "# only the fields that differ from the layer below are written.\n\n")
	wv_d(&b, "sun_dir", p.sun_dir, base.sun_dir)
	wv_d(&b, "sun_color", p.sun_color, base.sun_color)
	wf_d(&b, "sun_intensity", p.sun_intensity, base.sun_intensity)
	wv_d(&b, "ambient_sky", p.ambient_sky, base.ambient_sky)
	wv_d(&b, "ambient_ground", p.ambient_ground, base.ambient_ground)
	wf_d(&b, "ambient_intensity", p.ambient_intensity, base.ambient_intensity)
	wf_d(&b, "ambient_floor", p.ambient_floor, base.ambient_floor)
	wv_d(&b, "fog_color", p.fog_color, base.fog_color)
	wf_d(&b, "fog_start", p.fog_start, base.fog_start)
	wf_d(&b, "fog_end", p.fog_end, base.fog_end)
	wf_d(&b, "fog_height_falloff", p.fog_height_falloff, base.fog_height_falloff)
	wf_d(&b, "fog_density", p.fog_density, base.fog_density)
	wv_d(&b, "sky_color", p.sky_color, base.sky_color)
	wf_d(&b, "exposure", p.exposure, base.exposure)
	if p.tonemap != base.tonemap {fmt.sbprintf(&b, "tonemap = %s\n", tonemap_str(p.tonemap))}
	wf_d(&b, "contrast", p.contrast, base.contrast)
	wf_d(&b, "saturation", p.saturation, base.saturation)
	wf_d(&b, "white_point", p.white_point, base.white_point)
	wv_d(&b, "color_filter", p.color_filter, base.color_filter)
	wf_d(&b, "albedo_lift", p.albedo_lift, base.albedo_lift)
	wf_d(&b, "spec_scale", p.spec_scale, base.spec_scale)
	wf_d(&b, "foliage_spec", p.foliage_spec, base.foliage_spec)
	wf_d(&b, "gloss_min", p.gloss_min, base.gloss_min)
	wf_d(&b, "gloss_max", p.gloss_max, base.gloss_max)
	wf_d(&b, "emissive_scale", p.emissive_scale, base.emissive_scale)
	wf_d(&b, "normal_strength", p.normal_strength, base.normal_strength)
	wf_d(&b, "shadow_strength", p.shadow_strength, base.shadow_strength)
	wf_d(&b, "shadow_bias", p.shadow_bias, base.shadow_bias)
	wf_d(&b, "shadow_softness", p.shadow_softness, base.shadow_softness)
	if p.veg_shadows != base.veg_shadows {fmt.sbprintf(&b, "veg_shadows = %s\n", veg_str(p.veg_shadows))}
	return strings.to_string(b)
}

@(private)
tonemap_str :: proc(t: Tonemap) -> string {
	switch t {
	case .Reinhard:
		return "reinhard"
	case .ACES:
		return "aces"
	case .Filmic:
		return "filmic"
	case .None:
		return "none"
	}
	return "aces"
}

@(private)
veg_str :: proc(v: Veg_Shadows) -> string {
	switch v {
	case .Off:
		return "off"
	case .Proxy:
		return "proxy"
	case .Full:
		return "full"
	}
	return "full"
}

@(private)
wf_d :: proc(b: ^strings.Builder, key: string, v, base: f32) {
	if v != base {wf(b, key, v)}
}

@(private)
wv_d :: proc(b: ^strings.Builder, key: string, v, base: Vec3) {
	if v != base {wv(b, key, v)}
}

@(private)
wf :: proc(b: ^strings.Builder, key: string, v: f32) {
	fmt.sbprintf(b, "%s = %g\n", key, v)
}

@(private)
wv :: proc(b: ^strings.Builder, key: string, v: Vec3) {
	fmt.sbprintf(b, "%s = %g, %g, %g\n", key, v[0], v[1], v[2])
}

@(private)
parse_f32 :: proc(s: string, fallback: f32) -> f32 {
	if v, ok := strconv.parse_f32(strings.trim_space(s)); ok {
		return v
	}
	return fallback
}

@(private)
parse_vec3 :: proc(s: string, fallback: Vec3) -> Vec3 {
	out := fallback
	rest := s
	for i in 0 ..< 3 {
		comma := strings.index_byte(rest, ',')
		field := rest if comma < 0 else rest[:comma]
		out[i] = parse_f32(field, fallback[i])
		if comma < 0 {
			break
		}
		rest = rest[comma + 1:]
	}
	return out
}
