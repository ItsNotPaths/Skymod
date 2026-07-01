package swf

// DefineShape geometry extraction — pulls each shape's filled OUTLINE (absolute Move/Line/Quad
// contours, in TWIPS = 1/20 px) + its first SOLID fill colour, for the install-time UI-asset dump
// (vector menu graphics → silhouette → DDS). The SHAPE record stream is the same bit-packed format as
// a font glyph (reuses that parser's shape), preceded by fill/line style arrays.
//
// SCOPE: flat solid shapes only — we SKIP (ok=false) any shape using a gradient/bitmap fill, a Shape4
// LINESTYLE2, or a mid-shape new-style record (re-aligning those is more than the menu logos need).
// Multi-fill shapes collapse to a single-colour silhouette (the first solid fill) — fine to identify
// + use a monochrome logo; a multi-colour graphic would need the full Flash fill rasteriser.

Shape :: struct {
	id:   u16,
	fill: [4]u8, // RGBA of the first solid fill (white if the shape declared none)
	segs: []Seg, // contours in twips; rasterise at scale 1/20 for native px
}

// extract_all_shapes returns every flat-solid DefineShape/2/3/4 in the SWF (complex ones skipped).
extract_all_shapes :: proc(file: []u8, allocator := context.allocator) -> []Shape {
	body, ok := swf_body(file, context.temp_allocator)
	if !ok || len(body) < 1 {
		return {}
	}
	nbits := int(body[0] >> 3)
	pos := (5 + 4 * nbits + 7) / 8 + 4
	out := make([dynamic]Shape, allocator)
	for pos + 2 <= len(body) {
		tc := int(u16le(body, pos));pos += 2
		code := tc >> 6
		length := tc & 0x3f
		if length == 0x3f {
			if pos + 4 > len(body) {break}
			length = int(u32le(body, pos));pos += 4
		}
		if pos + length > len(body) {break}
		switch code {
		case 2, 22, 32, 83:
			if sh, sok := parse_shape_def(body[pos:pos + length], code, allocator); sok {
				append(&out, sh)
			}
		}
		pos += length
		if code == 0 {break}
	}
	return out[:]
}

@(private)
parse_shape_def :: proc(b: []u8, code: int, allocator: Allocator) -> (Shape, bool) {
	r := Reader{b, 0, 0}
	sh: Shape
	sh.id = r_u16(&r)
	skip_rect(&r) // ShapeBounds (bit-packed)
	r_align(&r)
	if code == 83 { // DefineShape4: EdgeBounds RECT + a flags byte before the styles
		skip_rect(&r)
		r_align(&r)
		r_u8(&r)
	}
	shape34 := code == 32 || code == 83
	fill, fok := read_fill_array(&r, shape34)
	if !fok {
		return {}, false
	}
	sh.fill = fill
	if !skip_line_array(&r, code, shape34) {
		return {}, false
	}
	segs, sok := read_shape_records_shape(&r, allocator)
	if !sok || len(segs) == 0 {
		return {}, false
	}
	sh.segs = segs
	return sh, true
}

// r_align advances to the next byte boundary (byte reads after bit-packed fields need this).
@(private)
r_align :: proc(r: ^Reader) {
	if r.bit_pos != 0 {
		r.bit_pos = 0
		r.byte_pos += 1
	}
}

// skip_rect consumes a bit-packed RECT (nbits + 4 signed coords). Leaves the bit cursor mid-byte.
@(private)
skip_rect :: proc(r: ^Reader) {
	nbits := int(r_ubits(r, 5))
	for _ in 0 ..< 4 {
		r_sbits(r, nbits)
	}
}

// read_fill_array reads the FillStyleArray, returning the first SOLID fill's RGBA. Bails (ok=false)
// on any gradient/bitmap fill (variable-size — can't skip without full parsing, and we don't need it).
@(private)
read_fill_array :: proc(r: ^Reader, shape34: bool) -> ([4]u8, bool) {
	count := int(r_u8(r))
	if count == 0xFF {
		count = int(r_u16(r))
	}
	first := [4]u8{255, 255, 255, 255}
	have := false
	for _ in 0 ..< count {
		if r_u8(r) != 0x00 { // not a solid fill
			return {}, false
		}
		col: [4]u8
		col[0] = r_u8(r);col[1] = r_u8(r);col[2] = r_u8(r)
		col[3] = r_u8(r) if shape34 else 255
		if !have {
			first = col
			have = true
		}
	}
	return first, true
}

// skip_line_array consumes the LineStyleArray. Bails on Shape4 (LINESTYLE2 is structurally complex).
@(private)
skip_line_array :: proc(r: ^Reader, code: int, shape34: bool) -> bool {
	count := int(r_u8(r))
	if count == 0xFF {
		count = int(r_u16(r))
	}
	for _ in 0 ..< count {
		if code == 83 {
			return false // LINESTYLE2 — variable; bail
		}
		r_u16(r) // width
		r_u8(r);r_u8(r);r_u8(r) // RGB
		if shape34 {
			r_u8(r) // A (Shape3)
		}
	}
	return true
}

// read_shape_records_shape walks the bit-packed SHAPE records into absolute contours (like the glyph
// parser, but here a StateNewStyles record bails — re-reading style arrays mid-shape is out of scope).
@(private)
read_shape_records_shape :: proc(r: ^Reader, allocator: Allocator) -> ([]Seg, bool) {
	nfill := int(r_ubits(r, 4))
	nline := int(r_ubits(r, 4))
	segs := make([dynamic]Seg, allocator)
	px, py: f32
	for guard := 0; guard < 200000; guard += 1 {
		if r.byte_pos >= len(r.b) {
			break
		}
		if r_ubits(r, 1) == 0 { // non-edge record
			flags := r_ubits(r, 5)
			if flags == 0 {
				break // end of shape
			}
			if flags & 0x10 != 0 {
				return {}, false // StateNewStyles → would misalign; skip this shape
			}
			if flags & 0x01 != 0 { // StateMoveTo (absolute)
				mbits := int(r_ubits(r, 5))
				px = f32(r_sbits(r, mbits))
				py = f32(r_sbits(r, mbits))
				append(&segs, Seg{kind = .Move, x = px, y = py})
			}
			if flags & 0x02 != 0 {r_ubits(r, nfill)} // fill style 0
			if flags & 0x04 != 0 {r_ubits(r, nfill)} // fill style 1
			if flags & 0x08 != 0 {r_ubits(r, nline)} // line style
		} else { // edge record
			straight := r_ubits(r, 1) != 0
			numbits := int(r_ubits(r, 4)) + 2
			if straight {
				dx, dy: f32
				if r_ubits(r, 1) != 0 {
					dx = f32(r_sbits(r, numbits))
					dy = f32(r_sbits(r, numbits))
				} else if r_ubits(r, 1) != 0 {
					dy = f32(r_sbits(r, numbits))
				} else {
					dx = f32(r_sbits(r, numbits))
				}
				px += dx;py += dy
				append(&segs, Seg{kind = .Line, x = px, y = py})
			} else {
				cx := px + f32(r_sbits(r, numbits))
				cy := py + f32(r_sbits(r, numbits))
				px = cx + f32(r_sbits(r, numbits))
				py = cy + f32(r_sbits(r, numbits))
				append(&segs, Seg{kind = .Quad, x = px, y = py, cx = cx, cy = cy})
			}
		}
	}
	return segs[:], len(segs) > 0
}
