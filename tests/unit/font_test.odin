package unit_tests

// Font rasterizer + atlas regression guard. Hermetic + SYNTHETIC: hand-builds a tiny swf.Font with
// two glyphs — a solid square 'A' and a hollow square 'O' (an outer contour + an opposite-wound
// inner contour) — then rasterizes and checks (a) the atlas packs both with valid UVs, (b) the
// solid glyph fills its centre, (c) the hollow glyph's centre is EMPTY (non-zero winding leaves the
// hole), and (d) measure_text sums advances. Real font correctness is the swfdump/visual pass over
// the install; this only proves the fill rule + packing are wired right.

import "core:testing"
import "../../src/font"
import "../../src/formats/swf"

@(test)
test_font_rasterize :: proc(t: ^testing.T) {
	// em = 1000 units; a 800-unit square glyph rasterized at px=40 → ~32px box.
	square := []swf.Seg {
		{kind = .Move, x = 100, y = 100},
		{kind = .Line, x = 900, y = 100},
		{kind = .Line, x = 900, y = 900},
		{kind = .Line, x = 100, y = 900},
		{kind = .Line, x = 100, y = 100},
	}
	// 'O': outer CCW square + inner CW square (the hole) — winding cancels in the centre.
	hollow := []swf.Seg {
		{kind = .Move, x = 100, y = 100},
		{kind = .Line, x = 900, y = 100},
		{kind = .Line, x = 900, y = 900},
		{kind = .Line, x = 100, y = 900},
		{kind = .Line, x = 100, y = 100},
		{kind = .Move, x = 350, y = 350},
		{kind = .Line, x = 350, y = 650}, // reverse winding
		{kind = .Line, x = 650, y = 650},
		{kind = .Line, x = 650, y = 350},
		{kind = .Line, x = 350, y = 350},
	}
	f := swf.Font {
		em      = 1000,
		ascent  = 900,
		descent = 100,
		leading = 0,
		glyphs  = []swf.Glyph {
			{code = 'A', advance = 1000, segs = square},
			{code = 'O', advance = 1000, segs = hollow},
			{code = ' ', advance = 500, segs = nil},
		},
	}

	PX :: 40
	a := font.make_atlas(f, 40) // ref em is irrelevant here — glyphs are requested at PX directly
	defer font.destroy(&a)

	testing.expect(t, a.w > 0 && a.h > 0, "atlas has size")
	testing.expect(t, len(a.pixels) == a.w * a.h * 4, "pixel buffer sized")

	ga := font.glyph_at(&a, 'A', PX) // lazily bakes 'A' at 40px
	go := font.glyph_at(&a, 'O', PX)
	testing.expect(t, ga.w > 0, "A baked a bitmap")
	testing.expect(t, go.w > 0, "O baked a bitmap")
	testing.expect(t, ga.w > 20 && ga.w < 40, "A is ~32px wide")
	testing.expect(t, ga.u1 > ga.u0 && ga.v1 > ga.v0, "A has a valid UV rect")

	// Solid 'A' centre is opaque; hollow 'O' centre is transparent.
	testing.expect(t, alpha_at(&a, ga, 0.5, 0.5) > 200, "solid glyph centre filled")
	testing.expect(t, alpha_at(&a, ga, 0.5, 0.05) > 100, "solid glyph near-top filled")
	testing.expect(t, alpha_at(&a, go, 0.5, 0.5) < 40, "hollow glyph centre empty")
	testing.expect(t, alpha_at(&a, go, 0.5, 0.07) > 100, "hollow glyph rim filled")

	testing.expect_value(t, font.measure_text(&a, "AA", PX), ga.advance * 2)
	testing.expect(t, font.measure_text(&a, " ", PX) > 0, "space has advance")
}

// test_font_orientation guards the glyph Y orientation (the symmetric glyphs above can't — a vertical
// flip leaves a square/ring unchanged). A right triangle filled toward (small-x, small-y) must land
// in the atlas cell's TOP-LEFT, since SWF glyph Y is down (small Y = top) and the atlas is Y-down.
// If the rasterizer flips Y (the upside-down-text bug), the fill lands bottom-left and this fails.
@(test)
test_font_orientation :: proc(t: ^testing.T) {
	tri := []swf.Seg {
		{kind = .Move, x = 100, y = 100},
		{kind = .Line, x = 900, y = 100},
		{kind = .Line, x = 100, y = 900},
		{kind = .Line, x = 100, y = 100},
	}
	f := swf.Font {
		em      = 1000,
		ascent  = 900,
		descent = 100,
		glyphs  = []swf.Glyph{{code = 'F', advance = 1000, segs = tri}},
	}
	a := font.make_atlas(f, 40)
	defer font.destroy(&a)

	g := font.glyph_at(&a, 'F', 40)
	testing.expect(t, g.w > 0, "glyph baked")
	testing.expect(t, alpha_at(&a, g, 0.12, 0.12) > 180, "fill is in the TOP-LEFT (small x, small y)")
	testing.expect(t, alpha_at(&a, g, 0.88, 0.88) < 40, "bottom-right is empty")
}

// alpha_at samples the atlas alpha at a fractional (u,v) within glyph `g`'s bitmap cell (0..1).
alpha_at :: proc(a: ^font.Atlas, g: font.Glyph_Metric, u, v: f32) -> u8 {
	gx := int(g.u0 * f32(a.w))
	gy := int(g.v0 * f32(a.h))
	px := gx + int(u * g.w)
	py := gy + int(v * g.h)
	px = clamp(px, 0, a.w - 1)
	py = clamp(py, 0, a.h - 1)
	return a.pixels[(py * a.w + px) * 4 + 3]
}
