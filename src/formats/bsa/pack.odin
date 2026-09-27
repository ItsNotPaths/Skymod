package bsa

import "core:strings"

// Packing is the ba2 crate's (vendor/ba2, glue in build/bsa_glue).
foreign import skybsa {"../../../vendor/ba2/lib/libskybsa.a", "system:stdc++", "system:gcc_s"}

// Pack_Entry is one file to pack: its archive path and where its bytes lie in the spool.
Pack_Entry :: struct {
	path:         cstring,
	offset, size: u64,
}

@(default_calling_convention = "c")
foreign skybsa {
	skybsa_pack :: proc(out, spool: cstring, entries: [^]Pack_Entry, n: uint) -> bool ---
}

// pack writes an uncompressed v105 archive at out, readable by open(). The files' bytes are read
// from the spool file (memory-mapped, so a large archive never sits on the heap).
pack :: proc(out, spool: string, entries: []Pack_Entry) -> bool {
	o := strings.clone_to_cstring(out, context.temp_allocator)
	s := strings.clone_to_cstring(spool, context.temp_allocator)
	return skybsa_pack(o, s, raw_data(entries), uint(len(entries)))
}
