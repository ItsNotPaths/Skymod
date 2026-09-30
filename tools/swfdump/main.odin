package main

// swfdump — a dev/research tool (not shipped): inspect Skyrim's Scaleform UI SWFs to blueprint our
// own Lua-native menus. Prints STRUCTURE only (header + a tag histogram), never copyrighted content.
//
//   odin run tools/swfdump -- "<Skyrim - Interface.bsa>"          # list every SWF + its tag histogram
//   odin run tools/swfdump -- "<Skyrim - Interface.bsa>" --name startmenu   # one SWF, full detail
//
// No SDL — pure formats code, runs headless.

import "core:bytes"
import "core:compress/zlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../../src/font"
import "../../src/formats/bsa"
import "../../src/formats/dds"
import "../../src/formats/swf"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: swfdump <archive.bsa> [--name <substr>]")
		os.exit(2)
	}
	path := os.args[1]
	filter := ""
	if idx, found := slice.linear_search(os.args, "--name"); found && idx + 1 < len(os.args) {
		filter = os.args[idx + 1]
	}

	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA: %s", path)
		os.exit(1)
	}
	defer bsa.close(&arc)

	// --ls: just list every archive entry whose path contains the --name substring (ANY extension),
	// to locate assets (logos, credits text, …) before deciding how to extract them. No SWF parsing.
	if slice.contains(os.args, "--ls") {
		flt := strings.to_lower(filter, context.temp_allocator)
		count := 0
		for e in arc.entries {
			lower := strings.to_lower(e.path, context.temp_allocator)
			if filter != "" && !strings.contains(lower, flt) {continue}
			fmt.println("   ", e.path)
			count += 1
		}
		fmt.printfln("%d entr%s.", count, "y" if count == 1 else "ies")
		return
	}

	// --extract <destdir>: dump every entry matching --name to <destdir>/<basename> (raw bytes, e.g.
	// pulling loose DDS out of the BSA to inspect them). Locates the file end-to-end for asset research.
	if idx, found := slice.linear_search(os.args, "--extract"); found && idx + 1 < len(os.args) {
		destdir := os.args[idx + 1]
		flt := strings.to_lower(filter, context.temp_allocator)
		n := 0
		for e in arc.entries {
			lower := strings.to_lower(e.path, context.temp_allocator)
			if filter != "" && !strings.contains(lower, flt) {continue}
			data, ok := bsa.extract(&arc, e, context.temp_allocator)
			if !ok {continue}
			// basename: last path component (BSA paths use backslashes).
			base := e.path
			for i := len(e.path) - 1; i >= 0; i -= 1 {
				if e.path[i] == '\\' || e.path[i] == '/' {base = e.path[i + 1:];break}
			}
			out, _ := filepath.join({destdir, base}, context.temp_allocator)
			if os.write_entire_file(out, data) == nil {
				fmt.printfln("  %s -> %s (%d bytes)", e.path, out, len(data))
				n += 1
			}
		}
		fmt.printfln("extracted %d entr%s.", n, "y" if n == 1 else "ies")
		return
	}

	// Movie modes, on the first SWF/GFX matching --name:
	//   --shapes <destdir>           every shape as <destdir>/shape_<id>.dds, with its size + first solid fill
	//   --layout                     every named instance's stage rect (px), and its animated box per label
	//   --render <path> <label> <out.dds>   one instance as it sits on the stage, 2 px per stage px
	shapes_i, want_shapes := slice.linear_search(os.args, "--shapes")
	render_i, want_render := slice.linear_search(os.args, "--render")
	if want_shapes || want_render || slice.contains(os.args, "--layout") {
		mv, ok := first_movie(&arc, filter)
		if !ok {
			fmt.eprintln("no SWF/GFX matches --name")
			os.exit(1)
		}
		switch {
		case want_shapes && shapes_i + 1 < len(os.args):
			dump_shapes(&mv, os.args[shapes_i + 1])
		case want_render && render_i + 3 < len(os.args):
			img, rok := swf.render_instance(&mv, os.args[render_i + 1], os.args[render_i + 2], 2, allocator = context.temp_allocator)
			if !rok {
				fmt.eprintln("no such instance")
				os.exit(1)
			}
			_ = os.write_entire_file(os.args[render_i + 3], dds.write_rgba(img.rgba, u32(img.w), u32(img.h), context.temp_allocator))
			fmt.printfln("%dx%d, stage rect %v", img.w, img.h, img.rect)
		case:
			for e in swf.layout(&mv, context.temp_allocator) {
				r := e.rect
				fmt.printfln("%s  (%.1f,%.1f) %.1fx%.1f", e.path, r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0)
				for m in e.moving {
					fmt.printfln("    moving %s: (%.1f,%.1f) %.1fx%.1f", m.label, m.rect.x0, m.rect.y0, m.rect.x1 - m.rect.x0, m.rect.y1 - m.rect.y0)
				}
				for m in e.at {
					fmt.printfln("    at %s: (%.1f,%.1f) %.1fx%.1f", m.label, m.rect.x0, m.rect.y0, m.rect.x1 - m.rect.x0, m.rect.y1 - m.rect.y0)
				}
			}
		}
		return
	}

	// --cat: print the first matching entry's bytes as text (for credits.txt-style assets).
	if slice.contains(os.args, "--cat") {
		flt := strings.to_lower(filter, context.temp_allocator)
		for e in arc.entries {
			lower := strings.to_lower(e.path, context.temp_allocator)
			if filter != "" && !strings.contains(lower, flt) {continue}
			if data, ok := bsa.extract(&arc, e, context.temp_allocator); ok {
				fmt.printfln("=== %s (%d bytes) ===", e.path, len(data))
				fmt.println(string(data[:min(len(data), 1600)]))
			}
			return
		}
		return
	}

	n := 0
	for e in arc.entries {
		lower := strings.to_lower(e.path, context.temp_allocator)
		// Skyrim ships menus as .swf (interface\ root) AND Scaleform .gfx (interface\exported\ —
		// the runtime binaries, external-bitmap DDS alongside). Same tag structure; parse both.
		if !strings.has_suffix(lower, ".swf") && !strings.has_suffix(lower, ".gfx") {continue}
		if filter != "" && !strings.contains(lower, strings.to_lower(filter, context.temp_allocator)) {continue}
		data, dok := bsa.extract(&arc, e, context.temp_allocator)
		if !dok {
			fmt.printfln("  %s  (extract failed)", e.path)
			continue
		}
		if slice.contains(os.args, "--fonts") {
			dump_fonts(e.path, data)
		} else {
			parse_swf(e.path, data, filter != "")
		}
		n += 1
	}
	fmt.printfln("\n%d SWF(s).", n)
}

