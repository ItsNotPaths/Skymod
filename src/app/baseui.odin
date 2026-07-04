package main

// The synthesized built-in UI mod ("baseui") in content/. The default player UI — our Lua
// reimplementation of the base-game menus + assets converted from the user's OWN Skyrim install — is
// generated into <base>/content/baseui. It's the always-present BASELINE content mod (forced across
// all profiles, above vanilla + below user mods; see mount_game_mods / content_mod_dirs), packaged
// like a mods/ mod. Both parts are REGENERATABLE: the Lua from the exe's #load-embedded copies, the
// assets from the exe's extraction code run against the user's install. Falls back to the imgui menu
// if no font is found.
//
//   content/baseui/lua/...        the Lua screens + framework (rewritten from #load-embedded each boot)
//   content/baseui/bethassets/... DDS assets extracted from the install's SWFs (cached; mounted in VFS)

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "../font"
import "../formats/dds"
import "../formats/swf"
import "../ui"
import "../vfs"

// UI_REF_EM is the reference em (px) the UI's `scale == 1` maps to — the normalization screens author
// against (e.g. scale 0.31 ≈ 20px). The live atlas bakes each glyph at scale×UI_REF_EM, so this is
// NOT a single bake size that everything minifies from; it's just the authoring unit.
UI_REF_EM :: f32(64)

// baseui_lua_root returns <base>/content/baseui/lua — the driver code of the "baseui" content mod
// (our UI reimplementation). Its sibling content/baseui/bethassets holds assets converted from the
// install (mounted into the VFS as the baseline; see mount_game_mods / content_mod_dirs).
baseui_lua_root :: proc(base: string, allocator := context.allocator) -> string {
	p, _ := filepath.join({base, "content", "baseui", "lua"}, allocator)
	return p
}

// baseui_assets_dir returns <base>/content/baseui/bethassets — where install-time extraction writes
// the Bethesda-derived UI assets (at Bethesda-relative paths), mounted into the VFS as the baseline.
baseui_assets_dir :: proc(base: string, allocator := context.allocator) -> string {
	p, _ := filepath.join({base, "content", "baseui", "bethassets"}, allocator)
	return p
}

// baseui_ensure makes sure content/baseui is populated: the Lua framework + screens (engine-owned
// defaults) are rewritten from the embedded copies every boot so a build update can't leave a stale
// screen behind (user customization layers on top via mods/, not by editing content/). The font is no
// longer cached to disk — the menu builds a live atlas from the install's fonts (baseui_build_atlas).
baseui_ensure :: proc(base: string) -> bool {
	lua_root := baseui_lua_root(base, context.temp_allocator)
	for rel in ui.EMBEDDED_FILES {
		path, _ := filepath.join({lua_root, rel}, context.temp_allocator)
		embedded, ok := ui.embedded(rel)
		if !ok {
			continue
		}
		ensure_parent_dir(path)
		if os.write_entire_file(path, transmute([]u8)embedded) != nil {
			log.errorf("ui: could not write %q", path)
		}
	}
	// Create the bethassets dir up front so mount_game_mods mounts it (as a LOOSE root, read live) —
	// then the extraction below can write into it this same session and the menu sees the files.
	make_dirs(baseui_assets_dir(base, context.temp_allocator))
	return true
}

// baseui_build_atlas builds a LIVE glyph atlas from the UI font read THROUGH THE VFS (so a font
// mod overrides interface/fonts_en.swf like any other asset — uniform resolution, no source-BSA
// scan). The SWF outlines stay resident so glyphs bake lazily at display size. Caller owns the atlas
// (font.destroy). ok=false (→ imgui fallback menu) if the font doesn't resolve / has no usable face.
baseui_build_atlas :: proc(v: ^vfs.VFS) -> (font.Atlas, bool) {
	if v == nil {
		return {}, false
	}
	swf_bytes, ok := vfs.read(v, "interface/fonts_en.swf", context.temp_allocator)
	if !ok {
		log.warn("ui: interface/fonts_en.swf not in the VFS; using fallback menu")
		return {}, false
	}
	fonts := swf.parse_fonts(swf_bytes, context.temp_allocator)
	if len(fonts) == 0 {
		return {}, false
	}
	names := make([]string, len(fonts), context.temp_allocator)
	counts := make([]int, len(fonts), context.temp_allocator)
	for f, i in fonts {
		names[i] = f.name
		counts[i] = len(f.glyphs)
	}
	idx := font.pick_font(names, counts)
	if idx < 0 {
		return {}, false
	}
	log.infof("ui: live atlas from font %q (%d glyphs), ref em %.0fpx", fonts[idx].name, len(fonts[idx].glyphs), UI_REF_EM)
	// make_atlas deep-copies the outlines, so the temp-allocated parse above can be freed after.
	return font.make_atlas(fonts[idx], UI_REF_EM, 1024), true
}

