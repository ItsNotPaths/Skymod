package font

// Font engine layer 2-3 (rasterizer + atlas). Turns the vector glyph OUTLINES that `formats/swf`
// extracts from Skyrim's real UI fonts (Futura Condensed et al.) into a packed bitmap ATLAS + a
// per-glyph metrics table the UI substrate draws text from. Pure CPU + game-agnostic: no GPU, no
// SDL, no imgui — the renderer uploads `Atlas.pixels` as a texture and samples the per-glyph UV
// rects. The flow: flatten the quadratic Béziers → coverage-AA scanline fill (non-zero winding,
// analytic horizontal coverage + N vertical sub-samples) → shelf-pack the glyph bitmaps → metrics.
//
// The atlas is LIVE and LAZY: each (glyph, integer-px) pair is rasterized AT ITS DISPLAY SIZE on
// first use and cached. Skyrim's UI never animates text size, so a handful of discrete sizes ever
// bake. This replaces the old "rasterize one 64px master, then minify every size off it" approach —
// minifying a coverage atlas (even with mips) is exactly what made small text wobble/shimmer.
//
// The atlas is RGBA8 with rgb = 255 and a = coverage, so ONE UI shader draws both solid rects (over
// a 1×1 white texture) and glyphs (over the atlas) as `vertex_color * texel` — a glyph paints the
// node colour modulated by coverage, a rect paints the node colour flat.

import "../formats/swf"
import "base:runtime"
import "core:math"
import "core:strings"

// Glyph_Metric places one rune in the atlas + carries the pen geometry to lay it out. Pixel units
// at the rasterized size; `u0..v1` are normalized atlas coords for the quad.
Glyph_Metric :: struct {
	code:                rune,
	u0, v0, u1, v1:      f32, // atlas UV rect (normalized)
	w, h:                f32, // glyph bitmap size in px (0 for whitespace)
	bearing_x:           f32, // pen-x → left edge of the bitmap
	bearing_y:           f32, // baseline → TOP edge of the bitmap (positive up)
	advance:             f32, // pen advance to the next glyph
}

// Glyph_Key identifies one baked glyph: a codepoint AT a specific integer pixel size. Each size is
// rasterized separately and crisply — the atlas NEVER minifies one master size down (that shimmers).
Glyph_Key :: struct {
	code: rune,
	px:   int,
}

// Atlas is a LIVE, lazily-baked glyph cache: it keeps the vector outlines resident and rasterizes
// each (glyph, px) on first use into a shared, shelf-packed coverage bitmap — so every text size is
// sampled ~1:1 instead of minified from one over-sized master (the source of the small-text wobble).
// Pure CPU; the renderer re-uploads `pixels` to a GPU texture whenever `dirty`. Free with destroy.
Atlas :: struct {
	font:                  swf.Font,            // resident outlines (owned copy) for on-demand baking
	index:                 map[rune]int,        // code → font.glyphs index, for O(1) lookup
	ref_em:                f32,                  // px that the UI's `scale==1` maps to (authoring norm)
	space_em:              f32,                  // ' ' advance in FONT UNITS (fallback for missing glyphs)
	pixels:                []u8,                 // RGBA8, w*h*4 (rgb=255, a=coverage); shelf-packed
	w, h:                  int,
	pen_x, pen_y, shelf_h: int,                  // running shelf packer cursor
	dirty:                 bool,                 // pixels changed since the last GPU upload
	glyphs:                map[Glyph_Key]Glyph_Metric,
	allocator:             runtime.Allocator,
}

// SS is the vertical super-sampling factor (sub-scanlines per output row). Horizontal coverage is
// computed analytically per span, so 4 vertical samples already give clean edges at UI sizes.
@(private)
SS :: 4

// PAD is the 1px transparent gutter around each packed glyph so LINEAR sampling at the glyph's edge
// can't bleed in a neighbour. (No mip chain anymore — glyphs bake at display size, so 1px suffices.)
@(private)
PAD :: 1