// dump_fonts parses every DefineFont2/3 in an SWF and prints metadata + a few sample glyphs'
// outline stats — the verify for the glyph-outline parser (foundation for the rasterizer).
dump_fonts :: proc(name: string, raw: []u8) {
	fonts := swf.parse_fonts(raw, context.temp_allocator)
	if len(fonts) == 0 {return}
	fmt.printfln("\n%s — %d font(s)", name, len(fonts))
	for f in fonts {
		fmt.printfln(
			"  font id=%d %q  em=%.0f  ascent=%.0f descent=%.0f  %d glyphs",
			f.id, f.name, f.em, f.ascent, f.descent, len(f.glyphs),
		)
		samples := [?]rune{'A', 'g', '0', 'W'}
		for want in samples {
			for g in f.glyphs {
				if g.code != want {continue}
				minx, miny, maxx, maxy := glyph_bounds(g)
				fmt.printfln(
					"    %q  advance=%.0f  %d segs  bounds=(%.0f,%.0f .. %.0f,%.0f)",
					want, g.advance, len(g.segs), minx, miny, maxx, maxy,
				)
				break
			}
		}
	}
}

glyph_bounds :: proc(g: swf.Glyph) -> (minx, miny, maxx, maxy: f32) {
	minx, miny = 1e9, 1e9
	maxx, maxy = -1e9, -1e9
	for s in g.segs {
		for x in ([]f32{s.x, s.cx}) {
			minx = min(minx, x);maxx = max(maxx, x)
		}
		for y in ([]f32{s.y, s.cy}) {
			miny = min(miny, y);maxy = max(maxy, y)
		}
	}
	return
}

