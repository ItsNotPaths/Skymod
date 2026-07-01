package main

// Lighting profile management + the profile→GPU bridge (ROADMAP full-scene-lighting Phase A).
// This is where the app glues the pure-data lighting package (lighting.Light_Profile) to the
// renderer's per-frame GPU block (render.Light_Env): it owns the list of available profiles
// (two BAKED into the binary + any discovered sidecar folders under <base>/profiles/), the
// live-editable active profile, and the save path.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../formats/esm"
import "../lighting"
import smath "../math"
import "../mods"
import "../render"

// GAME_PROFILE_NAME is the sidecar profile the installer/boot derives from the user's own
// Skyrim.esm imagespace data — a data-faithful "vanilla" generated LOCALLY (never shipped;
// the extracted Bethesda values are their content, kept on their machine like content/).
GAME_PROFILE_NAME :: "skyrim"

// ensure_game_lighting_profile generates the data-faithful "skyrim" profile from the user's OWN
// Skyrim.esm (the default clear-day imagespace), once, if it doesn't already exist. The authentic
// GRADE (saturation / contrast / tint) is taken verbatim — those are pipeline-independent ratios;
// the HDR-scale numbers (white / sunlight / brightness) are calibrated to CE's renderer, not ours,
// so we keep our own exposure/white and just adopt brightness as a gentle exposure nudge. Starts
// from our baked "vanilla" (sun/ambient/fog) and overlays the game's grade. Idempotent + skips
// silently if source_game is unset. Reads from the user's files, writes to their local profiles/.
ensure_game_lighting_profile :: proc(base, src_game: string) {
	if base == "" || src_game == "" {
		return
	}
	marker, _ := filepath.join({base, lighting.SUBDIR, GAME_PROFILE_NAME, lighting.FILE_NAME}, context.temp_allocator)
	if os.exists(marker) {
		return // already generated
	}
	esm_path, _ := filepath.join({src_game, "Data", "Skyrim.esm"}, context.temp_allocator)
	data, rerr := os.read_entire_file(esm_path, context.allocator)
	if rerr != nil {
		return // no master to read — skip silently (hand-tuned baked vanilla still available)
	}
	defer delete(data)

	Pick :: struct {
		im:   esm.Imagespace,
		rank: int, // 0 none, 1 DefaultImageSpace, 2 a clear-day exterior
	}
	pick: Pick
	esm.walk(data, proc(rec: esm.Record, wc: esm.Walk_Context, user: rawptr) -> bool {
		p := (^Pick)(user)
		if esm.sig(rec) != "IMGS" {
			return true
		}
		fl, backing, ok := esm.fields(rec)
		if !ok {
			return true
		}
		defer {delete(fl);if backing != nil {delete(backing)}}
		edid := esm.editor_id(fl)
		im, dok := esm.decode_imagespace(fl)
		if !dok {
			return true
		}
		// Prefer a clear-day exterior grade (ISSkyrimClearDAY*), else the neutral default.
		if strings.has_prefix(edid, "ISSkyrimClearDAY") && p.rank < 2 {
			p.im, p.rank = im, 2
		} else if edid == "DefaultImageSpace" && p.rank < 1 {
			p.im, p.rank = im, 1
		}
		return true
	}, &pick)
	if pick.rank == 0 {
		return // no imagespace found
	}

	baked := lighting.baked(context.temp_allocator)
	prof := baked[0] // start from our hand-tuned "vanilla" (sun/ambient/fog/albedo_lift)
	// Overlay the game's authentic grade (verbatim) + a gentle exposure from its brightness.
	prof.tonemap = .Reinhard // CE-faithful operator
	prof.veg_shadows = .Full // the real game casts full per-object tree shadows (proxy is our low-spec option)
	prof.saturation = pick.im.saturation
	prof.contrast = pick.im.contrast
	prof.exposure = pick.im.brightness
	a := pick.im.tint_amount
	prof.color_filter = {
		1 - a + a * pick.im.tint_color.x,
		1 - a + a * pick.im.tint_color.y,
		1 - a + a * pick.im.tint_color.z,
	}
	if lighting.save(&prof, base, GAME_PROFILE_NAME) {
		log.infof("lighting: derived data-faithful %q profile from your Skyrim.esm imagespace", GAME_PROFILE_NAME)
	}
}

