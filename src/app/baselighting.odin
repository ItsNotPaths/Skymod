package main

// The pinned baseline lighting content mod ("baselighting") in content/ — the lighting analogue of
// content/baseui. It holds the selectable lighting PRESETS as flat <name>.txt files; one is the
// active look (the picker; see lighting_setup.odin) and they do NOT layer. Like baseui it's an
// always-present, engine-owned BASELINE forced across all profiles (a locked "SkyMod Lighting" row;
// see system_mod_names) and REGENERATABLE: the stylized presets from the exe's #load-embedded copies,
// the data-faithful "vanilla" from the user's OWN Skyrim.esm imagespace (local, never shipped — the
// extracted Bethesda values are their content, kept on their machine like content/).
//
//   content/baselighting/vanilla.txt    data-faithful baseline (Skyrim.esm clear-day grade); cached once
//   content/baselighting/realistic.txt  shipped stylized preset (rewritten from #load each boot)
//   content/baselighting/<user>.txt     looks saved from the in-game configurator

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../formats/esm"
import "../lighting"

// DEFAULT_LIGHTING is the preset selected when `lighting_profile` is unset/missing — the
// data-faithful baseline derived from the user's install.
DEFAULT_LIGHTING :: "vanilla"

// baselighting_dir returns <base>/content/baselighting — the pinned lighting content mod holding the
// preset .txt files (the picker's source; see lighting_state_init).
baselighting_dir :: proc(base: string, allocator := context.allocator) -> string {
	p, _ := filepath.join({base, "content", "baselighting"}, allocator)
	return p
}

// baselighting_ensure makes sure content/baselighting is populated. The stylized shipped presets
// (realistic) are rewritten from the exe's #load-embedded copies every boot (engine-owned defaults,
// like baseui's Lua). The data-faithful "vanilla" is DERIVED ONCE from the user's own Skyrim.esm
// imagespace (the clear-day grade) and cached — skipped if it already exists (avoids the esm walk
// each boot; user customization layers via new presets, not by editing these). Idempotent.
baselighting_ensure :: proc(base, src_game: string) {
	content, _ := filepath.join({base, "content"}, context.temp_allocator)
	_ = os.make_directory(content)
	dir := baselighting_dir(base, context.temp_allocator)
	_ = os.make_directory(dir)

	baked := lighting.baked(context.temp_allocator) // [vanilla, realistic, fullbright]

	// Shipped stylized preset(s): rewrite from the embedded copy each boot (engine-owned defaults).
	realistic := baked[1]
	_ = lighting.save(&realistic, dir, "realistic")

	// Data-faithful vanilla: derive ONCE from the user's Skyrim.esm imagespace, cached thereafter.
	vfile := strings.concatenate({DEFAULT_LIGHTING, lighting.FILE_EXT}, context.temp_allocator)
	vpath, _ := filepath.join({dir, vfile}, context.temp_allocator)
	if os.exists(vpath) {
		return // already generated
	}
	prof := baked[0] // start from our hand-tuned "vanilla" (sun/ambient/fog/albedo_lift)
	if im, ok := derive_skyrim_grade(src_game); ok {
		// Overlay the game's authentic grade (verbatim) + a gentle exposure from its brightness. The
		// GRADE ratios are pipeline-independent; the HDR-scale numbers are CE-calibrated so we keep our
		// own exposure/white and just adopt brightness as a nudge.
		prof.tonemap = .Reinhard // CE-faithful operator
		prof.veg_shadows = .Full // the real game casts full per-object tree shadows (proxy is our low-spec option)
		prof.saturation = im.saturation
		prof.contrast = im.contrast
		prof.exposure = im.brightness
		a := im.tint_amount
		prof.color_filter = {
			1 - a + a * im.tint_color.x,
			1 - a + a * im.tint_color.y,
			1 - a + a * im.tint_color.z,
		}
		log.infof("lighting: derived data-faithful %q preset from your Skyrim.esm imagespace", DEFAULT_LIGHTING)
	}
	_ = lighting.save(&prof, dir, DEFAULT_LIGHTING)
}

// derive_skyrim_grade reads the default clear-day imagespace grade from the user's own Skyrim.esm
// (prefers ISSkyrimClearDAY*, else DefaultImageSpace). ok=false if the master is unreadable / has no
// imagespace / src_game is unset. Reads from the user's files; nothing is written here.
@(private = "file")
derive_skyrim_grade :: proc(src_game: string) -> (esm.Imagespace, bool) {
	if src_game == "" {
		return {}, false
	}
	esm_path, _ := filepath.join({src_game, "Data", "Skyrim.esm"}, context.temp_allocator)
	data, rerr := os.read_entire_file(esm_path, context.allocator)
	if rerr != nil {
		return {}, false // no master to read — baked vanilla stands in
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
		if strings.has_prefix(edid, "ISSkyrimClearDAY") && p.rank < 2 {
			p.im, p.rank = im, 2
		} else if edid == "DefaultImageSpace" && p.rank < 1 {
			p.im, p.rank = im, 1
		}
		return true
	}, &pick)
	if pick.rank == 0 {
		return {}, false
	}
	return pick.im, true
}
