package main

// The built-in UI mod ("baseui") in content/: our Lua menus and the vanilla art for them. It is
// the always-present BASELINE content mod (forced across all profiles, above vanilla + below user
// mods; see mount_game_mods / content_mod_dirs). Falls back to the imgui menu if no font is found.
//
//   content/baseui/lua/...        the Lua screens + framework (rewritten from #load-embedded each boot)
//   content/baseui/bethassets/... art the installer extracts from the SWFs (converters/ui.odin)

import "core:log"
import "core:os"
import "core:path/filepath"
import "../font"
import "../formats/swf"
import "../installer"
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
	p, _ := filepath.join({base, installer.CONTENT_DIR, installer.UI_MOD, "lua"}, allocator)
	return p
}

// baseui_assets_dir returns <base>/content/baseui/bethassets, the installer's UI art.
baseui_assets_dir :: proc(base: string, allocator := context.allocator) -> string {
	p, _ := filepath.join({base, installer.CONTENT_DIR, installer.UI_MOD, installer.BETHASSETS_DIR}, allocator)
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
		os.make_directory_all(filepath.dir(path))
		if os.write_entire_file(path, transmute([]u8)embedded) != nil {
			log.errorf("ui: could not write %q", path)
		}
	}
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