// Lighting_State owns the profile picker + the active editable profile.
Lighting_State :: struct {
	base:     string,                  // exe dir (borrowed; for sidecar load/save/discover)
	names:    [dynamic]string,         // owned profile names: baked first, then sidecars
	baked:    []lighting.Light_Profile, // the embedded profiles (no heap strings inside)
	n_baked:  int,                     // names[:n_baked] are the baked ones
	active:   lighting.Light_Profile,  // the live profile (base ⊕ enabled lighting mods; configurator edits)
	current:  int,                     // index into names (the base)
	mprofile: ^mods.Profile,           // borrowed: enabled lighting mods layer onto the base
}

// lighting_state_init builds the picker: the baked profiles, then on-disk sidecars (whose
// names don't duplicate a baked one), and loads `want` (a baked name or sidecar folder) as
// the active profile — falling back to index 0 if `want` isn't found.
lighting_state_init :: proc(base, want: string, mprofile: ^mods.Profile) -> Lighting_State {
	ls: Lighting_State
	ls.base = base
	ls.mprofile = mprofile
	ls.baked = lighting.baked()
	ls.n_baked = len(ls.baked)
	for p in ls.baked {
		append(&ls.names, strings.clone(p.name))
	}
	sidecars := lighting.discover(base) // strings cloned by discover; we take ownership
	for n in sidecars {
		if slice_has(ls.names[:], n) {
			delete(n) // a sidecar overriding a baked name reuses the baked slot
		} else {
			append(&ls.names, n)
		}
	}
	delete(sidecars)

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
	delete(ls.baked)
	ls^ = {}
}

// lighting_select picks base profile names[i] and re-resolves the active look (base ⊕ enabled
// lighting mods). A sidecar base wins over a baked one of the same name.
lighting_select :: proc(ls: ^Lighting_State, i: int) {
	if i < 0 || i >= len(ls.names) {
		return
	}
	ls.current = i
	ls.active = lighting_resolve(ls)
}

// lighting_resolve computes the active profile: the selected base (sidecar wins over baked) with
// every ENABLED lighting mod layered on top in mod-list order (top→bottom; the lowest-listed mod
// wins per field). A lighting mod is mods/<name>/skymod/lighting.txt (partial txts allowed).
lighting_resolve :: proc(ls: ^Lighting_State) -> lighting.Light_Profile {
	base: lighting.Light_Profile
	if p, ok := lighting.load(ls.base, ls.names[ls.current]); ok {
		base = p
	} else if ls.current < ls.n_baked {
		base = ls.baked[ls.current]
		base.name = ls.names[ls.current]
	} else {
		base = lighting.DEFAULTS
	}
	if ls.mprofile != nil {
		for modname in mods.profile_enabled_mods(ls.mprofile, context.temp_allocator) {
			if modname == mods.BASE_MOD {
				continue
			}
			if data, rerr := os.read_entire_file(lighting_mod_path(ls.base, modname), context.temp_allocator);
			   rerr == nil {
				lighting.apply_text(&base, string(data))
			}
		}
	}
	return base
}

// lighting_mod_path is mods/<modname>/skymod/lighting.txt — the lighting payload a mod may carry.
lighting_mod_path :: proc(base, modname: string, allocator := context.temp_allocator) -> string {
	r, _ := filepath.join({base, MODS_DIRNAME, modname, "skymod", "lighting.txt"}, allocator)
	return r
}

// lighting_write_mod writes the active profile as a lighting mod at mods/<name>/skymod/lighting.txt.
// `delta` writes only the fields differing from the resolved stack below (a minimal partial txt);
// otherwise the whole config. The caller enables the mod in the profile(s) and re-resolves.
lighting_write_mod :: proc(ls: ^Lighting_State, name: string, delta: bool) -> bool {
	if name == "" {
		return false
	}
	txt: string
	if delta {
		resolved := lighting_resolve(ls) // base ⊕ existing mods, WITHOUT the live edits
		txt = lighting.serialize_delta(&ls.active, &resolved, name)
	} else {
		txt = lighting.serialize(&ls.active, name)
	}
	_ = os.make_directory(mods_root(ls.base))
	moddir, _ := filepath.join({ls.base, MODS_DIRNAME, name}, context.temp_allocator)
	_ = os.make_directory(moddir)
	skydir, _ := filepath.join({moddir, "skymod"}, context.temp_allocator)
	_ = os.make_directory(skydir)
	path, _ := filepath.join({skydir, "lighting.txt"}, context.temp_allocator)
	return os.write_entire_file(path, transmute([]byte)txt) == nil
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