// baseui_extract_assets converts the SWF-EMBEDDED UI assets (sub-shapes/bitmaps that can't be
// read as files) into DDS under content/baseui/bethassets at install time — cached, so each is done
// once. Reads the source SWFs THROUGH THE VFS (so a mod could even override the source). The menu then
// loads the DDS like any other asset, and a mod can override the extracted file. Whole-file assets
// (fonts_en.swf, credits.txt, the logo .nif + .dds) need NO conversion — read straight from vanilla.
//
// NOTE: bethassets is mounted as a LOOSE root, which the VFS reads live from disk — so files written
// here are visible to the already-built `v` this same session (no remount needed).
baseui_extract_assets :: proc(v: ^vfs.VFS, base: string) {
	if v == nil {
		return
	}
	assets := baseui_assets_dir(base, context.temp_allocator)
	// Named assets we actually use, at clean paths: the credits header icon (a DefineBitsLossless2 in
	// creditsmenu.swf exported "SkyrimLogo").
	logo, _ := filepath.join({assets, "interface", "skyrimlogo.dds"}, context.temp_allocator)
	extract_swf_bitmap(v, "interface/creditsmenu.swf", "SkyrimLogo", logo)
	// The Bethesda Game Studios logo (bottom-left of the menu): 621×292 #bbbdbf — LE startmenu
	// shape 78, SSE shape 554 (SSE reuses id 78 for an unrelated 28px icon, hence min_w).
	bethlogo, _ := filepath.join({assets, "interface", "bethesdalogo.dds"}, context.temp_allocator)
	extract_swf_shape(v, "interface/startmenu.swf", {78, 554}, bethlogo, min_w = 200)
	// The "wirey" meter end-cap (hudmenu shape 740 — a left/right mirror pair with 746). The vanilla shape
	// is BLACK-filled (its grey is a 2nd fill we don't extract, and there's no separate white copy), so we
	// re-rasterize it with a WHITE fill → a white cap the bar places on each end (mirrored via flip_x).
	cap, _ := filepath.join({assets, "interface", "meter_cap.dds"}, context.temp_allocator)
	extract_swf_shape_colored(v, "interface/exported/hudmenu.gfx", {740, 499}, cap, {255, 255, 255, 255})
	// The stat-bar deco frame (hudmenu shape 395) re-rasterized WHITE. The vanilla art is red-filled and
	// can't be tinted to white (red × tint = red), so we recolour it at extraction; white also lets a bar
	// tint it per stat later. (Its black bg companion, shape 416, is used as-is.)
	frame, _ := filepath.join({assets, "interface", "bar_frame.dds"}, context.temp_allocator)
	extract_swf_shape_colored(v, "interface/exported/hudmenu.gfx", {395, 446}, frame, {255, 255, 255, 255})
	// The bar's BLACK background frame (LE shape 416 / SSE 467, used as-is) at a STABLE path —
	// Lua references this instead of a dump filename, whose ids differ per edition.
	bar_bg, _ := filepath.join({assets, "interface", "bar_bg.dds"}, context.temp_allocator)
	extract_swf_shape(v, "interface/exported/hudmenu.gfx", {416, 467}, bar_bg, min_w = 100)
	// Browse-and-pick dump: EVERY shape (vector silhouette) + bitmap of the menu SWFs/GFX → DDS under
	// bethassets/<name>/, so any graphic can be found visually + referenced by `image{source=
	// "<name>/shape_<id>.dds"}`. Cached per source (skipped once the dir exists). Covers the classic
	// .swf menus AND the Scaleform interface\exported\*.gfx (CFX) now that swf_body decodes them —
	// so the loading-bar track (loadingmenu shape 5000) and the H/M/S meter end-cap (hudmenu shape 434)
	// land here too. See the "Skyrim UI asset IDs" memory for the catalog of which shape is what.
	dump_swf_assets(v, assets, "interface/startmenu.swf", "startmenu")
	dump_swf_assets(v, assets, "interface/creditsmenu.swf", "creditsmenu")
	dump_swf_assets(v, assets, "interface/loadingmenu.swf", "loadingmenu")
	dump_swf_assets(v, assets, "interface/exported/hudmenu.gfx", "hudmenu")
	// The HUD crosshair reticle: a small white dot we SYNTHESIZE (the vanilla crosshair isn't reliably
	// one extractable flat shape, and a dot is trivial to generate cleanly). hud.lua draws + tints it.
	reticle, _ := filepath.join({assets, "interface", "reticle.dds"}, context.temp_allocator)
	make_reticle(reticle)
}

