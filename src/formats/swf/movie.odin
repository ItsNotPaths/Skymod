package swf

// The display model of an SWF/GFX: shape definitions (every fill and line style), sprite timelines
// as a display list per frame, text field boxes, and the root timeline. Enough to render any named
// instance at any frame and to measure where it sits on the stage. Coordinates are twips (1/20 px).

import "core:strings"

Matrix :: struct {
	a, b, c, d, tx, ty: f32, // x' = a·x + c·y + tx, y' = b·x + d·y + ty
}

IDENTITY :: Matrix{1, 0, 0, 1, 0, 0}

// Cxform maps a colour: c' = c·mul + add (add in 0..255).
Cxform :: struct {
	mul, add: [4]f32,
}

CX_IDENTITY :: Cxform{{1, 1, 1, 1}, {}}

Rect :: struct {
	x0, y0, x1, y1: f32,
}

EMPTY_RECT :: Rect{1e30, 1e30, -1e30, -1e30}

Fill_Kind :: enum {
	Solid,
	Linear,
	Radial,
	Bitmap, // not drawn
}

Gradient_Stop :: struct {
	at:    f32, // 0..1
	color: [4]u8,
}

Fill :: struct {
	kind:  Fill_Kind,
	color: [4]u8, // Solid
	stops: []Gradient_Stop,
	mat:   Matrix, // gradient square (±16384 twips) → shape space
}

Line :: struct {
	width: f32, // twips
	color: [4]u8,
}

// Edge is one shape edge with the styles on each side; style indices are 1-based into the shape's
// fills/lines (0 = none). fill1 is on the edge's right in drawing order, fill0 on its left.
Edge :: struct {
	fill0, fill1, line: int,
	x0, y0, cx, cy, x1, y1: f32,
	curve: bool,
}

Shape_Def :: struct {
	bounds: Rect,
	fills:  []Fill,
	lines:  []Line,
	edges:  []Edge,
}

Place :: struct {
	depth: u16,
	id:    u16,
	name:  string,
	mat:   Matrix,
	cx:    Cxform,
	clip:  u16, // a mask layer when set; not drawn
}

Sprite :: struct {
	frames: [][]Place, // the display list at each frame, by depth
	labels: map[string]int,
}

Text_Def :: struct {
	bounds: Rect,
}

Character :: union {
	Shape_Def,
	Sprite,
	Text_Def,
}

Movie :: struct {
	stage: Rect,
	chars: map[u16]Character,
	root:  Sprite,
}

mat_mul :: proc(p, q: Matrix) -> Matrix { // q first, then p
	return {
		a  = p.a * q.a + p.c * q.b,
		b  = p.b * q.a + p.d * q.b,
		c  = p.a * q.c + p.c * q.d,
		d  = p.b * q.c + p.d * q.d,
		tx = p.a * q.tx + p.c * q.ty + p.tx,
		ty = p.b * q.tx + p.d * q.ty + p.ty,
	}
}

mat_apply :: proc(m: Matrix, x, y: f32) -> (f32, f32) {
	return m.a * x + m.c * y + m.tx, m.b * x + m.d * y + m.ty
}

mat_invert :: proc(m: Matrix) -> Matrix {
	det := m.a * m.d - m.b * m.c
	if det == 0 {return IDENTITY}
	i := 1 / det
	return {
		a  = m.d * i,
		b  = -m.b * i,
		c  = -m.c * i,
		d  = m.a * i,
		tx = (m.c * m.ty - m.d * m.tx) * i,
		ty = (m.b * m.tx - m.a * m.ty) * i,
	}
}

cx_mul :: proc(outer, inner: Cxform) -> Cxform {
	return {outer.mul * inner.mul, outer.mul * inner.add + outer.add}
}

rect_union :: proc(a, b: Rect) -> Rect {
	return {min(a.x0, b.x0), min(a.y0, b.y0), max(a.x1, b.x1), max(a.y1, b.y1)}
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	r := Rect{max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)}
	return r if r.x0 < r.x1 && r.y0 < r.y1 else EMPTY_RECT
}

rect_empty :: proc(r: Rect) -> bool {
	return r.x1 < r.x0
}

// rect_xform is the box around `r` after `m`.
rect_xform :: proc(r: Rect, m: Matrix) -> Rect {
	out := EMPTY_RECT
	for p in ([4][2]f32{{r.x0, r.y0}, {r.x1, r.y0}, {r.x0, r.y1}, {r.x1, r.y1}}) {
		x, y := mat_apply(m, p.x, p.y)
		out = rect_union(out, {x, y, x, y})
	}
	return out
}

// parse_movie reads every shape, sprite and text field of an SWF/GFX file. All of it lives in
// `allocator`; names borrow the decompressed body, which is allocated there too.
parse_movie :: proc(file: []u8, allocator := context.allocator) -> (m: Movie, ok: bool) {
	body := swf_body(file, allocator) or_return
	if len(body) < 1 {return}
	r := Reader{body, 0, 0}
	m.stage = read_rect(&r)
	r_align(&r)
	r.byte_pos += 4 // frame rate, frame count
	m.chars = make(map[u16]Character, allocator = allocator)
	m.root = parse_timeline(&m, body[r.byte_pos:], allocator)
	return m, true
}

