package ui

// The retained UI substrate (player-facing skinned UI; distinct from the imgui dev/tools panels).
// A tree of nodes is laid out against a screen rect and emits backend-agnostic draw commands.
// Backend v1 emits these into imgui's DrawList (app side); v2 = own SDL3_gpu pipeline + fonts. Pure
// data + layout + emit — no imgui/render/SDL dependency, so the renderer is swappable.
//
// Layout: single-anchor (anchor a `pivot` point of self to an `anchor` point of the parent, + a
// pixel `offset`; `stretch`/`fill` fills the parent on an axis), PLUS flow containers (Column/Row)
// that stack their children with `gap`. The Lua loader builds this tree from declarative tables.
//
// Text: when a font atlas is set (set_font), Text/Button nodes measure to their glyph advance and
// emit per-glyph quads sampling the atlas; with no font they fall back to a single Text command (the
// legacy imgui backend). Interaction metadata (id/action/disabled) rides on the nodes so the app can
// hit-test + dispatch without a second tree.

import "../font"
import "core:math"

Color :: [4]f32 // rgba, 0..1

Rect :: struct {
	x, y, w, h: f32,
}

// g_font is the active glyph atlas used to measure + expand Text. nil = legacy single-Text emit.
@(private)
g_font: ^font.Atlas

// set_font installs the atlas the substrate measures + rasterizes text with (nil to clear).
set_font :: proc(a: ^font.Atlas) {
	g_font = a
}

// HOLE(ui, gap): .Image and .Effect both draw a flat placeholder rect — no texture wiring in the backend, so no icon, portrait or animated widget can render.
Kind :: enum {
	Container, // layout-only box (paints `color` as a background if opaque)
	Column,    // stacks children top→down with `gap`
	Row,       // stacks children left→right with `gap`
	Rect,      // filled rectangle
	Text,      // text at the node's top-left
	Image,     // textured quad (placeholder rect until backend v2)
	Effect,    // renderer-animated visual (placeholder rect for now)
	Bar,       // meter/progress FILL: shader-drawn glossy fill sized to `value` (0..1); frame/track are sibling nodes
}

Align :: enum {
	Start, // left (Column) / top (Row) — the default
	Center,
	End, // right (Column) / bottom (Row)
}

Node :: struct {
	kind:     Kind,
	anchor:   [2]f32, // point in the PARENT to anchor to (0..1)
	pivot:    [2]f32, // point in SELF placed on the anchor (0..1); loader defaults it to anchor
	offset:   [2]f32, // pixel offset from the anchored point
	size:     [2]f32, // pixel size (Text uses a default line height in flow layout)
	stretch:  [2]bool, // fill the parent on an axis (from `fill`)
	gap:      f32,     // Column/Row: spacing between children
	pad:      f32,     // Column/Row: inner padding (insets children, grows the auto-measured size)
	align:    Align,   // Column/Row: cross-axis alignment of children
	scale:    f32,     // Text: glyph scale vs the atlas px size (0 → 1.0); a title scales up, body down
	wrap:     f32,     // Text: max line width in px for word-wrap (0 = single line, no wrap)
	value:    f32,     // Bar: fill fraction 0..1 (the shader masks the fill to this along +x)
	color:    Color,
	text:     string, // owned by the loader's allocator (free with destroy)
	image:    string, // Image: art source name (resolved to a texture by the backend); owned
	flip_x:   bool,   // Image: mirror horizontally (e.g. a bar's left end-cap reuses the right cap art)
	slice:    [2]f32, // Image: horizontal 3-slice cap widths {left,right} in SOURCE px (0 = normal). Fixed
	                  //   caps + a stretched middle, so a bar frame/track stretches to any width cleanly.
	id:       string, // stable id for mod patches + focus tracking; owned
	action:   string, // Button: handler name dispatched on activate; owned
	disabled: bool,   // Button: greyed + non-interactive (resolved from `enabled`/binds)
	modal:    bool,   // captures input: the engine routes focus only within the topmost modal subtree
	bind:     string, // property binding path (e.g. enabled); owned; resolved by the app per frame
	children: [dynamic]Node,
	screen:   Rect, // computed by layout
}

