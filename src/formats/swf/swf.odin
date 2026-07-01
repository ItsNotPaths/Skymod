package swf

// SWF reader — the parsing foundation for the font engine (rasterize Skyrim's Scaleform UI font) and
// later menu-asset inspection. Game-agnostic: LE and SE ship the same Flash/Scaleform SWF format, so
// nothing here forks per game. This first layer extracts DefineFont2/3 glyph OUTLINES (vector
// contours) + metrics; the rasterizer/atlas live on top.
//
// FORMAT: an SWF is FWS (raw) / CWS (zlib) / ZWS (lzma) + an 8-byte header, then a body of tags. A
// font tag holds an offset table → per-glyph SHAPE records (a bit-packed path of move/line/quad-curve
// edges), a code table (glyph→char), and (optional) a layout block (ascent/descent + advances).

import "core:bytes"
import "core:compress/zlib"

Seg_Kind :: enum {
	Move, // start a new contour at (x,y)
	Line, // straight edge to (x,y)
	Quad, // quadratic Bézier via control (cx,cy) to (x,y)
}

// Seg is one glyph-outline segment in font units (absolute). Curves are quadratic (SWF's only kind).
Seg :: struct {
	kind:   Seg_Kind,
	x, y:   f32, // endpoint
	cx, cy: f32, // control point (Quad only)
}

Glyph :: struct {
	code:    rune,
	advance: f32, // font units (HasLayout); 0 otherwise
	segs:    []Seg,
}

Font :: struct {
	id:                          u16,
	name:                        string, // borrowed from the source bytes
	em:                          f32,    // units per EM (1024 for DefineFont2, 20480 for DefineFont3)
	ascent, descent, leading:    f32,
	glyphs:                      []Glyph,
}

// parse_fonts decompresses an SWF file and returns every DefineFont2/3 in it. The returned fonts +
// glyphs are allocated in `allocator`; glyph names borrow the decompressed body (also allocator-owned
// via the returned ownership — caller keeps it alive by not freeing until done). For a dev/parse
// tool the simplest is a temp allocator.
parse_fonts :: proc(file: []u8, allocator := context.allocator) -> []Font {
	body, ok := swf_body(file, allocator)
	if !ok || len(body) < 1 {
		return {}
	}
	// Skip the frame-size RECT + framerate (2) + framecount (2) to reach the tag stream.
	nbits := int(body[0] >> 3)
	pos := (5 + 4 * nbits + 7) / 8 + 4
	out := make([dynamic]Font, allocator)
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
		if pos + length > len(body) {break}
		if code == 48 || code == 75 { // DefineFont2 / DefineFont3
			append(&out, parse_font(body[pos:pos + length], code == 75, allocator))
		}
		pos += length
		if code == 0 {break} // End
	}
	return out[:]
}

// swf_body returns the uncompressed tag-body region (everything after the 8-byte signature header),
// decompressing CWS (zlib). ZWS (lzma) is not yet supported.
swf_body :: proc(file: []u8, allocator := context.allocator) -> ([]u8, bool) {
	if len(file) < 8 {
		return nil, false
	}
	sig := string(file[0:3])
	flen := int(u32le(file, 4))
	switch sig {
	case "FWS":
		return file[8:], true
	case "CWS":
		out: bytes.Buffer
		if err := zlib.inflate(file[8:], &out, false, flen - 8); err != nil {
			bytes.buffer_destroy(&out)
			return nil, false
		}
		data := make([]u8, len(out.buf), allocator)
		copy(data, out.buf[:])
		bytes.buffer_destroy(&out)
		return data, true
	}
	return nil, false
}

// ── font + glyph parsing ──────────────────────────────────────────────────────────────────────

