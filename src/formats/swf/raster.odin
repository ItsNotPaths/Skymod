package swf

// Renders characters of a Movie into RGBA: every fill of a shape (solid and gradient, non-zero
// winding over the edges that bound it), its lines as quads, sprites through their display list at a
// frame label, all under the placement matrices and colour transforms. Text fields are not drawn.

import "core:math"
import "core:strings"

// Image is straight-alpha RGBA8. `rect` is the area it covers, in the space it was rendered in (px).
Image :: struct {
	rgba: []u8,
	w, h: int,
	rect: Rect,
}

@(private)
Canvas :: struct {
	w, h: int,
	px:   [][4]f32, // premultiplied, 0..1
	acc:  []f32, // coverage scratch for one style
	mask: []f32, // the clip layers' coverage over what is drawn now; nil = none
	solid: bool, // drawing a clip layer: every fill counts as opaque
}

// SS is the vertical sub-samples per pixel row of the coverage accumulator.
SS :: 4

// accumulate adds one edge's signed coverage to `acc` (w×h, row-major): each crossing adds coverage
// from its x to the row's right end, so opposite edges cancel and filled spans remain (non-zero
// winding once the magnitude is clamped to 1).
accumulate :: proc(acc: []f32, w, h: int, x0, y0, x1, y1: f32) {
	if y0 == y1 {return}
	dir: f32 = 1
	ax, ay, bx, by := x0, y0, x1, y1
	if ay > by {
		ax, ay, bx, by = bx, by, ax, ay
		dir = -1
	}
	dxdy := (bx - ax) / (by - ay)
	for row in max(int(math.floor(ay)), 0) ..< min(int(math.ceil(by)), h) {
		for s in 0 ..< SS {
			yc := f32(row) + (f32(s) + 0.5) / SS
			if yc < ay || yc >= by {continue}
			add_span(acc, w, row, ax + (yc - ay) * dxdy, dir / SS)
		}
	}
}

@(private)
add_span :: proc(acc: []f32, w, row: int, from, amt: f32) {
	x := max(from, 0)
	if int(x) >= w {return}
	col := int(x)
	acc[row * w + col] += amt * (1 - (x - f32(col))) // the covered part of the first cell
	for c in col + 1 ..< w {acc[row * w + c] += amt}
}

// flatten appends an edge's points after `m` (the start point, then curve steps, then the end).
flatten :: proc(pts: ^[dynamic][2]f32, e: Edge, m: Matrix) {
	clear(pts)
	x0, y0 := mat_apply(m, e.x0, e.y0)
	x1, y1 := mat_apply(m, e.x1, e.y1)
	append(pts, [2]f32{x0, y0})
	if e.curve {
		cx, cy := mat_apply(m, e.cx, e.cy)
		n := clamp(int((math.hypot(cx - x0, cy - y0) + math.hypot(x1 - cx, y1 - cy)) / 3), 2, 32)
		for i in 1 ..< n {
			t := f32(i) / f32(n)
			u := 1 - t
			append(pts, [2]f32{u * u * x0 + 2 * u * t * cx + t * t * x1, u * u * y0 + 2 * u * t * cy + t * t * y1})
		}
	}
	append(pts, [2]f32{x1, y1})
}

// frame_list is a sprite's display list at `label`, or its first frame when it has no such label.
frame_list :: proc(s: Sprite, label: string) -> []Place {
	if len(s.frames) == 0 {return nil}
	f := s.labels[label] or_else 0
	return s.frames[clamp(f, 0, len(s.frames) - 1)]
}

// bounds is the box of character `id` at `label` after `m`. `texts` counts text field boxes.
bounds :: proc(mv: ^Movie, id: u16, label: string, m: Matrix, hide: []string = nil, texts := true) -> Rect {
	switch c in mv.chars[id] {
	case Shape_Def:
		return rect_xform(c.bounds, m)
	case Text_Def:
		return rect_xform(c.bounds, m) if texts else EMPTY_RECT
	case Sprite:
		out := EMPTY_RECT
		clip, until := Rect{}, u16(0) // a clip layer bounds the depths up to `until`
		for p in frame_list(c, label) {
			pm := mat_mul(m, p.mat)
			if p.clip != 0 {
				clip, until = bounds(mv, p.id, label, pm), p.clip
				continue
			}
			if hidden(p.name, hide) {continue}
			b := bounds(mv, p.id, label, pm, hide, texts)
			if p.depth <= until {b = rect_intersect(b, clip)}
			out = rect_union(out, b)
		}
		return out
	}
	return EMPTY_RECT
}