// LINE_H is the assumed height (Column) / width (Row) of a child that doesn't specify a size — used
// to stack text rows before real text measurement lands.
LINE_H :: f32(28)

Cmd_Kind :: enum {
	Rect,  // solid fill (backend samples white)
	Text,  // whole-string text (legacy backend, no atlas)
	Image, // art texture quad (backend resolves `image` → texture)
	Glyph, // a single font-atlas glyph quad (uv into the atlas)
	Bar,   // meter FILL quad drawn by the dedicated bar pipeline (glossy sheen masked to `value`)
}

Draw_Cmd :: struct {
	kind:  Cmd_Kind,
	rect:  Rect,
	uv:    Rect, // Glyph: atlas uv (x,y = u0,v0; w,h = du,dv)
	color: Color,
	text:  string, // borrowed (Text)
	image: string, // borrowed (Image source name)
	value: f32,    // Bar: fill fraction 0..1 (fed to the bar shader as the sheen mask)
	flip_x: bool,  // Image: sample the texture mirrored horizontally
	slice: [2]f32, // Image: 3-slice cap widths {left,right} in source px (0 = draw as a single quad)
}

// measure computes intrinsic sizes bottom-up so flow containers get a real size before layout: a
// Column with no height sums its children's heights (+ gaps), a Row with no width sums widths, and an
// unsized Text gets the default line height. Without this, a bottom-anchored column has height 0 and
// its pivot can't lift the stack above the anchor — it spills off-screen.
measure :: proc(n: ^Node) {
	for &c in n.children {
		measure(&c)
	}
	#partial switch n.kind {
	case .Text:
		// With a font, a Text/Button measures to its glyph advance + line height (× scale); without
		// one it falls back to the default line height (the legacy single-Text backend). A `wrap` width
		// word-wraps the string into N lines: intrinsic width = widest line, height = N × line height.
		if g_font != nil {
			px := text_px(n)
			_, lh := font.vmetrics(g_font, px)
			if n.wrap > 0 {
				lines := wrap_text(n.text, px, n.wrap)
				if n.size.x == 0 {
					mw: f32
					for ln in lines {
						mw = max(mw, font.measure_text(g_font, ln, px))
					}
					n.size.x = mw
				}
				if n.size.y == 0 {
					n.size.y = lh * f32(max(len(lines), 1))
				}
			} else {
				if n.size.x == 0 {
					n.size.x = font.measure_text(g_font, n.text, px)
				}
				if n.size.y == 0 {
					n.size.y = lh
				}
			}
		} else if n.size.y == 0 {
			n.size.y = LINE_H
		}
	case .Column:
		if n.size.x == 0 { // intrinsic width = widest child + padding (a right-pivot column sits right)
			w: f32
			for &c in n.children {
				w = max(w, c.size.x)
			}
			n.size.x = w + 2 * n.pad
		}
		if n.size.y == 0 {
			total: f32
			for &c in n.children {
				total += c.size.y if c.size.y > 0 else LINE_H
			}
			if len(n.children) > 1 {
				total += n.gap * f32(len(n.children) - 1)
			}
			n.size.y = total + 2 * n.pad
		}
	case .Row:
		if n.size.x == 0 {
			total: f32
			for &c in n.children {
				total += c.size.x if c.size.x > 0 else LINE_H
			}
			if len(n.children) > 1 {
				total += n.gap * f32(len(n.children) - 1)
			}
			n.size.x = total + 2 * n.pad
		}
		if n.size.y == 0 {
			h: f32
			for &c in n.children {
				h = max(h, c.size.y if c.size.y > 0 else LINE_H)
			}
			n.size.y = h + 2 * n.pad
		}
	}
}

