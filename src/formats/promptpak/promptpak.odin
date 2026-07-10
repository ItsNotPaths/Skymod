package promptpak

// The baked button-prompt pack: one QOI-compressed RGBA atlas + a name → cell directory.
// Written at build time by tools/promptbake (from the CC0 Kenney "Input Prompts" art in
// vendor/), #load'd + parsed at runtime by src/prompts. A pure format package (no engine
// deps) so the writer (the tool) and the reader (the engine) share one definition and the
// round-trip is unit-testable without any baked art.
//
// Layout (little-endian, packed):
//   u32 magic "SMPR"   u32 version
//   u32 atlas_w        u32 atlas_h
//   u32 count          u32 qoi_len
//   count × { u16 name_len, name bytes, u16 x, u16 y, u16 w, u16 h }
//   qoi_len bytes of QOI (the RGBA8 atlas)
//
// Names are pack keys like "xbox/xbox_button_color_a" — `<set-slug>/<kenney basename>`.

import "core:encoding/endian"

MAGIC :: u32(0x52504D53) // "SMPR"
VERSION :: u32(1)

Entry :: struct {
	name:       string, // borrows the pak buffer
	x, y, w, h: u16,    // cell in atlas pixels
}

Pak :: struct {
	atlas_w, atlas_h: int,
	entries:          []Entry, // allocated; names borrow the parsed buffer
	qoi:              []u8,    // borrows the parsed buffer
}

// parse reads a pak image. Entry names + qoi bytes BORROW `data` (fine for a #load'd
// buffer); only the entries slice allocates. ok=false on any malformed/truncated input.
parse :: proc(data: []u8, allocator := context.allocator) -> (p: Pak, ok: bool) {
	pos := 0
	u16le :: proc(d: []u8, pos: ^int) -> (u16, bool) {
		v, vok := endian.get_u16(d[pos^:], .Little)
		if vok {pos^ += 2}
		return v, vok
	}
	u32le :: proc(d: []u8, pos: ^int) -> (u32, bool) {
		v, vok := endian.get_u32(d[pos^:], .Little)
		if vok {pos^ += 4}
		return v, vok
	}

	magic := u32le(data, &pos) or_return
	version := u32le(data, &pos) or_return
	if magic != MAGIC || version != VERSION {
		return
	}
	aw := u32le(data, &pos) or_return
	ah := u32le(data, &pos) or_return
	count := u32le(data, &pos) or_return
	qoi_len := u32le(data, &pos) or_return

	entries := make([]Entry, int(count), allocator)
	for i in 0 ..< int(count) {
		nlen := int(u16le(data, &pos) or_return)
		if pos + nlen > len(data) {
			delete(entries, allocator)
			return
		}
		name := string(data[pos:pos + nlen])
		pos += nlen
		x := u16le(data, &pos) or_return
		y := u16le(data, &pos) or_return
		w := u16le(data, &pos) or_return
		h := u16le(data, &pos) or_return
		entries[i] = Entry{name = name, x = x, y = y, w = w, h = h}
	}
	if pos + int(qoi_len) > len(data) {
		delete(entries, allocator)
		return
	}
	p = Pak {
		atlas_w = int(aw),
		atlas_h = int(ah),
		entries = entries,
		qoi     = data[pos:pos + int(qoi_len)],
	}
	return p, true
}

destroy :: proc(p: ^Pak, allocator := context.allocator) {
	delete(p.entries, allocator)
	p^ = {}
}

// write serializes a pak image (the tool side of parse). The caller owns the result.
write :: proc(atlas_w, atlas_h: int, entries: []Entry, qoi: []u8, allocator := context.allocator) -> []u8 {
	size := 6 * 4
	for e in entries {
		size += 2 + len(e.name) + 4 * 2
	}
	size += len(qoi)
	out := make([dynamic]u8, 0, size, allocator)

	put16 :: proc(out: ^[dynamic]u8, v: u16) {
		b: [2]u8
		endian.put_u16(b[:], .Little, v)
		append(out, ..b[:])
	}
	put32 :: proc(out: ^[dynamic]u8, v: u32) {
		b: [4]u8
		endian.put_u32(b[:], .Little, v)
		append(out, ..b[:])
	}

	put32(&out, MAGIC)
	put32(&out, VERSION)
	put32(&out, u32(atlas_w))
	put32(&out, u32(atlas_h))
	put32(&out, u32(len(entries)))
	put32(&out, u32(len(qoi)))
	for e in entries {
		put16(&out, u16(len(e.name)))
		append(&out, ..transmute([]u8)e.name)
		put16(&out, e.x)
		put16(&out, e.y)
		put16(&out, e.w)
		put16(&out, e.h)
	}
	append(&out, ..qoi)
	return out[:]
}
