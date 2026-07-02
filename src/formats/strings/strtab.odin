package strtab

// Localized string-table reader for the STRINGS family (ROADMAP Phase 4 substrate:
// real display names for the inspector + script refs). A LOCALIZED plugin (TES4 header
// flag 0x80) stores its string-typed subrecords — FULL names, DESC descriptions, book
// text, dialogue — as a u32 string id, NOT inline text; the text lives in an external
// per-plugin, per-language file:
//
//   Data/Strings/<Plugin>_<Language>.STRINGS   — names (FULL): NUL-terminated at offset
//   Data/Strings/<Plugin>_<Language>.DLSTRINGS  — descriptions (DESC/book): length-prefixed
//   Data/Strings/<Plugin>_<Language>.ILSTRINGS  — dialogue lines: length-prefixed
//
// Layout (little-endian): count:u32, dataSize:u32, then `count` directory entries
// { stringID:u32, offset:u32 } (offset into the data block that FOLLOWS the directory),
// then the dataSize-byte data block. `.STRINGS` stores a NUL-terminated string at each
// offset; `.DL/.ILSTRINGS` prefix each with a u32 byte length (INCLUDING the NUL).
// Ref: UESP "Skyrim Mod:String Table File Format". Pure parser — no engine deps.

import "core:encoding/endian"
import "core:strings"

// Kind distinguishes the two on-disk string encodings. Plain (.STRINGS, the names file)
// stores a bare NUL-terminated string at each directory offset; Lengthed (.DL/.ILSTRINGS)
// prefixes each with a u32 byte length that includes the trailing NUL.
Kind :: enum {
	Plain,
	Lengthed,
}

// parse decodes a STRINGS-family file into a stringID -> text map, cloning each string
// into `allocator` (free with destroy). ok=false on a truncated header/directory. A
// single malformed entry is skipped, not fatal — the rest of the table still resolves.
parse :: proc(data: []u8, kind: Kind, allocator := context.allocator) -> (table: map[u32]string, ok: bool) {
	if len(data) < 8 {
		return nil, false
	}
	count := int(rd32(data, 0))
	// Directory is `count` × 8 bytes starting at offset 8; the data block follows it.
	dir := 8
	block := dir + count * 8
	if block > len(data) {
		return nil, false
	}

	table = make(map[u32]string, count, allocator)
	for i in 0 ..< count {
		e := dir + i * 8
		sid := rd32(data, e)
		off := int(rd32(data, e + 4))
		start := block + off
		if start >= len(data) {
			continue // directory points past the data block — skip this entry
		}
		text: string
		switch kind {
		case .Plain:
			text = cstr(data[start:])
		case .Lengthed:
			if start + 4 > len(data) {
				continue
			}
			n := int(rd32(data, start))
			s := start + 4
			if n <= 0 || s + n > len(data) {
				continue
			}
			// n includes the trailing NUL; keep bytes up to (but not including) it.
			text = cstr(data[s:s + n])
		}
		table[sid] = strings.clone(text, allocator)
	}
	return table, true
}

// destroy frees a table's cloned strings and the map itself.
destroy :: proc(table: ^map[u32]string, allocator := context.allocator) {
	for _, v in table {
		delete(v, allocator)
	}
	delete(table^)
	table^ = {}
}

// lookup returns the text for a string id, or "" if the table has none.
lookup :: proc(table: map[u32]string, sid: u32) -> string {
	return table[sid] if sid in table else ""
}

// cstr returns the bytes up to the first NUL (the Bethesda zstring convention) as a
// view — parse clones it before keeping.
@(private)
cstr :: proc(b: []u8) -> string {
	for c, i in b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

@(private)
rd32 :: proc(b: []u8, off: int) -> u32 {
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return v
}
