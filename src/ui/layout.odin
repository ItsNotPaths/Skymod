package ui

// The Lua data file engine.layout returns for a vanilla SWF: where its named instances and its
// extracted art sit on the stage, in px. baseui writes it at install time.

import "core:fmt"
import "core:strings"
import "../formats/swf"

// Art_Rect is an art file drawn from an instance, and the stage rect it covers.
Art_Rect :: struct {
	dest: string,
	rect: swf.Rect,
}

// layout_source is the file's Lua: { stage = {w, h}, art = { [dest] = rect }, instances = { [path] =
// { rect, moving = { [label] = rect } } } }, each rect { x, y, w, h }.
layout_source :: proc(mv: ^swf.Movie, source: string, art: []Art_Rect, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	fmt.sbprintfln(&b, "-- Generated from %s: where its named instances sit on the stage, in px.", source)
	fmt.sbprintln(&b, "return {")
	fmt.sbprintfln(&b, "  stage = {{ w = %.0f, h = %.0f }},", (mv.stage.x1 - mv.stage.x0) / 20, (mv.stage.y1 - mv.stage.y0) / 20)
	fmt.sbprintln(&b, "  art = {")
	for a in art {
		fmt.sbprintfln(&b, "    [%q] = %s,", a.dest, lua_rect(a.rect))
	}
	fmt.sbprintln(&b, "  },")
	fmt.sbprintln(&b, "  instances = {")
	for e in swf.layout(mv, context.temp_allocator) {
		if swf.rect_empty(e.rect) {continue}
		fmt.sbprintf(&b, "    [%q] = {{ rect = %s", e.path, lua_rect(e.rect))
		if len(e.moving) > 0 {
			fmt.sbprint(&b, ", moving = {")
			for m in e.moving {
				if !swf.rect_empty(m.rect) {fmt.sbprintf(&b, " [%q] = %s,", m.label, lua_rect(m.rect))}
			}
			fmt.sbprint(&b, " }")
		}
		fmt.sbprintln(&b, " },")
	}
	fmt.sbprintln(&b, "  },")
	fmt.sbprintln(&b, "}")
	return strings.to_string(b)
}

@(private = "file")
lua_rect :: proc(r: swf.Rect) -> string {
	return fmt.tprintf("{{ x = %.2f, y = %.2f, w = %.2f, h = %.2f }}", r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0)
}