parse_swf :: proc(name: string, raw: []u8, detail := false) {
	if len(raw) < 8 {
		fmt.printfln("%s  (too short)", name)
		return
	}
	sig := string(raw[0:3])
	ver := raw[3]
	flen := u32le(raw, 4)

	out: bytes.Buffer
	defer bytes.buffer_destroy(&out)
	body: []u8
	switch sig {
	case "FWS", "GFX": // uncompressed SWF / uncompressed Scaleform GFX
		body = raw[8:]
	case "CWS", "CFX": // zlib SWF / zlib Scaleform GFX (Skyrim's exported\*.gfx are CFX)
		if err := zlib.inflate(raw[8:], &out, false, int(flen) - 8); err != nil {
			fmt.printfln("%s  (zlib decompress failed)", name)
			return
		}
		body = out.buf[:]
	case "ZWS":
		fmt.printfln("%s  v%d  LZMA-compressed (parser TBD)", name, ver)
		return
	case:
		fmt.printfln("%s  (not an SWF: %q)", name, sig)
		return
	}

	// Frame size RECT (nbits in the top 5 bits of byte 0) → the stage size, then framerate/count.
	if len(body) < 1 {return}
	stage, _ := read_rect(body, 0) // {xmin,xmax,ymin,ymax} px
	nbits := int(body[0] >> 3)
	pos := (5 + 4 * nbits + 7) / 8
	if pos + 4 > len(body) {return}
	framerate := f32(u16le(body, pos)) / 256.0
	pos += 2
	framecount := int(u16le(body, pos))
	pos += 2

	// Walk top-level tags.
	counts: map[int]int
	defer delete(counts)
	total := 0
	for pos + 2 <= len(body) {
		tc := int(u16le(body, pos))
		pos += 2
		code := tc >> 6
		length := tc & 0x3f
		if length == 0x3f {
			if pos + 4 > len(body) {break}
			length = int(u32le(body, pos))
			pos += 4
		}
		counts[code] += 1
		total += 1
		if detail && pos + length <= len(body) {
			tb := body[pos:pos + length]
			switch code {
			case 56:
				parse_exports(tb)
			case 37:
				parse_edittext(tb)
			case 2, 22, 32, 83:
				parse_shape(tb, code)
			}
		}
		pos += length
		if code == 0 {break} // End
	}

	fmt.printfln(
		"\n%s\n  %s v%d  %.0ffps  %d frames  %d top-level tags  stage %.0fx%.0f",
		name, sig, ver, framerate, framecount, total, stage[1] - stage[0], stage[3] - stage[2],
	)
	// Histogram, most-frequent first.
	codes := make([dynamic]int, 0, len(counts), context.temp_allocator)
	for c in counts {append(&codes, c)}
	slice.sort_by(codes[:], proc(a, b: int) -> bool {return a < b})
	for c in codes {
		fmt.printfln("    %4d x  %-22s (tag %d)", counts[c], tag_name(c), c)
	}
}

@(private = "file")
u16le :: proc(b: []u8, o: int) -> u16 {
	return u16(b[o]) | u16(b[o + 1]) << 8
}

@(private = "file")
u32le :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}

// tag_name maps the common SWF tag codes (for a readable histogram).
@(private = "file")
tag_name :: proc(code: int) -> string {
	switch code {
	case 0:
		return "End"
	case 1:
		return "ShowFrame"
	case 2:
		return "DefineShape"
	case 4:
		return "PlaceObject"
	case 9:
		return "SetBackgroundColor"
	case 10:
		return "DefineFont"
	case 11:
		return "DefineText"
	case 12:
		return "DoAction(AS2)"
	case 20:
		return "DefineBitsLossless"
	case 22:
		return "DefineShape2"
	case 26:
		return "PlaceObject2"
	case 32:
		return "DefineShape3"
	case 33:
		return "DefineText2"
	case 36:
		return "DefineBitsLossless2"
	case 37:
		return "DefineEditText"
	case 39:
		return "DefineSprite"
	case 43:
		return "FrameLabel"
	case 46:
		return "DefineMorphShape"
	case 48:
		return "DefineFont2"
	case 59:
		return "DoInitAction"
	case 70:
		return "PlaceObject3"
	case 73:
		return "DefineFontAlignZones"
	case 74:
		return "CSMTextSettings"
	case 75:
		return "DefineFont3"
	case 76:
		return "SymbolClass"
	case 82:
		return "DoABC(AS3)"
	case 83:
		return "DefineShape4"
	case 84:
		return "DefineMorphShape2"
	case 88:
		return "DefineFontName"
	// Scaleform GFX-specific tags (in exported\*.gfx). The external-image tags name the companion
	// _iXXX.dds bitmaps beside the .gfx — our extractable UI art.
	case 1000:
		return "GFX_ExporterInfo"
	case 1001:
		return "GFX_DefineExternalImage"
	case 1002:
		return "GFX_FontTextureInfo"
	case 1003:
		return "GFX_DefineExternalGradientImage"
	case 1004:
		return "GFX_DefineSubImage"
	case 1005:
		return "GFX_DefineExternalImage2"
	case 1006:
		return "GFX_DefineExternalSound"
	case 1007:
		return "GFX_DefineExternalStreamSound"
	}
	if code >= 1000 {return "GFX_?"}
	return "?"
}