// make_reticle writes a small white antialiased dot to `dest` (once; skips if it exists). White so
// hud.lua can tint it (image draws texel × colour); Lua also picks the on-screen size.
@(private = "file")
make_reticle :: proc(dest: string) {
	if os.exists(dest) {
		return
	}
	N :: 32          // texture side
	R :: f32(6)      // dot radius in texels
	AA :: f32(1.5)   // edge softness (texels the alpha ramps across)
	rgba := make([]u8, N * N * 4, context.temp_allocator)
	c := f32(N - 1) * 0.5
	for y in 0 ..< N {
		for x in 0 ..< N {
			dx, dy := f32(x) - c, f32(y) - c
			d := math.sqrt(dx * dx + dy * dy)
			a := clamp((R - d) / AA + 0.5, 0, 1) // 1 inside the dot, ramps to 0 across AA texels at the rim
			i := (y * N + x) * 4
			rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3] = 255, 255, 255, u8(a * 255)
		}
	}
	ensure_parent_dir(dest)
	if os.write_entire_file(dest, dds.write_rgba(rgba, N, N, context.temp_allocator)) != nil {
		log.errorf("ui: could not write %q", dest)
	} else {
		log.infof("ui: generated reticle → %s (%dx%d)", filepath.base(dest), N, N)
	}
}

// extract_swf_shape rasterizes one shape from `swf_path` as a solid silhouette and
// writes it as DDS to `dest` — once (skips if it exists). Best-effort.
@(private = "file")
// `ids` are per-edition candidates for the SAME art, tried in ORDER (LE first, then SSE —
// SSE re-exported every UI SWF, so character ids moved). min_w guards against an id REUSED
// for different art across editions (startmenu 78: LE = the 621px Bethesda logo, SSE = a
// 28px icon — the SSE logo moved to 554): a candidate rasterizing narrower than min_w is
// skipped and the next candidate tried.
extract_swf_shape :: proc(v: ^vfs.VFS, swf_path: string, ids: []u16, dest: string, min_w := 0) {
	if os.exists(dest) {
		return
	}
	raw, ok := vfs.read(v, swf_path, context.temp_allocator)
	if !ok {
		return
	}
	shapes := swf.extract_all_shapes(raw, context.temp_allocator)
	for want in ids {
		for sh in shapes {
			if sh.id != want {
				continue
			}
			rgba, w, h := font.rasterize_shape(sh.segs, 1.0 / 20, sh.fill, context.temp_allocator)
			if w < max(min_w, 1) || h <= 0 {
				break // wrong art under a reused id — try the next candidate
			}
			ensure_parent_dir(dest)
			if os.write_entire_file(dest, dds.write_rgba(rgba, u32(w), u32(h), context.temp_allocator)) != nil {
				log.errorf("ui: could not write %q", dest)
			} else {
				log.infof("ui: extracted shape %d → %s (%dx%d)", sh.id, filepath.base(dest), w, h)
			}
			return
		}
	}
	log.warnf("ui: none of shapes %v (min_w %d) matched in %s", ids, min_w, swf_path)
}

