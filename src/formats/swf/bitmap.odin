package swf

// DefineBitsLossless2 extraction — pulls a NAMED bitmap (an ExportAssets symbol, e.g. "SkyrimLogo")
// out of a Scaleform SWF as straight RGBA, for the install-time UI-asset extraction (→ DDS in
// content/baseui/bethassets). Handles the two formats Scaleform uses: 8-bit palette (3) and 32-bit
// ARGB (5). Both store RGB PREMULTIPLIED by alpha; we un-premultiply to straight RGBA (our UI shader
// samples straight alpha). Sibling to the font-glyph path; reuses swf_body (zlib) + the tag walk.

import "core:bytes"
import "core:compress/zlib"

// Bitmap is a decoded image: straight (un-premultiplied) RGBA, top-down rows, w*h*4 bytes.
Bitmap :: struct {
	w, h: int,
	rgba: []u8,
}

// extract_bitmap decodes the DefineBitsLossless2 bitmap exported as `name`. ok=false if the symbol /
// bitmap isn't found or the format is unsupported. `rgba` is owned by `allocator`.
extract_bitmap :: proc(file: []u8, name: string, allocator := context.allocator) -> (bmp: Bitmap, ok: bool) {
	body, bok := swf_body(file, context.temp_allocator)
	if !bok || len(body) < 1 {
		return {}, false
	}
	nbits := int(body[0] >> 3)
	pos := (5 + 4 * nbits + 7) / 8 + 4 // past frame-size RECT + framerate(2) + framecount(2)

	// Exports and bitmap tags can appear in any order, so collect both, then resolve name → id → tag.
	want_id := -1
	losses := make(map[u16][]u8, 16, context.temp_allocator)
	for pos + 2 <= len(body) {
		tc := int(u16le(body, pos));pos += 2
		code := tc >> 6
		length := tc & 0x3f
		if length == 0x3f {
			if pos + 4 > len(body) {break}
			length = int(u32le(body, pos));pos += 4
		}
		if pos + length > len(body) {break}
		tb := body[pos:pos + length]
		switch code {
		case 56: // ExportAssets: count u16, then (id u16, name cstr) pairs
			if len(tb) >= 2 {
				cnt := int(u16le(tb, 0));o := 2
				for _ in 0 ..< cnt {
					if o + 2 > len(tb) {break}
					id := u16le(tb, o);o += 2
					nm, no := cstr(tb, o);o = no
					if nm == name {want_id = int(id)}
				}
			}
		case 36: // DefineBitsLossless2
			if len(tb) >= 7 {
				losses[u16le(tb, 0)] = tb
			}
		}
		pos += length
		if code == 0 {break}
	}
	if want_id < 0 {
		return {}, false
	}
	tb, found := losses[u16(want_id)]
	if !found {
		return {}, false
	}
	return decode_lossless2(tb, allocator)
}

// Named_Bitmap pairs a decoded bitmap with its SWF character id (for the dump-all extraction).
Named_Bitmap :: struct {
	id:  u16,
	bmp: Bitmap,
}

// extract_all_bitmaps decodes EVERY DefineBitsLossless2 in the SWF (by character id), for the
// browse-and-pick asset dump. Each bmp's rgba is owned by `allocator`.
extract_all_bitmaps :: proc(file: []u8, allocator := context.allocator) -> []Named_Bitmap {
	body, bok := swf_body(file, context.temp_allocator)
	if !bok || len(body) < 1 {
		return {}
	}
	nbits := int(body[0] >> 3)
	pos := (5 + 4 * nbits + 7) / 8 + 4
	out := make([dynamic]Named_Bitmap, allocator)
	for pos + 2 <= len(body) {
		tc := int(u16le(body, pos));pos += 2
		code := tc >> 6
		length := tc & 0x3f
		if length == 0x3f {
			if pos + 4 > len(body) {break}
			length = int(u32le(body, pos));pos += 4
		}
		if pos + length > len(body) {break}
		if code == 36 && length >= 7 {
			tb := body[pos:pos + length]
			if bmp, ok := decode_lossless2(tb, allocator); ok {
				append(&out, Named_Bitmap{u16le(tb, 0), bmp})
			}
		}
		pos += length
		if code == 0 {break}
	}
	return out[:]
}

@(private)
decode_lossless2 :: proc(tb: []u8, allocator: Allocator) -> (Bitmap, bool) {
	format := tb[2]
	w := int(u16le(tb, 3))
	h := int(u16le(tb, 5))
	if w <= 0 || h <= 0 {
		return {}, false
	}
	o := 7
	ncol := 0
	if format == 3 {
		if len(tb) < 8 {return {}, false}
		ncol = int(tb[7]) + 1 // BitmapColorTableSize is count-1
		o = 8
	}
	stride := (w + 3) &~ 3 // indexed rows pad to a 32-bit boundary
	expected := 0
	switch format {
	case 5:
		expected = w * h * 4
	case 3:
		expected = ncol * 4 + stride * h
	case:
		return {}, false // 15-bit (4) or unknown — add if a UI asset needs it
	}

	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := zlib.inflate(tb[o:], &buf, false, expected); err != nil {
		return {}, false
	}
	raw := buf.buf[:]

	out := make([]u8, w * h * 4, allocator)
	switch format {
	case 5: // ARGB, premultiplied, no row padding
		if len(raw) < w * h * 4 {return {}, false}
		for i in 0 ..< w * h {
			a := raw[i * 4]
			out[i * 4 + 0] = unpremul(raw[i * 4 + 1], a)
			out[i * 4 + 1] = unpremul(raw[i * 4 + 2], a)
			out[i * 4 + 2] = unpremul(raw[i * 4 + 3], a)
			out[i * 4 + 3] = a
		}
	case 3: // palette (RGBA, premultiplied) + indexed pixels
		if len(raw) < ncol * 4 + stride * h {return {}, false}
		pal := raw[:ncol * 4]
		pix := raw[ncol * 4:]
		for y in 0 ..< h {
			for x in 0 ..< w {
				idx := int(pix[y * stride + x])
				if idx >= ncol {idx = 0}
				a := pal[idx * 4 + 3]
				oi := (y * w + x) * 4
				out[oi + 0] = unpremul(pal[idx * 4 + 0], a)
				out[oi + 1] = unpremul(pal[idx * 4 + 1], a)
				out[oi + 2] = unpremul(pal[idx * 4 + 2], a)
				out[oi + 3] = a
			}
		}
	}
	return Bitmap{w, h, out}, true
}

// unpremul recovers a straight channel from a premultiplied one: c_straight = c·255/a (clamped).
@(private)
unpremul :: proc(c, a: u8) -> u8 {
	if a == 0 {
		return 0
	}
	v := int(c) * 255 / int(a)
	return u8(min(v, 255))
}

@(private)
cstr :: proc(b: []u8, o: int) -> (string, int) {
	end := o
	for end < len(b) && b[end] != 0 {
		end += 1
	}
	return string(b[o:end]), min(end + 1, len(b))
}