// ── detail parsers: the layout blueprint (named symbols + dynamic text fields) ─────────────────

// parse_exports prints an ExportAssets (tag 56) table: the symbols the game references by name.
@(private = "file")
parse_exports :: proc(b: []u8) {
	if len(b) < 2 {return}
	count := int(u16le(b, 0))
	o := 2
	for _ in 0 ..< count {
		if o + 2 > len(b) {break}
		id := u16le(b, o)
		o += 2
		name, no := read_str(b, o)
		o = no
		fmt.printfln("    export  id=%-4d  %q", id, name)
	}
}

// parse_edittext prints a DefineEditText (tag 37): the dynamic text field's box, its bound variable
// name, and its default text — i.e. a menu label/news field and where it sits.
@(private = "file")
parse_edittext :: proc(b: []u8) {
	if len(b) < 4 {return}
	id := u16le(b, 0)
	o := 2
	bounds, o2 := read_rect(b, o)
	o = o2
	if o + 2 > len(b) {return}
	f1 := b[o]
	f2 := b[o + 1]
	o += 2
	has_text := f1 & 0x80 != 0
	has_color := f1 & 0x04 != 0
	has_maxlen := f1 & 0x02 != 0
	has_font := f1 & 0x01 != 0
	has_fontclass := f2 & 0x80 != 0
	has_layout := f2 & 0x20 != 0
	if has_font {o += 4} // FontID u16 + FontHeight u16
	if has_fontclass {_, no := read_str(b, o);o = no}
	if has_color {o += 4}
	if has_maxlen {o += 2}
	if has_layout {o += 9} // align u8 + left/right/indent/leading
	varname, o3 := read_str(b, o)
	o = o3
	text := ""
	if has_text && o < len(b) {text, _ = read_str(b, o)}
	w := bounds[1] - bounds[0]
	h := bounds[3] - bounds[2]
	fmt.printfln("    edittext id=%-4d %.0fx%.0f  var=%q  text=%q", id, w, h, varname, text)
}

// parse_shape prints a DefineShape/2/3/4's id, pixel bounds, and its SOLID fill colors — enough to
// blueprint a flat UI graphic (panel/stripe/line) without lifting the art. Shape3/4 fills carry alpha
// (RGBA); Shape/2 are RGB. Stops at the first gradient/bitmap fill (those are variable-size and we
// only care about the solid panel fills here). The bit-packed edge records after the styles are
// skipped — bounds + fills are the layout blueprint.
@(private = "file")
parse_shape :: proc(b: []u8, code: int) {
	if len(b) < 3 {return}
	id := u16le(b, 0)
	o := 2
	bounds, o2 := read_rect(b, o) // ShapeBounds
	o = o2
	if code == 83 { // DefineShape4: + EdgeBounds RECT + a flags byte before the styles
		_, o3 := read_rect(b, o)
		o = o3 + 1
	}
	rgba := code == 32 || code == 83 // Shape3/Shape4 fills are RGBA; Shape/Shape2 are RGB
	w := bounds[1] - bounds[0]
	h := bounds[3] - bounds[2]

	if o >= len(b) {return}
	count := int(b[o]);o += 1
	if count == 0xFF {
		if o + 2 > len(b) {return}
		count = int(u16le(b, o));o += 2
	}
	sb := strings.builder_make(context.temp_allocator)
	complex := false
	for _ in 0 ..< count {
		if o >= len(b) {break}
		t := b[o];o += 1
		if t != 0x00 { // 0x10/0x12/0x13 gradient, 0x40+ bitmap — variable size, stop
			complex = true
			break
		}
		if rgba {
			if o + 4 > len(b) {break}
			fmt.sbprintf(&sb, " #%02x%02x%02x a=%d", b[o], b[o + 1], b[o + 2], b[o + 3])
			o += 4
		} else {
			if o + 3 > len(b) {break}
			fmt.sbprintf(&sb, " #%02x%02x%02x", b[o], b[o + 1], b[o + 2])
			o += 3
		}
	}
	fmt.printfln(
		"    shape%d id=%-4d %.0fx%.0f  fills:%s%s",
		code,
		id,
		w,
		h,
		strings.to_string(sb),
		" …(+gradient/bitmap)" if complex else "",
	)
}