// layout computes n.screen from its anchor/stretch against `parent`, then lays out its children.
layout :: proc(n: ^Node, parent: Rect) {
	w := n.size.x
	h := n.size.y
	x, y: f32
	if n.stretch.x {
		x = parent.x + n.offset.x
		w = parent.w - n.offset.x
	} else {
		x = parent.x + parent.w * n.anchor.x + n.offset.x - w * n.pivot.x
	}
	if n.stretch.y {
		y = parent.y + n.offset.y
		h = parent.h - n.offset.y
	} else {
		y = parent.y + parent.h * n.anchor.y + n.offset.y - h * n.pivot.y
	}
	n.screen = Rect{x, y, w, h}
	layout_children(n)
}

// layout_children positions n's children: Column/Row stack them (the parent assigns their rects);
// every other kind anchors each child against n.screen.
layout_children :: proc(n: ^Node) {
	#partial switch n.kind {
	case .Column:
		avail_w := n.screen.w - 2 * n.pad
		cy := n.screen.y + n.pad
		for &c in n.children {
			ch := c.size.y if c.size.y > 0 else LINE_H
			cw := c.size.x if c.size.x > 0 else avail_w
			ax := align_offset(n.align, avail_w, cw) // cross-axis (horizontal) alignment
			c.screen = Rect{n.screen.x + n.pad + ax + c.offset.x, cy + c.offset.y, cw, ch}
			cy += ch + n.gap
			layout_children(&c)
		}
	case .Row:
		avail_h := n.screen.h - 2 * n.pad
		cx := n.screen.x + n.pad
		for &c in n.children {
			cw := c.size.x if c.size.x > 0 else LINE_H
			ch := c.size.y if c.size.y > 0 else avail_h
			ay := align_offset(n.align, avail_h, ch) // cross-axis (vertical) alignment
			c.screen = Rect{cx + c.offset.x, n.screen.y + n.pad + ay + c.offset.y, cw, ch}
			cx += cw + n.gap
			layout_children(&c)
		}
	case:
		for &c in n.children {
			layout(&c, n.screen)
		}
	}
}

// align_offset is the cross-axis shift placing a child of size `sz` within `avail` per `a`.
@(private)
align_offset :: proc(a: Align, avail, sz: f32) -> f32 {
	switch a {
	case .Center:
		return (avail - sz) / 2
	case .End:
		return avail - sz
	case .Start:
	}
	return 0
}

// DISABLED_DIM scales a button's text colour when disabled (greyed out, still readable).
DISABLED_DIM :: f32(0.45)

// emit appends draw commands in tree (painter's) order. Container/Column/Row paint their `color` as
// a background (if opaque) before their children; Text expands to per-glyph atlas quads when a font
// is set (else a single Text command); Image emits a textured quad the backend resolves by name.
// `dim` carries a disabled-state down the tree: a disabled box (e.g. a button widget wrapping its
// label) greys its whole subtree, so the dim applies to the child Text even though the interactive
// node — and thus the `disabled` flag — sits on the wrapper.
emit :: proc(n: ^Node, out: ^[dynamic]Draw_Cmd, dim := false) {
	dim := dim || n.disabled
	is_box := n.kind == .Container || n.kind == .Column || n.kind == .Row
	if is_box && n.color[3] > 0 {
		append(out, Draw_Cmd{kind = .Rect, rect = n.screen, color = n.color})
	}
	#partial switch n.kind {
	case .Rect, .Effect:
		append(out, Draw_Cmd{kind = .Rect, rect = n.screen, color = n.color})
	case .Bar:
		// FILL only — the shader masks the glossy fill to `value` along +x. The track/frame chrome are
		// sibling nodes (Rect/Image) that emit through the normal paths, so the two layers stay separate.
		col := n.color if n.color[3] > 0 else Color{0.78, 0.635, 0.29, 1} // default warm gold fill
		append(out, Draw_Cmd{kind = .Bar, rect = n.screen, color = col, value = clamp(n.value, 0, 1)})
	case .Text:
		col := n.color
		if dim {
			col.rgb *= DISABLED_DIM
		}
		if g_font != nil {
			if n.wrap > 0 {
				emit_text_wrapped(n.text, n.screen, col, text_px(n), n.wrap, out)
			} else {
				emit_text(n.text, n.screen, col, text_px(n), out)
			}
		} else {
			append(out, Draw_Cmd{kind = .Text, rect = n.screen, color = col, text = n.text})
		}
	case .Image:
		// The backend multiplies texel × color, so an UNTINTED image (no color set → {0,0,0,0}) must
		// draw white, or the texture comes out fully transparent. A set color tints/fades it.
		col := n.color if n.color[3] > 0 else Color{1, 1, 1, 1}
		if dim {col.rgb *= DISABLED_DIM}
		append(out, Draw_Cmd{kind = .Image, rect = n.screen, color = col, image = n.image, flip_x = n.flip_x, slice = n.slice})
	}
	for &c in n.children {
		emit(&c, out, dim)
	}
}

