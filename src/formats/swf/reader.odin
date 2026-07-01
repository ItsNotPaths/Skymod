package swf

// Byte + bit reader for the SWF tag/shape streams. Byte reads assume byte-alignment (tags, tables,
// and each glyph start are byte-aligned); bit reads drive the shape parser.

import "base:runtime"

Allocator :: runtime.Allocator

Reader :: struct {
	b:        []u8,
	byte_pos: int,
	bit_pos:  int,
}

@(private)
r_u8 :: proc(r: ^Reader) -> u8 {
	if r.byte_pos >= len(r.b) {
		return 0
	}
	v := r.b[r.byte_pos]
	r.byte_pos += 1
	return v
}

@(private)
r_u16 :: proc(r: ^Reader) -> u16 {
	lo := u16(r_u8(r))
	hi := u16(r_u8(r))
	return lo | hi << 8
}

@(private)
r_u32 :: proc(r: ^Reader) -> u32 {
	b0 := u32(r_u8(r))
	b1 := u32(r_u8(r))
	b2 := u32(r_u8(r))
	b3 := u32(r_u8(r))
	return b0 | b1 << 8 | b2 << 16 | b3 << 24
}

@(private)
r_s16 :: proc(r: ^Reader) -> i16 {
	return i16(r_u16(r))
}

// r_ubits reads n bits big-endian-within-bytes (the SWF bit order).
@(private)
r_ubits :: proc(r: ^Reader, n: int) -> u32 {
	v: u32
	for _ in 0 ..< n {
		v <<= 1
		if r.byte_pos < len(r.b) {
			v |= u32((r.b[r.byte_pos] >> uint(7 - r.bit_pos)) & 1)
		}
		r.bit_pos += 1
		if r.bit_pos == 8 {
			r.bit_pos = 0
			r.byte_pos += 1
		}
	}
	return v
}

// r_sbits reads an n-bit two's-complement signed value.
@(private)
r_sbits :: proc(r: ^Reader, n: int) -> i32 {
	v := r_ubits(r, n)
	if n > 0 && (v & (1 << uint(n - 1))) != 0 {
		v |= ~u32(0) << uint(n) // sign-extend
	}
	return i32(v)
}

// u16le / u32le read little-endian integers out of a byte slice (tag headers).
@(private)
u16le :: proc(b: []u8, o: int) -> u16 {
	return u16(b[o]) | u16(b[o + 1]) << 8
}

@(private)
u32le :: proc(b: []u8, o: int) -> u32 {
	return u32(b[o]) | u32(b[o + 1]) << 8 | u32(b[o + 2]) << 16 | u32(b[o + 3]) << 24
}