// read_str reads a NUL-terminated string at offset o; returns it + the offset past the NUL.
@(private = "file")
read_str :: proc(b: []u8, o: int) -> (string, int) {
	end := o
	for end < len(b) && b[end] != 0 {end += 1}
	return string(b[o:end]), end + 1
}

// read_rect reads a bit-packed RECT (twips) at offset o; returns px bounds {xmin,xmax,ymin,ymax}
// + the byte offset past it.
@(private = "file")
read_rect :: proc(b: []u8, o: int) -> ([4]f32, int) {
	br := Bit_Reader{b, o, 0}
	nbits := int(read_bits(&br, 5))
	out: [4]f32
	for i in 0 ..< 4 {
		out[i] = f32(read_sbits(&br, nbits)) / 20.0 // twips → px
	}
	next := br.byte_pos + (1 if br.bit_pos > 0 else 0)
	return out, next
}

@(private = "file")
Bit_Reader :: struct {
	b:        []u8,
	byte_pos: int,
	bit_pos:  int,
}

@(private = "file")
read_bits :: proc(br: ^Bit_Reader, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n {
		v <<= 1
		if br.byte_pos < len(br.b) {
			v |= u32((br.b[br.byte_pos] >> uint(7 - br.bit_pos)) & 1)
		}
		br.bit_pos += 1
		if br.bit_pos == 8 {
			br.bit_pos = 0
			br.byte_pos += 1
		}
	}
	return v
}

@(private = "file")
read_sbits :: proc(br: ^Bit_Reader, n: int) -> i32 {
	v := read_bits(br, n)
	if n > 0 && (v & (1 << uint(n - 1))) != 0 {
		v |= ~u32(0) << uint(n) // sign-extend
	}
	return i32(v)
}


// first_movie parses the first SWF/GFX whose path contains `filter`.
first_movie :: proc(arc: ^bsa.Archive, filter: string) -> (swf.Movie, bool) {
	flt := strings.to_lower(filter, context.temp_allocator)
	for e in arc.entries {
		lower := strings.to_lower(e.path, context.temp_allocator)
		if !strings.has_suffix(lower, ".swf") && !strings.has_suffix(lower, ".gfx") {continue}
		if filter != "" && !strings.contains(lower, flt) {continue}
		raw := bsa.extract(arc, e, context.temp_allocator) or_continue
		return swf.parse_movie(raw, context.temp_allocator)
	}
	return {}, false
}

// dump_shapes writes every shape as DDS. The catalog line (id, size, first solid fill) is the key
// baseui finds vanilla art by, since ids change between game builds.
dump_shapes :: proc(mv: ^swf.Movie, destdir: string) {
	n := 0
	for id, c in mv.chars {
		sh := c.(swf.Shape_Def) or_continue
		img := swf.render_shape_image(mv, id, 1, context.temp_allocator) or_continue
		col := swf.shape_color(sh)
		fmt.printfln("  shape %d  %dx%d  fill #%02x%02x%02x%02x", id, img.w, img.h, col[0], col[1], col[2], col[3])
		out, _ := filepath.join({destdir, fmt.tprintf("shape_%d.dds", id)}, context.temp_allocator)
		if os.write_entire_file(out, dds.write_rgba(img.rgba, u32(img.w), u32(img.h), context.temp_allocator)) == nil {n += 1}
	}
	fmt.printfln("rendered %d shapes -> %s", n, destdir)
}
