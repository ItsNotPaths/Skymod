package main

// promptbake — packs the vendored Kenney "Input Prompts" art (CC0) into the single
// prompts.pak the engine #load's: every device set's 64px "Default" PNG on one fixed-pitch
// RGBA atlas (QOI-compressed) + a name → cell directory. Run by build/bake_prompts.sh
// before `odin build` (like the GLSL → SPIR-V shader bake).
//
//   odin run tools/promptbake -- <vendor/kenney-input-prompts> <out.pak>
//   odin run tools/promptbake -- --stub <out.pak>     # empty pak (no vendored art; the
//                                                     # engine falls back to text hints)
//
// Glyphs are keyed "<set-slug>/<kenney basename>" ("xbox/xbox_button_color_a",
// "kbm/keyboard_f", …) — basenames repeat across sets (Switch vs Switch 2), the slug
// disambiguates. No SDL — pure formats code, runs headless.

import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:image/qoi"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../../src/formats/promptpak"

// Directory name → pack slug for the sets Kenney ships in 1.5. An unlisted set (a future
// pack revision) still bakes under an auto-slug (lowercased alphanumerics) with a warning.
SET_SLUGS := [][2]string {
	{"Flairs", "flairs"},
	{"Generic", "generic"},
	{"Keyboard & Mouse", "kbm"},
	{"Meta Quest", "quest"},
	{"Nintendo Gamecube", "gamecube"},
	{"Nintendo Switch", "switch"},
	{"Nintendo Switch 2", "switch2"},
	{"Nintendo Wii", "wii"},
	{"Nintendo WiiU", "wiiu"},
	{"Playdate", "playdate"},
	{"PlayStation Series", "ps"},
	{"Steam Controller", "steamcontroller"},
	{"Steam Deck", "steamdeck"},
	{"Steam Frame", "steamframe"},
	{"Touch", "touch"},
	{"Valve Index", "index"},
	{"Xbox Series", "xbox"},
}

CELL :: 64      // every 1.5 glyph is 64×64; a differently-sized one is skipped with a warning
MARGIN :: 1     // transparent px ringing each cell (linear sampling can't bleed a neighbour)
PITCH :: CELL + 2 * MARGIN
ATLAS_W :: 2048
COLS :: ATLAS_W / PITCH

main :: proc() {
	args := os.args[1:]
	switch {
	case len(args) == 2 && args[0] == "--stub":
		write_stub(args[1])
	case len(args) == 2:
		bake(args[0], args[1])
	case:
		fmt.eprintln("usage: promptbake <vendor-dir> <out.pak> | promptbake --stub <out.pak>")
		os.exit(2)
	}
}

// write_stub emits a valid, empty pak (1×1 transparent atlas, no entries) so the engine
// compiles + runs without the vendored art — every prompt lookup misses and the UI's text
// fallback shows instead.
write_stub :: proc(out_path: string) {
	pixel := [4]u8{0, 0, 0, 0}
	blob := encode_pak(1, 1, pixel[:], {})
	write_out(out_path, blob)
	fmt.printfln("  stub pak (no glyphs) -> %s", out_path)
}

Glyph :: struct {
	key:  string, // "<slug>/<basename>"
	path: string,
}