// text_scale is a node's glyph scale vs the atlas reference em (0 → 1.0).
@(private)
text_scale :: proc(n: ^Node) -> f32 {
	return n.scale if n.scale > 0 else 1
}

// text_px is the integer pixel size a node's text bakes + draws at: scale × the atlas reference em.
// Rounding to a whole pixel means a given `scale` always maps to one cached, size-matched bake.
@(private)
text_px :: proc(n: ^Node) -> int {
	return int(math.round(text_scale(n) * g_font.ref_em))
}

// emit_text lays a string out as per-glyph atlas quads along the baseline of `area` (top-left origin;
// baseline = top + ascent), left-aligned. Glyphs are baked at `px` (size-matched, no scaling here) and
// SNAPPED to the pixel grid so the atlas samples 1:1 — the crisp, wobble-free path. Whitespace/unknown
// glyphs only advance the pen.
@(private)
emit_text :: proc(s: string, area: Rect, color: Color, px: int, out: ^[dynamic]Draw_Cmd) {
	asc, _ := font.vmetrics(g_font, px)
	pen := area.x
	baseline := math.round(area.y + asc) // whole-pixel baseline (vertical 1:1)
	for r in s {
		m := font.glyph_at(g_font, r, px)
		if m.w > 0 && m.h > 0 {
			gx := math.round(pen + m.bearing_x) // snap each glyph onto the pixel grid (no h-blur)
			gy := baseline - m.bearing_y
			append(
				out,
				Draw_Cmd {
					kind = .Glyph,
					rect = {gx, gy, m.w, m.h},
					uv = {m.u0, m.v0, m.u1 - m.u0, m.v1 - m.v0},
					color = color,
				},
			)
		}
		pen += m.advance
	}
}

// wrap_text greedily word-wraps `s` to lines no wider than `max_w` px (at size `px`), returning
// contiguous sub-slices of `s` (so no content is copied — only the temp-allocated line array). Words
// are maximal non-space runs; the space at each break is dropped (a line runs word-start→word-end),
// inner spaces are kept. A single word wider than `max_w` overflows on its own line (never split).
@(private)
wrap_text :: proc(s: string, px: int, max_w: f32) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	words := make([dynamic][2]int, context.temp_allocator) // [start,end) byte ranges of each word
	i := 0
	for i < len(s) {
		for i < len(s) && s[i] == ' ' {i += 1} // skip spaces
		if i >= len(s) {break}
		start := i
		for i < len(s) && s[i] != ' ' {i += 1}
		append(&words, [2]int{start, i})
	}
	if len(words) == 0 {
		append(&lines, s)
		return lines[:]
	}
	li := 0 // first word on the current line
	for k in 1 ..< len(words) {
		// Would extending the line through word k overflow? (span keeps the inner spaces.)
		if font.measure_text(g_font, s[words[li][0]:words[k][1]], px) > max_w {
			append(&lines, s[words[li][0]:words[k - 1][1]]) // commit up to the previous word
			li = k
		}
	}
	append(&lines, s[words[li][0]:words[len(words) - 1][1]])
	return lines[:]
}