// extract_swf_shape_colored rasterizes a shape from `swf_path` to `dest` in an OVERRIDE colour (not
// the shape's own fill) — e.g. re-colouring a black-filled cap to white so the UI can place/tint it.
// `ids` are per-edition candidates for the same art (first present wins), like extract_swf_shape.
// Once (skips if `dest` exists). Best-effort.
@(private = "file")
extract_swf_shape_colored :: proc(v: ^vfs.VFS, swf_path: string, ids: []u16, dest: string, color: [4]u8) {
	if os.exists(dest) {
		return
	}
	raw, ok := vfs.read(v, swf_path, context.temp_allocator)
	if !ok {
		return
	}
	for sh in swf.extract_all_shapes(raw, context.temp_allocator) {
		if !slice.contains(ids, sh.id) {
			continue
		}
		rgba, w, h := font.rasterize_shape(sh.segs, 1.0 / 20, color, context.temp_allocator)
		if w <= 0 || h <= 0 {
			return
		}
		ensure_parent_dir(dest)
		if os.write_entire_file(dest, dds.write_rgba(rgba, u32(w), u32(h), context.temp_allocator)) != nil {
			log.errorf("ui: could not write %q", dest)
		} else {
			log.infof("ui: extracted shape %d (recoloured) → %s (%dx%d)", sh.id, filepath.base(dest), w, h)
		}
		return
	}
	log.warnf("ui: none of shapes %v found in %s", ids, swf_path)
}

// dump_swf_assets converts every flat-solid shape (silhouette in its fill colour) + every
// DefineBitsLossless2 bitmap of `swf_path` into DDS files under bethassets/<name>/ (shape_<id>.dds /
// bitmap_<id>.dds). Cached: skips if the output dir already exists. Best-effort.
@(private = "file")
dump_swf_assets :: proc(v: ^vfs.VFS, assets, swf_path, name: string) {
	dir, _ := filepath.join({assets, name}, context.temp_allocator)
	if os.is_dir(dir) {
		return // already dumped
	}
	raw, ok := vfs.read(v, swf_path, context.temp_allocator)
	if !ok {
		return
	}
	make_dirs(dir)
	nshapes := 0
	for sh in swf.extract_all_shapes(raw, context.temp_allocator) {
		rgba, w, h := font.rasterize_shape(sh.segs, 1.0 / 20, sh.fill, context.temp_allocator)
		if w <= 0 || h <= 0 {
			continue
		}
		dest, _ := filepath.join({dir, fmt.tprintf("shape_%d.dds", sh.id)}, context.temp_allocator)
		if os.write_entire_file(dest, dds.write_rgba(rgba, u32(w), u32(h), context.temp_allocator)) == nil {
			nshapes += 1
		}
	}
	nbmp := 0
	for bm in swf.extract_all_bitmaps(raw, context.temp_allocator) {
		dest, _ := filepath.join({dir, fmt.tprintf("bitmap_%d.dds", bm.id)}, context.temp_allocator)
		dd := dds.write_rgba(bm.bmp.rgba, u32(bm.bmp.w), u32(bm.bmp.h), context.temp_allocator)
		if os.write_entire_file(dest, dd) == nil {
			nbmp += 1
		}
	}
	log.infof("ui: dumped %d shapes + %d bitmaps from %s → bethassets/%s", nshapes, nbmp, swf_path, name)
}

// extract_swf_bitmap pulls the named bitmap out of `swf_path` (via the VFS) and writes it as DDS to
// `dest` — once (skips if `dest` already exists). Best-effort: a miss just leaves the asset absent.
@(private = "file")
extract_swf_bitmap :: proc(v: ^vfs.VFS, swf_path, name, dest: string) {
	if os.exists(dest) {
		return
	}
	raw, ok := vfs.read(v, swf_path, context.temp_allocator)
	if !ok {
		return
	}
	bmp, bok := swf.extract_bitmap(raw, name, context.temp_allocator)
	if !bok {
		log.warnf("ui: could not extract %q from %s", name, swf_path)
		return
	}
	ddata := dds.write_rgba(bmp.rgba, u32(bmp.w), u32(bmp.h), context.temp_allocator)
	ensure_parent_dir(dest)
	if os.write_entire_file(dest, ddata) != nil {
		log.errorf("ui: could not write %q", dest)
	} else {
		log.infof("ui: extracted %s → %s (%dx%d)", name, filepath.base(dest), bmp.w, bmp.h)
	}
}

// ensure_parent_dir creates the directory chain holding `path` (best-effort).
@(private = "file")
ensure_parent_dir :: proc(path: string) {
	make_dirs(filepath.dir(path))
}

// make_dirs creates `dir` and any missing parents (os.make_directory is single-level).
@(private = "file")
make_dirs :: proc(dir: string) {
	if dir == "" || dir == "." || dir == "/" || os.is_dir(dir) {
		return
	}
	parent := filepath.dir(dir)
	if parent != dir {
		make_dirs(parent)
	}
	_ = os.make_directory(dir)
}
