package bsa

import "core:os"

// (hole bsa-writer :tags assets :sev gap) no BSA writer: install-time converters cannot repack their output, so converted audio has nowhere to go but loose files.

// Writer streams an uncompressed v105 archive: the names fix the header size, so data is
// appended as it arrives and the header is written at finish.
Writer :: struct {
	file:  ^os.File,
	paths: []string, // archive paths ("sound\voice\..."), in add order
	offsets, sizes: []u32,
}

create :: proc(path: string, paths: []string) -> (w: Writer, ok: bool) {
	return {}, false
}

// add appends the data of paths[i]. Files can arrive in any order.
add :: proc(w: ^Writer, i: int, data: []u8) -> bool {
	return false
}

finish :: proc(w: ^Writer) -> bool {
	return false
}
