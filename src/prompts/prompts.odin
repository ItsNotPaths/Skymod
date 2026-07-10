package prompts

// The baked button-prompt glyph set: Kenney "Input Prompts" 1.5 (CC0), every device set —
// keyboard/mouse, Xbox, PlayStation, Switch (1/2), Steam Deck/Controller/Frame, GameCube,
// Wii/WiiU, Playdate, Quest, Index, Touch, generic sticks/wheels — packed into one QOI
// atlas + name→cell directory at build time (build/bake_prompts.sh → prompts.pak) and
// #load'd here, like the shaders. Keys are "<set-slug>/<kenney basename>", e.g.
// "kbm/keyboard_f", "xbox/xbox_button_color_a" (the input package maps Codes to keys;
// Lua can also reference ANY glyph directly via image{source="prompts/<key>"}).
//
// A leaf package: no renderer/UI deps. The app decodes once, uploads, and frees — this
// package only parses the container and hands out cells. With the stub pak (no vendored
// art) every lookup misses and callers fall back to text hints.

import "core:image"
import "core:image/qoi"
import "../formats/promptpak"

PAK :: #load("prompts.pak")

Rect :: struct {
	x, y, w, h: int, // atlas pixels
}

// dir builds the name → cell directory (map keys borrow the embedded pak — never freed,
// it's static) and reports the atlas dimensions. ok=false on a corrupt pak.
dir :: proc(allocator := context.allocator) -> (m: map[string]Rect, atlas_w, atlas_h: int, ok: bool) {
	p, pok := promptpak.parse(PAK, context.temp_allocator)
	if !pok {
		return
	}
	m = make(map[string]Rect, len(p.entries), allocator)
	for e in p.entries {
		m[e.name] = Rect{int(e.x), int(e.y), int(e.w), int(e.h)}
	}
	return m, p.atlas_w, p.atlas_h, true
}

// atlas decodes the QOI atlas to RGBA8 (an ^image.Image the caller destroys with
// `destroy_atlas` once uploaded). ok=false on a corrupt pak/QOI stream.
atlas :: proc(allocator := context.allocator) -> (img: ^image.Image, ok: bool) {
	context.allocator = allocator // qoi.destroy frees via context — keep alloc/free paired
	p, pok := promptpak.parse(PAK, context.temp_allocator)
	if !pok {
		return
	}
	decoded, err := qoi.load_from_bytes(p.qoi, allocator = allocator)
	if err != nil || decoded.channels != 4 || decoded.depth != 8 {
		if decoded != nil {qoi.destroy(decoded)}
		return
	}
	return decoded, true
}

destroy_atlas :: proc(img: ^image.Image) {
	qoi.destroy(img)
}