// parse_timeline walks one tag stream (the root, or a sprite's), defining characters and building
// the display list frame by frame.
@(private)
parse_timeline :: proc(m: ^Movie, b: []u8, allocator: Allocator) -> Sprite {
	s := Sprite{labels = make(map[string]int, allocator = allocator)}
	frames := make([dynamic][]Place, allocator)
	list := make([dynamic]Place, context.temp_allocator)
	pos := 0
	for pos + 2 <= len(b) {
		tc := int(u16le(b, pos));pos += 2
		code := tc >> 6
		length := tc & 0x3f
		if length == 0x3f {
			if pos + 4 > len(b) {break}
			length = int(u32le(b, pos));pos += 4
		}
		if pos + length > len(b) {break}
		d := b[pos:pos + length]
		pos += length
		switch code {
		case 0:
			return finish_sprite(&s, &frames, list[:])
		case 1: // ShowFrame
			append(&frames, clone_list(list[:], allocator))
		case 2, 22, 32, 83:
			if sh, id, sok := parse_shape(d, code, allocator); sok {m.chars[id] = sh}
		case 39: // DefineSprite
			if len(d) >= 4 {m.chars[u16le(d, 0)] = parse_timeline(m, d[4:], allocator)}
		case 37: // DefineEditText
			if len(d) >= 2 {
				tr := Reader{d, 2, 0}
				m.chars[u16le(d, 0)] = Text_Def{read_rect(&tr)}
			}
		case 26, 70:
			place(&list, d, code == 70)
		case 5, 28: // RemoveObject, RemoveObject2
			depth := u16le(d, 2 if code == 5 else 0)
			for p, i in list {
				if p.depth == depth {ordered_remove(&list, i);break}
			}
		case 43: // FrameLabel
			name, _ := cstr(d, 0)
			s.labels[strings.clone(name, allocator)] = len(frames)
		}
	}
	return finish_sprite(&s, &frames, list[:])
}

@(private)
finish_sprite :: proc(s: ^Sprite, frames: ^[dynamic][]Place, list: []Place) -> Sprite {
	if len(frames) == 0 && len(list) > 0 {append(frames, clone_list(list, frames.allocator))}
	s.frames = frames[:]
	return s^
}

@(private)
clone_list :: proc(list: []Place, allocator: Allocator) -> []Place {
	out := make([]Place, len(list), allocator)
	copy(out, list)
	return out
}

// place applies a PlaceObject2/3 to the display list: a new object, a replaced character or a moved one.
@(private)
place :: proc(list: ^[dynamic]Place, d: []u8, po3: bool) {
	r := Reader{d, 0, 0}
	flags := r_u8(&r)
	flags2: u8
	if po3 {flags2 = r_u8(&r)}
	depth := r_u16(&r)
	has_char := flags & 0x02 != 0
	if po3 && (flags2 & 0x08 != 0 || (flags2 & 0x10 != 0 && has_char)) {
		_, r.byte_pos = cstr(d, r.byte_pos) // class name
	}
	at := -1
	for p, i in list {
		if p.depth == depth {at = i;break}
	}
	if flags & 0x01 == 0 || at < 0 { // a new object at `depth`
		p := Place{depth = depth, mat = IDENTITY, cx = CX_IDENTITY}
		if at >= 0 {
			list[at] = p
		} else {
			at = len(list)
			for q, i in list {
				if q.depth > depth {at = i;break}
			}
			inject_at(list, at, p)
		}
	}
	p := &list[at]
	if has_char {p.id = r_u16(&r)}
	if flags & 0x04 != 0 {p.mat = read_matrix(&r)}
	if flags & 0x08 != 0 {p.cx = read_cxform(&r)}
	if flags & 0x10 != 0 {r_u16(&r)} // ratio
	if flags & 0x20 != 0 {
		p.name, r.byte_pos = cstr(d, r.byte_pos)
	}
	if flags & 0x40 != 0 {p.clip = r_u16(&r)}
}

@(private)
read_rect :: proc(r: ^Reader) -> Rect {
	n := int(r_ubits(r, 5))
	x0 := f32(r_sbits(r, n))
	x1 := f32(r_sbits(r, n))
	y0 := f32(r_sbits(r, n))
	y1 := f32(r_sbits(r, n))
	return {x0, y0, x1, y1}
}

@(private)
read_matrix :: proc(r: ^Reader) -> Matrix {
	m := IDENTITY
	if r_ubits(r, 1) != 0 {
		n := int(r_ubits(r, 5))
		m.a = f32(r_sbits(r, n)) / 65536
		m.d = f32(r_sbits(r, n)) / 65536
	}
	if r_ubits(r, 1) != 0 {
		n := int(r_ubits(r, 5))
		m.b = f32(r_sbits(r, n)) / 65536
		m.c = f32(r_sbits(r, n)) / 65536
	}
	n := int(r_ubits(r, 5))
	m.tx = f32(r_sbits(r, n))
	m.ty = f32(r_sbits(r, n))
	r_align(r)
	return m
}

@(private)
read_cxform :: proc(r: ^Reader) -> Cxform {
	cx := CX_IDENTITY
	has_add := r_ubits(r, 1) != 0
	has_mul := r_ubits(r, 1) != 0
	n := int(r_ubits(r, 4))
	if has_mul {
		for i in 0 ..< 4 {cx.mul[i] = f32(r_sbits(r, n)) / 256}
	}
	if has_add {
		for i in 0 ..< 4 {cx.add[i] = f32(r_sbits(r, n))}
	}
	r_align(r)
	return cx
}