@(private)
hidden :: proc(name: string, hide: []string) -> bool {
	for h in hide {if h == name {return true}}
	return false
}

// find walks a dotted instance path from the root: its character and its matrix to the stage.
find :: proc(mv: ^Movie, path: string) -> (id: u16, m: Matrix, ok: bool) {
	m = IDENTITY
	s := mv.root
	rest := path
	for rest != "" {
		name := rest
		if i := strings.index_byte(rest, '.'); i >= 0 {
			name, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		p := find_place(s, name) or_return
		id, m = p.id, mat_mul(m, p.mat)
		if rest != "" {s = (mv.chars[id].(Sprite)) or_return}
	}
	return id, m, true
}

@(private)
find_place :: proc(s: Sprite, name: string) -> (Place, bool) {
	for f in s.frames {
		for p in f {if p.name == name {return p, true}}
	}
	return {}, false
}

// render_instance draws the instance at `path` as it sits on the stage, at `label` (any sprite
// inside that has the label shows it), `scale` px per stage px, without the named children in `hide`.
// Colour transforms above the instance (its fades) are left out. Image.rect is in stage px.
render_instance :: proc(mv: ^Movie, path, label: string, scale: f32, hide: []string = nil, allocator := context.allocator) -> (img: Image, ok: bool) {
	id, m := find(mv, path) or_return
	return render(mv, id, label, m, CX_IDENTITY, scale, hide, allocator)
}

// render_shape_image draws one shape definition at `scale` px per shape px.
render_shape_image :: proc(mv: ^Movie, id: u16, scale: f32, allocator := context.allocator) -> (Image, bool) {
	return render(mv, id, "", IDENTITY, CX_IDENTITY, scale, nil, allocator)
}

@(private)
render :: proc(mv: ^Movie, id: u16, label: string, m: Matrix, cx: Cxform, scale: f32, hide: []string, allocator: Allocator) -> (img: Image, ok: bool) {
	b := bounds(mv, id, label, m, hide, false)
	if rect_empty(b) {return}
	k := scale / 20
	x0, y0 := math.floor(b.x0 * k) - 1, math.floor(b.y0 * k) - 1
	x1, y1 := math.ceil(b.x1 * k) + 1, math.ceil(b.y1 * k) + 1
	c := Canvas{w = int(x1 - x0), h = int(y1 - y0)}
	if c.w <= 0 || c.h <= 0 || c.w * c.h > 16 << 20 {return}
	c.px = make([][4]f32, c.w * c.h, context.temp_allocator)
	c.acc = make([]f32, c.w * c.h, context.temp_allocator)
	draw(mv, &c, id, label, mat_mul(Matrix{k, 0, 0, k, -x0, -y0}, m), cx, hide)
	img = Image{make([]u8, c.w * c.h * 4, allocator), c.w, c.h, {x0 / scale, y0 / scale, x1 / scale, y1 / scale}}
	for p, i in c.px {
		if p.a <= 0 {continue}
		for ch in 0 ..< 3 {img.rgba[i * 4 + ch] = u8(clamp(p[ch] / p.a, 0, 1) * 255 + 0.5)}
		img.rgba[i * 4 + 3] = u8(clamp(p.a, 0, 1) * 255 + 0.5)
	}
	return img, true
}

@(private)
draw :: proc(mv: ^Movie, c: ^Canvas, id: u16, label: string, m: Matrix, cx: Cxform, hide: []string) {
	switch ch in mv.chars[id] {
	case Shape_Def:
		draw_shape(c, ch, m, cx)
	case Sprite:
		outer := c.mask
		until := u16(0)
		for p in frame_list(ch, label) {
			if p.depth > until {c.mask, until = outer, 0}
			if p.clip != 0 { // a clip layer: its fills mask the depths up to p.clip
				c.mask, until = clip_mask(mv, c, p.id, label, mat_mul(m, p.mat), outer), p.clip
				continue
			}
			if hidden(p.name, hide) {continue}
			draw(mv, c, p.id, label, mat_mul(m, p.mat), cx_mul(cx, p.cx), hide)
		}
		c.mask = outer
	case Text_Def:
	}
}

@(private)
draw_shape :: proc(c: ^Canvas, sh: Shape_Def, m: Matrix, cx: Cxform) {
	pts := make([dynamic][2]f32, context.temp_allocator)
	for f, i in sh.fills {
		if f.kind == .Bitmap {continue}
		style := i + 1
		for &a in c.acc {a = 0}
		for e in sh.edges {
			if e.fill0 != style && e.fill1 != style {continue}
			flatten(&pts, e, m)
			for j in 1 ..< len(pts) {
				a, b := pts[j - 1], pts[j]
				if e.fill1 == style {accumulate(c.acc, c.w, c.h, a.x, a.y, b.x, b.y)}
				if e.fill0 == style {accumulate(c.acc, c.w, c.h, b.x, b.y, a.x, a.y)}
			}
		}
		composite(c, f, m, cx)
	}
	px_per_twip := math.sqrt(abs(m.a * m.d - m.b * m.c))
	for l, i in sh.lines {
		style := i + 1
		for &a in c.acc {a = 0}
		hw := max(l.width * px_per_twip / 2, 0.5)
		for e in sh.edges {
			if e.line != style {continue}
			flatten(&pts, e, m)
			for j in 1 ..< len(pts) {stroke_segment(c, pts[j - 1], pts[j], hw)}
		}
		composite(c, Fill{kind = .Solid, color = l.color}, m, cx)
	}
}

// clip_mask is the coverage of a clip layer's fills, within the `outer` mask.
@(private)
clip_mask :: proc(mv: ^Movie, c: ^Canvas, id: u16, label: string, m: Matrix, outer: []f32) -> []f32 {
	mc := Canvas{w = c.w, h = c.h, solid = true, mask = outer}
	mc.px = make([][4]f32, c.w * c.h, context.temp_allocator)
	mc.acc = make([]f32, c.w * c.h, context.temp_allocator)
	draw(mv, &mc, id, label, m, CX_IDENTITY, nil)
	out := make([]f32, c.w * c.h, context.temp_allocator)
	for p, i in mc.px {out[i] = p.a}
	return out
}

// stroke_segment adds a segment as a quad `hw` px either side of it (no caps or joins).
@(private)
stroke_segment :: proc(c: ^Canvas, a, b: [2]f32, hw: f32) {
	d := b - a
	n := math.hypot(d.x, d.y)
	if n == 0 {return}
	o := [2]f32{-d.y, d.x} * (hw / n)
	q := [4][2]f32{a + o, b + o, b - o, a - o}
	for j in 0 ..< 4 {
		p0, p1 := q[j], q[(j + 1) % 4]
		accumulate(c.acc, c.w, c.h, p0.x, p0.y, p1.x, p1.y)
	}
}

// composite blends style colour × coverage over the canvas.
@(private)
composite :: proc(c: ^Canvas, f: Fill, m: Matrix, cx: Cxform) {
	inv := mat_invert(mat_mul(m, f.mat))
	for y in 0 ..< c.h {
		for x in 0 ..< c.w {
			i := y * c.w + x
			cov := min(abs(c.acc[i]), 1)
			if c.mask != nil {cov *= c.mask[i]}
			if cov < 1.0 / 512 {continue}
			col := fill_color(f, inv, f32(x) + 0.5, f32(y) + 0.5)
			for ch in 0 ..< 4 {col[ch] = clamp((col[ch] * cx.mul[ch] + cx.add[ch]) / 255, 0, 1)}
			if c.solid {col.a = 1}
			a := col.a * cov
			c.px[i] = [4]f32{col.r * a, col.g * a, col.b * a, a} + c.px[i] * (1 - a)
		}
	}
}

// fill_color is a style's colour (0..255) at canvas point (x, y); `inv` maps the canvas back to the
// gradient square.
@(private)
fill_color :: proc(f: Fill, inv: Matrix, x, y: f32) -> [4]f32 {
	if f.kind == .Solid || len(f.stops) == 0 {
		return {f32(f.color.r), f32(f.color.g), f32(f.color.b), f32(f.color.a)}
	}
	gx, gy := mat_apply(inv, x, y)
	t := (gx + 16384) / 32768 if f.kind == .Linear else math.hypot(gx, gy) / 16384
	t = clamp(t, 0, 1)
	prev := f.stops[0]
	for s in f.stops {
		if t <= s.at {
			span := s.at - prev.at
			u := (t - prev.at) / span if span > 0 else 1
			return lerp_color(prev.color, s.color, u)
		}
		prev = s
	}
	return lerp_color(prev.color, prev.color, 0)
}

@(private)
lerp_color :: proc(a, b: [4]u8, t: f32) -> [4]f32 {
	return {
		f32(a.r) + (f32(b.r) - f32(a.r)) * t,
		f32(a.g) + (f32(b.g) - f32(a.g)) * t,
		f32(a.b) + (f32(b.b) - f32(a.b)) * t,
		f32(a.a) + (f32(b.a) - f32(a.a)) * t,
	}
}
