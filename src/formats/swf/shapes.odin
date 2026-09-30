package swf

// DefineShape 1-4: bounds, every fill style (solid, linear and radial gradients, bitmap), every line
// style, and the edges with the styles on each side. New styles mid-shape append to the shape's style
// arrays, so edge style indices stay global to the shape.

@(private)
parse_shape :: proc(b: []u8, code: int, allocator: Allocator) -> (sh: Shape_Def, id: u16, ok: bool) {
	r := Reader{b, 0, 0}
	id = r_u16(&r)
	sh.bounds = read_rect(&r)
	r_align(&r)
	if code == 83 { // DefineShape4: edge bounds + flags
		read_rect(&r)
		r_align(&r)
		r_u8(&r)
	}
	fills := make([dynamic]Fill, allocator)
	lines := make([dynamic]Line, allocator)
	edges := make([dynamic]Edge, allocator)
	read_styles(&r, code, &fills, &lines, allocator) or_return
	nfill := int(r_ubits(&r, 4))
	nline := int(r_ubits(&r, 4))
	fill_base, line_base := 0, 0
	fill0, fill1, line: int
	px, py: f32
	for r.byte_pos < len(r.b) {
		if r_ubits(&r, 1) == 0 {
			flags := r_ubits(&r, 5)
			if flags == 0 {break}
			if flags & 0x01 != 0 {
				n := int(r_ubits(&r, 5))
				px = f32(r_sbits(&r, n))
				py = f32(r_sbits(&r, n))
			}
			f0, f1, l: Maybe(u32)
			if flags & 0x02 != 0 {f0 = r_ubits(&r, nfill)}
			if flags & 0x04 != 0 {f1 = r_ubits(&r, nfill)}
			if flags & 0x08 != 0 {l = r_ubits(&r, nline)}
			if flags & 0x10 != 0 { // new styles; this record's indices name them
				r_align(&r)
				fill_base, line_base = len(fills), len(lines)
				read_styles(&r, code, &fills, &lines, allocator) or_return
				nfill = int(r_ubits(&r, 4))
				nline = int(r_ubits(&r, 4))
				fill0, fill1, line = 0, 0, 0
			}
			if v, set := f0.?; set {fill0 = style_index(v, fill_base)}
			if v, set := f1.?; set {fill1 = style_index(v, fill_base)}
			if v, set := l.?; set {line = style_index(v, line_base)}
			continue
		}
		e := Edge{fill0 = fill0, fill1 = fill1, line = line, x0 = px, y0 = py}
		straight := r_ubits(&r, 1) != 0
		n := int(r_ubits(&r, 4)) + 2
		if straight {
			dx, dy: f32
			if r_ubits(&r, 1) != 0 {
				dx = f32(r_sbits(&r, n))
				dy = f32(r_sbits(&r, n))
			} else if r_ubits(&r, 1) != 0 {
				dy = f32(r_sbits(&r, n))
			} else {
				dx = f32(r_sbits(&r, n))
			}
			px += dx;py += dy
		} else {
			e.curve = true
			e.cx = px + f32(r_sbits(&r, n))
			e.cy = py + f32(r_sbits(&r, n))
			px = e.cx + f32(r_sbits(&r, n))
			py = e.cy + f32(r_sbits(&r, n))
		}
		e.x1, e.y1 = px, py
		append(&edges, e)
	}
	sh.fills, sh.lines, sh.edges = fills[:], lines[:], edges[:]
	return sh, id, true
}

@(private)
style_index :: proc(v: u32, base: int) -> int {
	return 0 if v == 0 else base + int(v)
}

@(private)
read_count :: proc(r: ^Reader) -> int {
	n := int(r_u8(r))
	if n == 0xff {n = int(r_u16(r))}
	return n
}

@(private)
read_color :: proc(r: ^Reader, alpha: bool) -> [4]u8 {
	c := [4]u8{r_u8(r), r_u8(r), r_u8(r), 255}
	if alpha {c[3] = r_u8(r)}
	return c
}

@(private)
read_styles :: proc(r: ^Reader, code: int, fills: ^[dynamic]Fill, lines: ^[dynamic]Line, allocator: Allocator) -> bool {
	alpha := code == 32 || code == 83
	nfill := read_count(r) // a range bound is read again each pass
	for _ in 0 ..< nfill {
		append(fills, read_fill(r, alpha, allocator) or_return)
	}
	nline := read_count(r)
	for _ in 0 ..< nline {
		l := Line{width = f32(r_u16(r))}
		if code != 83 {
			l.color = read_color(r, alpha)
		} else {
			f1 := r_u8(r)
			r_u8(r)
			if (f1 >> 4) & 3 == 2 {r_u16(r)} // miter limit
			if f1 & 0x08 != 0 {
				f := read_fill(r, true, allocator) or_return
				l.color = f.color if f.kind == .Solid else (f.stops[0].color if len(f.stops) > 0 else {})
			} else {
				l.color = read_color(r, true)
			}
		}
		append(lines, l)
	}
	return true
}

@(private)
read_fill :: proc(r: ^Reader, alpha: bool, allocator: Allocator) -> (f: Fill, ok: bool) {
	switch kind := r_u8(r); kind {
	case 0x00:
		f.color = read_color(r, alpha)
	case 0x10, 0x12, 0x13:
		f.kind = .Linear if kind == 0x10 else .Radial
		f.mat = read_matrix(r)
		n := int(r_u8(r) & 0x0f)
		f.stops = make([]Gradient_Stop, n, allocator)
		for &s in f.stops {
			s.at = f32(r_u8(r)) / 255
			s.color = read_color(r, alpha)
		}
		if kind == 0x13 {r_u16(r)} // focal point
	case 0x40 ..= 0x43:
		f.kind = .Bitmap
		r_u16(r)
		f.mat = read_matrix(r)
	case:
		return {}, false
	}
	return f, true
}

// shape_color is a shape's first solid fill, white when it has none.
shape_color :: proc(sh: Shape_Def) -> [4]u8 {
	for f in sh.fills {
		if f.kind == .Solid {return f.color}
	}
	return {255, 255, 255, 255}
}