// make_atlas builds a live atlas over `src`'s outlines: it DEEP-COPIES the font (so the parse can use
// a temp allocator) and allocates a blank `dim`×`dim` bitmap to bake into. `ref_em` is the pixel size
// the UI's `scale == 1` maps to. Nothing is rasterized until a glyph is first requested. Free with
// destroy.
make_atlas :: proc(src: swf.Font, ref_em: f32, dim := 1024, allocator := context.allocator) -> Atlas {
	a: Atlas
	a.allocator = allocator
	a.ref_em = ref_em
	a.w = dim
	a.h = dim
	a.pixels = make([]u8, dim * dim * 4, allocator) // zeroed = fully transparent
	a.pen_x, a.pen_y, a.shelf_h = PAD, PAD, 0
	a.glyphs = make(map[Glyph_Key]Glyph_Metric, allocator)

	// Own a copy of the outlines so the atlas outlives the (temp-allocated) parse.
	f := src
	f.name = strings.clone(src.name, allocator)
	f.glyphs = make([]swf.Glyph, len(src.glyphs), allocator)
	for g, i in src.glyphs {
		ng := g
		ng.segs = make([]swf.Seg, len(g.segs), allocator)
		copy(ng.segs, g.segs)
		f.glyphs[i] = ng
	}
	a.font = f

	a.index = make(map[rune]int, allocator)
	for g, i in f.glyphs {
		a.index[g.code] = i
	}
	for g in f.glyphs {
		if g.code == ' ' {
			a.space_em = g.advance
		}
	}
	if a.space_em <= 0 {
		a.space_em = f.em * 0.3
	}
	return a
}

destroy :: proc(a: ^Atlas) {
	delete(a.pixels, a.allocator)
	delete(a.glyphs)
	delete(a.index)
	for g in a.font.glyphs {
		delete(g.segs, a.allocator)
	}
	delete(a.font.glyphs, a.allocator)
	delete(a.font.name, a.allocator)
	a^ = {}
}

// glyph_at returns the metric for `r` at integer size `px`, baking it into the atlas on first use.
glyph_at :: proc(a: ^Atlas, r: rune, px: int) -> Glyph_Metric {
	if m, ok := a.glyphs[{r, px}]; ok {
		return m
	}
	return bake_glyph(a, r, px)
}

// measure_text returns the advance width (px) of `text` at size `px` (single line; no kerning). Bakes
// each glyph as a side effect (measure precedes draw, and measured text is text we're about to draw).
measure_text :: proc(a: ^Atlas, text: string, px: int) -> f32 {
	w: f32
	for r in text {
		w += glyph_at(a, r, px).advance
	}
	return w
}

// vmetrics returns the ascent (baseline→top) and full line height at size `px`.
vmetrics :: proc(a: ^Atlas, px: int) -> (ascent, line_height: f32) {
	s := f32(px) / a.font.em
	ascent = a.font.ascent * s
	line_height = (a.font.ascent + abs(a.font.descent) + a.font.leading) * s
	if line_height <= 0 {
		line_height = f32(px) * 1.25
	}
	return
}

// bake_glyph rasterizes `r` at `px` and shelf-packs it into the live atlas, caching + returning its
// metric. Whitespace / outline-less / unknown runes cache an advance-only metric (no bitmap). If the
// atlas is full the glyph caches advance-only (renders nothing) rather than overflowing the bitmap.
@(private)
bake_glyph :: proc(a: ^Atlas, r: rune, px: int) -> Glyph_Metric {
	scale := f32(px) / a.font.em
	idx, found := a.index[r]
	if !found {
		m := Glyph_Metric{code = r, advance = a.space_em * scale}
		a.glyphs[{r, px}] = m
		return m
	}
	g := a.font.glyphs[idx]
	adv := g.advance * scale
	if r == ' ' || len(g.segs) == 0 {
		m := Glyph_Metric{code = r, advance = adv}
		a.glyphs[{r, px}] = m
		return m
	}
	cov, gw, gh, bx, by := raster_glyph(g, scale)
	if gw == 0 || gh == 0 {
		m := Glyph_Metric{code = r, advance = adv}
		a.glyphs[{r, px}] = m
		return m
	}
	// Shelf-pack: place left→right; wrap to a new shelf at the width cap.
	if a.pen_x + gw + PAD > a.w {
		a.pen_x = PAD
		a.pen_y += a.shelf_h + PAD
		a.shelf_h = 0
	}
	if a.pen_y + gh + PAD > a.h {
		m := Glyph_Metric{code = r, advance = adv} // atlas full → metric only
		a.glyphs[{r, px}] = m
		return m
	}
	gx, gy := a.pen_x, a.pen_y
	for row in 0 ..< gh {
		for col in 0 ..< gw {
			c := cov[row * gw + col]
			i := ((gy + row) * a.w + (gx + col)) * 4
			a.pixels[i + 0] = 255
			a.pixels[i + 1] = 255
			a.pixels[i + 2] = 255
			a.pixels[i + 3] = c
		}
	}
	a.pen_x += gw + PAD
	a.shelf_h = max(a.shelf_h, gh)
	a.dirty = true
	m := Glyph_Metric {
		code      = r,
		u0        = f32(gx) / f32(a.w),
		v0        = f32(gy) / f32(a.h),
		u1        = f32(gx + gw) / f32(a.w),
		v1        = f32(gy + gh) / f32(a.h),
		w         = f32(gw),
		h         = f32(gh),
		bearing_x = bx,
		bearing_y = by,
		advance   = adv,
	}
	a.glyphs[{r, px}] = m
	return m
}

