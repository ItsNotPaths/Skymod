package main

// The imgui-DrawList backend for the UI substrate (backend v1): renders the `ui` package's
// backend-agnostic draw commands by emitting into imgui's foreground draw list, reusing imgui's
// font atlas + the existing SDL_gpu render path. Backend v2 (own SDL3_gpu pipeline + extracted
// Skyrim fonts) will replace this without touching the `ui` tree. Call between ui_new_frame and
// the frame's imgui Render.

import "core:fmt"
import imgui "../../vendor/odin-imgui"
import "../ui"

// ui_render_imgui draws `cmds` into imgui's foreground draw list (drawn on top of everything).
ui_render_imgui :: proc(cmds: []ui.Draw_Cmd) {
	dl := imgui.GetForegroundDrawList()
	for c in cmds {
		p_min := imgui.Vec2{c.rect.x, c.rect.y}
		p_max := imgui.Vec2{c.rect.x + c.rect.w, c.rect.y + c.rect.h}
		col := ui_pack_color(c.color)
		switch c.kind {
		case .Rect:
			imgui.DrawList_AddRectFilled(dl, p_min, p_max, col)
		case .Image:
			// Texture wiring is v2; draw a visible placeholder slot (grey fill + border) for now.
			fill := col if c.color[3] > 0 else ui_pack_color({0.30, 0.30, 0.34, 1})
			imgui.DrawList_AddRectFilled(dl, p_min, p_max, fill)
			imgui.DrawList_AddRect(dl, p_min, p_max, ui_pack_color({0.55, 0.55, 0.60, 1}))
		case .Text:
			imgui.DrawList_AddText(dl, p_min, col, fmt.ctprintf("%s", c.text))
		case .Glyph:
			// Font-atlas glyph quads are the v2 (SDL3_gpu) backend's job; the imgui DrawList
			// backend (no atlas) only ever receives .Text. Nothing to draw here.
		}
	}
}

// ui_screen_size returns the current display size (the UI substrate's root rect). DisplaySize is
// the framebuffer size the imgui backend sets each frame (== the main viewport Size); the viewport
// WorkSize is a work-area inset that isn't populated here, so it must not be used for layout.
ui_screen_size :: proc() -> (w, h: f32) {
	io := imgui.GetIO()
	return io.DisplaySize.x, io.DisplaySize.y
}

// ui_pack_color packs an rgba (0..1) color into imgui's ImU32 (0xAABBGGRR).
ui_pack_color :: proc(c: ui.Color) -> u32 {
	r := u32(clamp(c[0], 0, 1) * 255)
	g := u32(clamp(c[1], 0, 1) * 255)
	b := u32(clamp(c[2], 0, 1) * 255)
	a := u32(clamp(c[3], 0, 1) * 255)
	return (a << 24) | (b << 16) | (g << 8) | r
}