// emit_text_wrapped word-wraps `s` to `max_w` and emits each line stacked by the font line height,
// from the top of `area` (each line left-aligned like emit_text).
@(private)
emit_text_wrapped :: proc(s: string, area: Rect, color: Color, px: int, max_w: f32, out: ^[dynamic]Draw_Cmd) {
	_, lh := font.vmetrics(g_font, px)
	y := area.y
	for ln in wrap_text(s, px, max_w) {
		emit_text(ln, Rect{area.x, y, area.w, lh}, color, px, out)
		y += lh
	}
}

// build sets the root to fill the screen, lays out its children, and rebuilds the draw list.
build :: proc(root: ^Node, screen_w, screen_h: f32, out: ^[dynamic]Draw_Cmd) {
	clear(out)
	measure(root) // auto-size flow containers from their content before positioning
	root.screen = Rect{0, 0, screen_w, screen_h}
	layout_children(root)
	emit(root, out)
}

// destroy frees a node's owned strings + child arrays recursively.
destroy :: proc(n: ^Node) {
	delete(n.text)
	delete(n.image)
	delete(n.id)
	delete(n.action)
	delete(n.bind)
	for &c in n.children {
		destroy(&c)
	}
	delete(n.children)
}

// ── interaction (the app drives input against the laid-out tree) ───────────────────────────────

// Focusable is one activatable node (a button) — its action, hit rect, and state — collected in
// tree order for keyboard navigation + mouse hit-testing.
Focusable :: struct {
	action:   string, // borrowed from the node
	id:       string, // borrowed
	rect:     Rect,
	disabled: bool,
}

// collect_focusables appends every node carrying an `action` (in tree order) to `out`. Call after
// build (rects must be laid out). Disabled buttons are included so the app can skip/grey them.
collect_focusables :: proc(n: ^Node, out: ^[dynamic]Focusable) {
	if len(n.action) > 0 {
		append(out, Focusable{action = n.action, id = n.id, rect = n.screen, disabled = n.disabled})
	}
	for &c in n.children {
		collect_focusables(&c, out)
	}
}

// topmost_modal returns the last (topmost-painted) node in the tree that captures input (`modal`),
// or nil. The engine routes input only within this subtree when one exists — so a confirm dialog
// grabs focus while a passive toast/level-up transient (modal = false) leaves the base interactive.
topmost_modal :: proc(n: ^Node) -> ^Node {
	result: ^Node
	if n.modal {
		result = n
	}
	for &c in n.children {
		if r := topmost_modal(&c); r != nil {
			result = r
		}
	}
	return result
}

// focus_root returns the subtree the engine should route input to: the topmost modal node if any,
// else the whole tree.
focus_root :: proc(root: ^Node) -> ^Node {
	if m := topmost_modal(root); m != nil {
		return m
	}
	return root
}

contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

// find_by_id returns a pointer to the first node with the given id (depth-first), or nil.
find_by_id :: proc(n: ^Node, id: string) -> ^Node {
	if n.id == id {
		return n
	}
	for &c in n.children {
		if r := find_by_id(&c, id); r != nil {
			return r
		}
	}
	return nil
}

// resolve_binds walks the tree and, for every node with a `bind` path, sets `disabled` from the
// resolver (a bound `enabled` that resolves false greys the button). The resolver maps a path to a
// truthiness; unknown paths should return false so gated buttons stay disabled until proven enabled.
resolve_binds :: proc(n: ^Node, resolver: proc(path: string) -> bool) {
	if len(n.bind) > 0 {
		n.disabled = !resolver(n.bind)
	}
	for &c in n.children {
		resolve_binds(&c, resolver)
	}
}