// pick_font chooses the best UI face from a parsed SWF font set: prefer a name containing "futura"
// (and "condensed"), else the font with the most glyphs (the body face). Returns -1 if none.
pick_font :: proc(names: []string, glyph_counts: []int) -> int {
	best := -1
	best_score := -1
	for name, i in names {
		lower := strings.to_lower(name, context.temp_allocator)
		score := glyph_counts[i] // tie-break toward the richest face
		if strings.contains(lower, "futura") {score += 100000}
		if strings.contains(lower, "condensed") {score += 50000}
		if score > best_score {
			best_score = score
			best = i
		}
	}
	return best
}

// rasterize_shape fills a DefineShape's contours (in twips; `scale` 1/20 → native px) as a SOLID
// silhouette tinted by `fill` (straight RGBA) — reusing the glyph coverage rasterizer. For converting
// flat vector menu graphics (e.g. the BGS logo) to a DDS. rgba owned by `allocator`; w/h are the
// tight bitmap size, 0 if the shape is empty/degenerate.
rasterize_shape :: proc(segs: []swf.Seg, scale: f32, fill: [4]u8, allocator := context.allocator) -> (rgba: []u8, w, h: int) {
	cov, cw, ch, _, _ := raster_glyph(swf.Glyph{segs = segs}, scale)
	if cw <= 0 || ch <= 0 {
		return nil, 0, 0
	}
	out := make([]u8, cw * ch * 4, allocator)
	for i in 0 ..< cw * ch {
		out[i * 4 + 0] = fill[0]
		out[i * 4 + 1] = fill[1]
		out[i * 4 + 2] = fill[2]
		out[i * 4 + 3] = u8(int(cov[i]) * int(fill[3]) / 255)
	}
	return out, cw, ch
}

// ── rasterization ─────────────────────────────────────────────────────────────────────────────

// Edge is one flattened straight segment in atlas-pixel space (after Bézier subdivision).
@(private)
Edge :: struct {
	x0, y0, x1, y1: f32,
}

// raster_glyph flattens a glyph's outline at `scale`, then coverage-fills its bounding box. Returns
// the coverage bitmap (temp-allocated), its size, and the pen bearings (left side bearing + baseline
// →top). SWF font Y is up (baseline at 0, ascenders positive), so we flip to atlas Y-down here.
@(private)
raster_glyph :: proc(g: swf.Glyph, scale: f32) -> (cov: []u8, w, h: int, bearing_x, bearing_y: f32) {
	edges := make([dynamic]Edge, context.temp_allocator)
	// Flatten into edges in a Y-up float space (font units * scale). Track the bbox.
	minx, miny := f32(1e30), f32(1e30)
	maxx, maxy := f32(-1e30), f32(-1e30)
	px, py: f32 // current point (Y-up, scaled)
	sx, sy: f32 // contour start (to close it)
	have_start := false
	note :: proc(minx, miny, maxx, maxy: ^f32, x, y: f32) {
		minx^ = min(minx^, x);miny^ = min(miny^, y)
		maxx^ = max(maxx^, x);maxy^ = max(maxy^, y)
	}
	emit_line :: proc(edges: ^[dynamic]Edge, x0, y0, x1, y1: f32) {
		if y0 != y1 { // horizontal edges contribute no winding crossings
			append(edges, Edge{x0, y0, x1, y1})
		}
	}
	for seg in g.segs {
		x := seg.x * scale
		y := seg.y * scale
		switch seg.kind {
		case .Move:
			// Close the previous contour (font fills need closed loops for the winding to balance).
			if have_start && (px != sx || py != sy) {
				emit_line(&edges, px, py, sx, sy)
			}
			px, py = x, y
			sx, sy = x, y
			have_start = true
			note(&minx, &miny, &maxx, &maxy, x, y)
		case .Line:
			emit_line(&edges, px, py, x, y)
			note(&minx, &miny, &maxx, &maxy, x, y)
			px, py = x, y
		case .Quad:
			cx := seg.cx * scale
			cy := seg.cy * scale
			// Subdivide the quadratic Bézier into line segments; step count from a rough chord.
			n := bezier_steps(px, py, cx, cy, x, y)
			lx, ly := px, py
			for i in 1 ..= n {
				t := f32(i) / f32(n)
				mt := 1 - t
				bx := mt * mt * px + 2 * mt * t * cx + t * t * x
				by := mt * mt * py + 2 * mt * t * cy + t * t * y
				emit_line(&edges, lx, ly, bx, by)
				note(&minx, &miny, &maxx, &maxy, bx, by)
				lx, ly = bx, by
			}
			px, py = x, y
		}
	}
	// Close the final contour.
	if have_start && (px != sx || py != sy) {
		emit_line(&edges, px, py, sx, sy)
	}
	if len(edges) == 0 || maxx <= minx || maxy <= miny {
		return nil, 0, 0, 0, 0
	}

	// Bitmap bounds: integer box covering the outline, with a 1px margin so AA edges aren't clipped.
	x0i := int(math.floor(minx)) - 1
	y0i := int(math.floor(miny)) - 1
	x1i := int(math.ceil(maxx)) + 1
	y1i := int(math.ceil(maxy)) + 1
	w = x1i - x0i
	h = y1i - y0i
	if w <= 0 || h <= 0 {
		return nil, 0, 0, 0, 0
	}
	bearing_x = f32(x0i)
	// SWF glyph Y is DOWN (the top of a glyph is the SMALLEST Y; the baseline is 0). The atlas is also
	// Y-down (row 0 = top), so map font-Y straight to bitmap rows — NO flip (flipping renders text
	// upside down). bearing_y = baseline→top, positive up = -y0i (the top edge sits above baseline).
	bearing_y = -f32(y0i)

	acc := make([]f32, w * h, context.temp_allocator) // coverage accumulator
	for e in edges {
		ex0 := e.x0 - f32(x0i)
		ex1 := e.x1 - f32(x0i)
		ey0 := e.y0 - f32(y0i)
		ey1 := e.y1 - f32(y0i)
		scan_edge(acc, w, h, ex0, ey0, ex1, ey1)
	}

	cov = make([]u8, w * h, context.temp_allocator)
	for i in 0 ..< w * h {
		// Non-zero winding: a cell is filled where the signed winding number is non-zero. abs()
		// makes it orientation-agnostic (a glyph's outer contour may be CW or CCW), and the
		// fractional boundary cells keep the anti-aliased edge ramp.
		v := clamp(abs(acc[i]), 0, 1)
		cov[i] = u8(v * 255 + 0.5)
	}
	return cov, w, h, bearing_x, bearing_y
}

