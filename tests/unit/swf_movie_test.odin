package unit_tests

// formats/swf movie model: a clip layer masks the depths under it when drawing and measuring, and
// the layout gives the box of a sprite's animated children at each label.

import "core:testing"
import "../../src/formats/swf"

// box_shape is a filled w×h px rectangle at (x, y) px, in twips.
@(private = "file")
box_shape :: proc(x, y, w, h: f32, color: [4]u8) -> swf.Shape_Def {
	x0, y0, x1, y1 := x * 20, y * 20, (x + w) * 20, (y + h) * 20
	edges := make([]swf.Edge, 4, context.temp_allocator)
	edges[0] = {fill1 = 1, x0 = x0, y0 = y0, x1 = x1, y1 = y0}
	edges[1] = {fill1 = 1, x0 = x1, y0 = y0, x1 = x1, y1 = y1}
	edges[2] = {fill1 = 1, x0 = x1, y0 = y1, x1 = x0, y1 = y1}
	edges[3] = {fill1 = 1, x0 = x0, y0 = y1, x1 = x0, y1 = y0}
	fills := make([]swf.Fill, 1, context.temp_allocator)
	fills[0] = {kind = .Solid, color = color}
	return {bounds = {x0, y0, x1, y1}, fills = fills, edges = edges}
}

@(private = "file")
at :: proc(x, y: f32) -> swf.Matrix {
	return {1, 0, 0, 1, x * 20, y * 20}
}

// A meter: a 10x10 mask (depth 1, clips depth 2) over a 10x10 red fill (depth 2) that slides 10 px
// left between "Full" and "Empty". It sits on the root as "Meter" at (100, 50).
@(private = "file")
meter_movie :: proc() -> swf.Movie {
	mv := swf.Movie{chars = make(map[u16]swf.Character, allocator = context.temp_allocator)}
	mv.chars[1] = box_shape(0, 0, 10, 10, {255, 255, 255, 255}) // mask
	mv.chars[2] = box_shape(0, 0, 10, 10, {255, 0, 0, 255}) // fill
	full := make([]swf.Place, 2, context.temp_allocator)
	full[0] = {depth = 1, id = 1, mat = swf.IDENTITY, cx = swf.CX_IDENTITY, clip = 2}
	full[1] = {depth = 2, id = 2, mat = swf.IDENTITY, cx = swf.CX_IDENTITY}
	empty := make([]swf.Place, 2, context.temp_allocator)
	empty[0] = full[0]
	empty[1] = {depth = 2, id = 2, mat = at(-10, 0), cx = swf.CX_IDENTITY}
	frames := make([][]swf.Place, 2, context.temp_allocator)
	frames[0], frames[1] = full, empty
	labels := make(map[string]int, allocator = context.temp_allocator)
	labels["Full"], labels["Empty"] = 0, 1
	mv.chars[3] = swf.Sprite{frames = frames, labels = labels}
	root := make([][]swf.Place, 1, context.temp_allocator)
	root[0] = make([]swf.Place, 1, context.temp_allocator)
	root[0][0] = {depth = 1, id = 3, name = "Meter", mat = at(100, 50), cx = swf.CX_IDENTITY}
	mv.root = {frames = root}
	return mv
}

@(test)
test_swf_clip_masks_draw :: proc(t: ^testing.T) {
	mv := meter_movie()
	full, ok := swf.render_instance(&mv, "Meter", "Full", 1, nil, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, full.w, 12) // 10 px and a 1 px margin each side
	centre := (full.h / 2 * full.w + full.w / 2) * 4
	testing.expect_value(t, full.rgba[centre], 255) // red inside the mask
	testing.expect_value(t, full.rgba[centre + 3], 255)

	// At "Empty" the fill slid out from under the mask: nothing shows, and nothing is measured.
	_, drawn := swf.render_instance(&mv, "Meter", "Empty", 1, nil, context.temp_allocator)
	testing.expect(t, !drawn)
}

@(test)
test_swf_layout_moving_box :: proc(t: ^testing.T) {
	mv := meter_movie()
	entries := swf.layout(&mv, context.temp_allocator)
	testing.expect_value(t, len(entries), 1)
	if len(entries) != 1 {return}
	e := entries[0]
	testing.expect_value(t, e.path, "Meter")
	testing.expect_value(t, e.rect, swf.Rect{100, 50, 110, 60})
	testing.expect_value(t, len(e.moving), 2)
	for m in e.moving {
		switch m.label {
		case "Full":  testing.expect_value(t, m.rect, swf.Rect{100, 50, 110, 60})
		case "Empty": testing.expect_value(t, m.rect, swf.Rect{90, 50, 100, 60}) // slid left
		}
	}
}