bake :: proc(vendor_dir, out_path: string) {
	glyphs := scan(vendor_dir)
	if len(glyphs) == 0 {
		fmt.eprintfln("error: no <set>/Default/*.png under %s", vendor_dir)
		os.exit(1)
	}
	slice.sort_by(glyphs, proc(a, b: Glyph) -> bool {return a.key < b.key})

	rows := (len(glyphs) + COLS - 1) / COLS
	atlas_h := rows * PITCH
	atlas := make([]u8, ATLAS_W * atlas_h * 4)

	entries := make([dynamic]promptpak.Entry, 0, len(glyphs))
	skipped := 0
	for g in glyphs {
		img, err := png.load_from_file(g.path, {.alpha_add_if_missing})
		if err != nil || img.width != CELL || img.height != CELL || img.channels != 4 || img.depth != 8 {
			fmt.eprintfln("  warn: skipping %s (%v, %dx%d ch%d d%d)", g.path, err,
				img == nil ? 0 : img.width, img == nil ? 0 : img.height,
				img == nil ? 0 : img.channels, img == nil ? 0 : img.depth)
			skipped += 1
			if img != nil {png.destroy(img)}
			continue
		}
		i := len(entries)
		cx := MARGIN + (i % COLS) * PITCH
		cy := MARGIN + (i / COLS) * PITCH
		src := bytes.buffer_to_bytes(&img.pixels)
		for row in 0 ..< CELL {
			dst := ((cy + row) * ATLAS_W + cx) * 4
			copy(atlas[dst:dst + CELL * 4], src[row * CELL * 4:])
		}
		append(&entries, promptpak.Entry{name = g.key, x = u16(cx), y = u16(cy), w = CELL, h = CELL})
		png.destroy(img)
	}

	blob := encode_pak(ATLAS_W, atlas_h, atlas, entries[:])
	write_out(out_path, blob)
	fmt.printfln("  %d glyphs (%d skipped) -> %s (%dx%d atlas, %d KiB)",
		len(entries), skipped, out_path, ATLAS_W, atlas_h, len(blob) / 1024)
}

// scan collects every <set>/Default/*.png under the vendor dir as (key, path).
scan :: proc(vendor_dir: string) -> []Glyph {
	out := make([dynamic]Glyph)
	sets, rerr := os.read_all_directory_by_path(vendor_dir, context.allocator)
	if rerr != nil {
		fmt.eprintfln("error: cannot read %s: %v", vendor_dir, rerr)
		os.exit(1)
	}
	for set in sets {
		if set.type != .Directory {continue}
		def_dir, _ := filepath.join({vendor_dir, set.name, "Default"})
		files, derr := os.read_all_directory_by_path(def_dir, context.allocator)
		if derr != nil {continue}
		slug := set_slug(set.name)
		for f in files {
			if f.type == .Directory || !strings.has_suffix(f.name, ".png") {continue}
			stem := f.name[:len(f.name) - len(".png")]
			path, _ := filepath.join({def_dir, f.name})
			append(&out, Glyph{key = fmt.aprintf("%s/%s", slug, stem), path = path})
		}
	}
	return out[:]
}

set_slug :: proc(dir_name: string) -> string {
	for s in SET_SLUGS {
		if s[0] == dir_name {return s[1]}
	}
	// Future set: derive a slug so it still bakes (and flag it for the table above).
	b := strings.builder_make()
	for r in dir_name {
		switch r {
		case 'a' ..= 'z', '0' ..= '9': strings.write_rune(&b, r)
		case 'A' ..= 'Z': strings.write_rune(&b, r + 32)
		}
	}
	slug := strings.to_string(b)
	fmt.eprintfln("  warn: unknown set %q -> slug %q (add it to SET_SLUGS)", dir_name, slug)
	return slug
}

// encode_pak QOI-compresses the RGBA atlas and wraps it in the pak container.
encode_pak :: proc(w, h: int, rgba: []u8, entries: []promptpak.Entry) -> []u8 {
	img: image.Image
	img.width = w
	img.height = h
	img.channels = 4
	img.depth = 8
	bytes.buffer_init(&img.pixels, rgba)
	out: bytes.Buffer
	if err := qoi.save_to_buffer(&out, &img); err != nil {
		fmt.eprintfln("error: qoi encode failed: %v", err)
		os.exit(1)
	}
	return promptpak.write(w, h, entries, bytes.buffer_to_bytes(&out))
}

write_out :: proc(path: string, blob: []u8) {
	if err := os.write_entire_file(path, blob); err != nil {
		fmt.eprintfln("error: cannot write %s: %v", path, err)
		os.exit(1)
	}
}