// bezier_steps picks a subdivision count for a quadratic from the control-polygon length.
@(private)
bezier_steps :: proc(x0, y0, cx, cy, x1, y1: f32) -> int {
	d := math.hypot(cx - x0, cy - y0) + math.hypot(x1 - cx, y1 - cy)
	n := int(d / 3) // ~3px per segment
	return clamp(n, 2, 32)
}

// scan_edge accumulates one edge's contribution into the coverage buffer using non-zero winding with
// analytic horizontal coverage and SS vertical sub-samples. The standard span approach: at each
// sub-scanline an edge contributes a crossing (x, winding±1); we don't have all edges here, so
// instead we accumulate signed horizontal coverage to the RIGHT of each crossing and rely on the
// per-row prefix in scan finalize. To keep it simple and self-contained we use the classic
// "signed area" trick per edge: add +dir coverage from the crossing x to the row's right edge,
// scaled by 1/SS; overlapping opposite edges cancel, leaving filled spans. Coverage is clamped at
// read time. This matches stb_truetype's v_subsample sweep at SS sub-rows.
@(private)
scan_edge :: proc(acc: []f32, w, h: int, x0, y0, x1, y1: f32) {
	if y0 == y1 {
		return
	}
	dir: f32 = 1
	ax, ay, bx, by := x0, y0, x1, y1
	if ay > by {
		ax, ay, bx, by = bx, by, ax, ay
		dir = -1
	}
	dxdy := (bx - ax) / (by - ay)
	for row in 0 ..< h {
		for s in 0 ..< SS {
			yc := f32(row) + (f32(s) + 0.5) / f32(SS)
			if yc < ay || yc >= by {
				continue
			}
			xc := ax + (yc - ay) * dxdy
			// Add signed coverage from xc to the right edge of the row, weight 1/SS.
			add_span(acc, w, row, xc, dir / f32(SS))
		}
	}
}

// add_span adds `amt` coverage from x = `from` to the right edge of `row`, with the partial-pixel
// cell at `from` weighted by its uncovered fraction (analytic horizontal AA).
@(private)
add_span :: proc(acc: []f32, w, row: int, from: f32, amt: f32) {
	x := from
	if x < 0 {
		x = 0
	}
	if int(x) >= w {
		return
	}
	col := int(x)
	frac := 1 - (x - f32(col)) // covered fraction of the first cell
	acc[row * w + col] += amt * frac
	for c in col + 1 ..< w {
		acc[row * w + c] += amt
	}
}