@(private)
parse_font :: proc(b: []u8, font3: bool, allocator: Allocator) -> Font {
	r := Reader{b, 0, 0}
	f: Font
	f.id = r_u16(&r)
	flags := r_u8(&r)
	has_layout := flags & 0x80 != 0
	wide_offsets := flags & 0x08 != 0
	wide_codes := flags & 0x04 != 0
	r_u8(&r) // language code
	namelen := int(r_u8(&r))
	f.name = string(b[r.byte_pos:r.byte_pos + namelen])
	r.byte_pos += namelen
	if len(f.name) > 0 && f.name[len(f.name) - 1] == 0 {
		f.name = f.name[:len(f.name) - 1] // drop the trailing NUL
	}
	nglyphs := int(r_u16(&r))
	f.em = 20480 if font3 else 1024

	// Offset table: nglyphs glyph offsets + one code-table offset, relative to the table start.
	table_start := r.byte_pos
	offsets := make([]int, nglyphs + 1, context.temp_allocator)
	for i in 0 ..= nglyphs {
		offsets[i] = int(r_u32(&r)) if wide_offsets else int(r_u16(&r))
	}

	f.glyphs = make([]Glyph, nglyphs, allocator)
	for i in 0 ..< nglyphs {
		gr := Reader{b, table_start + offsets[i], 0}
		f.glyphs[i].segs = parse_glyph(&gr, allocator)
	}

	// Code table (glyph → char), at table_start + the last offset.
	cr := Reader{b, table_start + offsets[nglyphs], 0}
	for i in 0 ..< nglyphs {
		f.glyphs[i].code = rune(r_u16(&cr)) if wide_codes else rune(r_u8(&cr))
	}

	if has_layout {
		f.ascent = f32(r_s16(&cr))
		f.descent = f32(r_s16(&cr))
		f.leading = f32(r_s16(&cr))
		for i in 0 ..< nglyphs {
			f.glyphs[i].advance = f32(r_s16(&cr))
		}
		// glyph bounds RECTs + kerning follow — not needed for rasterization (we use the outlines).
	}
	return f
}

// parse_glyph walks a SHAPE record (bit-packed) into absolute move/line/quad segments.
@(private)
parse_glyph :: proc(r: ^Reader, allocator: Allocator) -> []Seg {
	nfill := int(r_ubits(r, 4))
	nline := int(r_ubits(r, 4))
	segs := make([dynamic]Seg, allocator)
	px, py: f32
	for {
		if r_ubits(r, 1) == 0 {
			flags := r_ubits(r, 5)
			if flags == 0 {
				break // end record
			}
			if flags & 0x01 != 0 { // StateMoveTo (absolute)
				mbits := int(r_ubits(r, 5))
				px = f32(r_sbits(r, mbits))
				py = f32(r_sbits(r, mbits))
				append(&segs, Seg{kind = .Move, x = px, y = py})
			}
			if flags & 0x02 != 0 {r_ubits(r, nfill)} // fill style 0 — ignored (glyphs are single-fill)
			if flags & 0x04 != 0 {r_ubits(r, nfill)} // fill style 1
			if flags & 0x08 != 0 {r_ubits(r, nline)} // line style
			// StateNewStyles (0x10) never occurs inside a glyph shape.
		} else {
			straight := r_ubits(r, 1) != 0 // StraightFlag comes BEFORE NumBits
			numbits := int(r_ubits(r, 4)) + 2
			if straight {
				dx, dy: f32
				if r_ubits(r, 1) != 0 { // general line
					dx = f32(r_sbits(r, numbits))
					dy = f32(r_sbits(r, numbits))
				} else if r_ubits(r, 1) != 0 { // vertical
					dy = f32(r_sbits(r, numbits))
				} else { // horizontal
					dx = f32(r_sbits(r, numbits))
				}
				px += dx
				py += dy
				append(&segs, Seg{kind = .Line, x = px, y = py})
			} else { // curved (quadratic) edge
				cx := px + f32(r_sbits(r, numbits))
				cy := py + f32(r_sbits(r, numbits))
				px = cx + f32(r_sbits(r, numbits))
				py = cy + f32(r_sbits(r, numbits))
				append(&segs, Seg{kind = .Quad, x = px, y = py, cx = cx, cy = cy})
			}
		}
	}
	return segs[:]
}
