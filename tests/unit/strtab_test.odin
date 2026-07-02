package unit_tests

// Localized string-table (STRINGS family) reader tests. Hermetic + SYNTHETIC: a
// hand-built blob (header + directory + data block), no game files. Guards the two
// on-disk encodings — Plain (.STRINGS, NUL-terminated) and Lengthed (.DL/.ILSTRINGS,
// u32-length-prefixed) — plus offset resolution and out-of-range tolerance.

import "core:encoding/endian"
import "core:testing"
import strtab "../../src/formats/strings"

@(test)
test_strtab_plain :: proc(t: ^testing.T) {
	// data block: "Iron Sword\0Health Potion\0" — sid 1 at offset 0, sid 2 at offset 11.
	block: [dynamic]u8;defer delete(block)
	append(&block, ..transmute([]u8)string("Iron Sword\x00"))
	off2 := len(block)
	append(&block, ..transmute([]u8)string("Health Potion\x00"))

	data := build_strings({{1, 0}, {2, u32(off2)}}, block[:])
	defer delete(data)

	tbl, ok := strtab.parse(data, .Plain)
	testing.expect(t, ok, "parse .STRINGS")
	defer strtab.destroy(&tbl)
	testing.expect_value(t, len(tbl), 2)
	testing.expect_value(t, strtab.lookup(tbl, 1), "Iron Sword")
	testing.expect_value(t, strtab.lookup(tbl, 2), "Health Potion")
	testing.expect_value(t, strtab.lookup(tbl, 999), "") // absent id
}

@(test)
test_strtab_lengthed :: proc(t: ^testing.T) {
	// Lengthed: each entry is len:u32 (INCLUDING the NUL) then the bytes.
	block: [dynamic]u8;defer delete(block)
	put32(&block, 6) // "Hello\0" is 6 bytes
	append(&block, ..transmute([]u8)string("Hello\x00"))
	off2 := len(block)
	put32(&block, 3)
	append(&block, ..transmute([]u8)string("Hi\x00"))

	data := build_strings({{10, 0}, {20, u32(off2)}}, block[:])
	defer delete(data)

	tbl, ok := strtab.parse(data, .Lengthed)
	testing.expect(t, ok, "parse .DLSTRINGS")
	defer strtab.destroy(&tbl)
	testing.expect_value(t, strtab.lookup(tbl, 10), "Hello")
	testing.expect_value(t, strtab.lookup(tbl, 20), "Hi")
}

@(test)
test_strtab_bad_offset_skipped :: proc(t: ^testing.T) {
	// A directory entry whose offset runs past the data block is skipped, not fatal — the
	// valid entries still resolve.
	block: [dynamic]u8;defer delete(block)
	append(&block, ..transmute([]u8)string("Ok\x00"))

	data := build_strings({{1, 0}, {2, 9999}}, block[:])
	defer delete(data)

	tbl, ok := strtab.parse(data, .Plain)
	testing.expect(t, ok, "parse tolerates a bad offset")
	defer strtab.destroy(&tbl)
	testing.expect_value(t, strtab.lookup(tbl, 1), "Ok")
	testing.expect_value(t, len(tbl), 1) // the out-of-range entry dropped
}

@(test)
test_strtab_truncated :: proc(t: ^testing.T) {
	tbl, ok := strtab.parse({0, 1, 2}, .Plain) // < 8 bytes → no header
	testing.expect(t, !ok, "truncated header rejected")
	_ = tbl
}

// --- synthetic blob builder ---

// build_strings assembles a STRINGS-family file: header (count, dataSize), the directory
// of {stringID, offset} entries, then the data block. Caller frees the returned slice.
@(private = "file")
build_strings :: proc(dir: [][2]u32, block: []u8) -> []u8 {
	out: [dynamic]u8
	put32(&out, u32(len(dir))) // count
	put32(&out, u32(len(block))) // dataSize
	for e in dir {
		put32(&out, e[0]) // stringID
		put32(&out, e[1]) // offset into the data block
	}
	append(&out, ..block)
	return out[:]
}

@(private = "file")
put32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}
