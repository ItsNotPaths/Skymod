package main

// Lighting preset management + the preset→GPU bridge (ROADMAP full-scene-lighting Phase A). This is
// where the app glues the pure-data lighting package (lighting.Light_Profile) to the renderer's
// per-frame GPU block (render.Light_Env). The available presets are the flat <name>.txt files in the
// pinned baseline content mod content/baselighting (see baselighting.odin) plus the hardcoded
// "fullbright" dev preset; one is the active look. Presets are complete + mutually exclusive — they
// do NOT layer (a saved look is just another selectable preset).

import "core:strings"
import "../lighting"
import smath "../math"
import "../render"

// FULLBRIGHT_NAME is the one preset with no .txt on disk: the dev/low-spec look (no sun, flat full
// ambient, passthrough tonemap → raw textures) whose zero shadow_strength makes the CSM passes skip
// entirely. Hardcoded (from the #load-embedded copy) so it's always available and never edited.
FULLBRIGHT_NAME :: "fullbright"

// Lighting_State owns the preset picker + the active editable profile.
Lighting_State :: struct {
	base:    string,                 // exe dir (borrowed; for content/baselighting load/save/discover)
	names:   [dynamic]string,        // owned preset names: content/baselighting/*.txt + "fullbright"
	active:  lighting.Light_Profile, // the live profile (selected preset; the configurator edits it)
	current: int,                    // index into names
}

// lighting_state_init builds the picker from the content/baselighting presets (+ the hardcoded
// fullbright), then loads `want` (a preset name) as the active profile — falling back to index 0
// if `want` isn't found. baselighting_ensure must have run first (it materializes vanilla.txt).
lighting_state_init :: proc(base, want: string) -> Lighting_State {
	ls: Lighting_State
	ls.base = base
	names := lighting.discover(baselighting_dir(base, context.temp_allocator))
	for n in names {
		append(&ls.names, n) // discover clones each name; we take ownership of the strings
	}
	delete(names) // free just the slice backing (the strings moved into ls.names)
	if len(ls.names) == 0 {
		append(&ls.names, strings.clone(DEFAULT_LIGHTING)) // defensive: no presets on disk yet
	}
	if !slice_has(ls.names[:], FULLBRIGHT_NAME) {
		append(&ls.names, strings.clone(FULLBRIGHT_NAME))
	}

	ls.current = 0
	for n, i in ls.names {
		if n == want {
			ls.current = i
			break
		}
	}
	lighting_select(&ls, ls.current)
	return ls
}

lighting_state_destroy :: proc(ls: ^Lighting_State) {
	for n in ls.names {
		delete(n)
	}
	delete(ls.names)
	ls^ = {}
}

// lighting_select picks preset names[i] and loads it as the active look.
lighting_select :: proc(ls: ^Lighting_State, i: int) {
	if i < 0 || i >= len(ls.names) {
		return
	}
	ls.current = i
	ls.active = lighting_resolve(ls)
}

// lighting_resolve loads the selected preset: the on-disk content/baselighting/<name>.txt wins; the
// hardcoded fullbright (#load) is the fallback for that name; else DEFAULTS.
lighting_resolve :: proc(ls: ^Lighting_State) -> lighting.Light_Profile {
	name := ls.names[ls.current]
	if p, ok := lighting.load(baselighting_dir(ls.base, context.temp_allocator), name); ok {
		return p
	}
	if name == FULLBRIGHT_NAME {
		baked := lighting.baked(context.temp_allocator) // [vanilla, realistic, fullbright]
		p := baked[2]
		p.name = FULLBRIGHT_NAME
		return p
	}
	base := lighting.DEFAULTS
	base.name = name
	return base
}

// lighting_save_preset writes the active look as a preset at content/baselighting/<name>.txt (a full
// serialize — presets are complete looks), then makes it the current selection. The configurator's
// "Save" calls this; the saved file appears in the picker and can be shared like any content file.
lighting_save_preset :: proc(ls: ^Lighting_State, name: string) -> bool {
	if name == "" {
		return false
	}
	if !lighting.save(&ls.active, baselighting_dir(ls.base, context.temp_allocator), name) {
		return false
	}
	idx := -1
	for n, i in ls.names {
		if n == name {
			idx = i
			break
		}
	}
	if idx < 0 {
		append(&ls.names, strings.clone(name))
		idx = len(ls.names) - 1
	}
	ls.current = idx // ls.active already holds the saved values — no re-resolve needed
	return true
}

// lighting_env flattens a profile + the current camera position into the renderer's per-frame
// lighting block. Packing mirrors the `Light` UBO in mesh.frag (all-vec4, std140). Called each
// frame (cheap) so live edits + camera motion (fog distance) take effect immediately.
lighting_env :: proc(p: ^lighting.Light_Profile, cam_pos: smath.Vec3) -> render.Light_Env {
	return render.Light_Env {
		sun_dir        = {p.sun_dir.x, p.sun_dir.y, p.sun_dir.z, p.albedo_lift},
		sun_color      = {p.sun_color.x, p.sun_color.y, p.sun_color.z, p.sun_intensity},
		ambient_sky    = {p.ambient_sky.x, p.ambient_sky.y, p.ambient_sky.z, p.ambient_floor},
		ambient_ground = {p.ambient_ground.x, p.ambient_ground.y, p.ambient_ground.z, p.ambient_intensity},
		fog_color      = {p.fog_color.x, p.fog_color.y, p.fog_color.z, 0},
		fog_params     = {p.fog_start, p.fog_end, p.fog_height_falloff, p.fog_density},
		cam_pos        = {cam_pos.x, cam_pos.y, cam_pos.z, 0},
		material       = {p.spec_scale, p.normal_strength, p.emissive_scale, p.foliage_spec},
	}
}

// lighting_post flattens a profile's tonemap/grade fields into the renderer's post block.
// The tonemap enum maps to the post.frag operator index (0 Reinhard / 1 ACES / 2 Filmic).
lighting_post :: proc(p: ^lighting.Light_Profile) -> render.Post_Params {
	mode: f32 = 0
	switch p.tonemap {
	case .Reinhard:
		mode = 0
	case .ACES:
		mode = 1
	case .Filmic:
		mode = 2
	case .None:
		mode = 3
	}
	return render.Post_Params {
		params = {p.exposure, mode, p.white_point, p.contrast},
		grade  = {p.color_filter.x, p.color_filter.y, p.color_filter.z, p.saturation},
	}
}

@(private = "file")
slice_has :: proc(s: []string, v: string) -> bool {
	for x in s {
		if x == v {
			return true
		}
	}
	return false
}
