package bsa

// BSA archive reader (ROADMAP Iteration 1, Milestone A). Read-only and
// byte-accurate: we INDEX the archive (each file's path + where its bytes live)
// and extract on demand, never copying the archive. A dumb reader — path
// normalization and override precedence live one layer up in `vfs`, the path
// authority.
//
// Layout (little-endian): header(36) → folder-record table → per-folder blocks
// (name + file records) → file-name block → file data. Refs: UESP "Skyrim
// Mod:Archive File Format". No engine deps.
//
// LE (v104) vs SE (v105): the format is nearly identical. The header, folder
// blocks, file records, and name block are byte-for-byte the same; only two things
// differ — the folder-record STRIDE (16 vs 24 bytes; `count` is at the same offset
// either way) and the default COMPRESSION (zlib vs LZ4). Both are parameterized
// below (folder_rec, Archive.method) so SE support is: accept 105 + implement
// decompress_lz4. Nothing else changes. (SE uses .bsa v105, NOT .ba2 — that's
// Fallout 4; and SE textures are still full DDS, no header reconstruction.)

import "core:bytes"
import "core:compress/zlib"
import "core:encoding/endian"
import "core:os"
import "core:slice"
import "core:strings"

VERSION_LE :: 104 // Skyrim Legendary Edition (TES5): zlib, 16-byte folder records.
VERSION_SE :: 105 // Skyrim Special Edition: LZ4, 24-byte folder records.

// Header archive_flags bits we care about.
FLAG_FOLDER_NAMES :: 0x1   // folder records are followed by their names
FLAG_FILE_NAMES   :: 0x2   // a file-name block follows the folder blocks
FLAG_COMPRESSED   :: 0x4   // files are compressed by default (method = Archive.method)
FLAG_EMBED_NAMES  :: 0x100 // each file's data block is prefixed with its full path

// File-record size field: low 30 bits are the size; bit 30 means "compression is
// the OPPOSITE of the archive default".
SIZE_MASK          :: 0x3FFF_FFFF
SIZE_FLIP_COMPRESS :: 0x4000_0000

HEADER_SIZE   :: 36
FOLDER_REC_LE :: 16 // v104: u64 hash, u32 count, u32 offset
FOLDER_REC_SE :: 24 // v105: u64 hash, u32 count, u32 _pad, u64 offset
FILE_REC      :: 16 // file record (both versions): u64 hash, u32 size, u32 offset

// Compression is the per-archive default method (the edition determines it). The
// per-file `compressed` bool then says whether a given file uses it.
Compression :: enum {
	Zlib, // LE (v104)
	LZ4,  // SE (v105) — not yet implemented (see decompress_lz4)
}

// Entry is one indexed file: its path as stored in the archive (e.g.
// "textures\clutter\foo.dds", backslashes, original case) and where its bytes are.
Entry :: struct {
	path:       string, // heap-owned, raw (vfs normalizes for lookup)
	offset:     u32,    // absolute offset of the data block
	size:       u32,    // size of the data block (already masked)
	compressed: bool,
}

Archive :: struct {
	file:        ^os.File,
	path:        string,      // the .bsa path on disk (heap-owned)
	method:      Compression, // how compressed files in this archive are packed
	embed_names: bool,        // data blocks carry a leading name bstring
	entries:     []Entry,     // heap-owned
}

// open parses an archive's index. The file handle stays open for extract(); call
// close() when done. Returns ok=false (handle cleaned up) on any malformed input.
open :: proc(path: string, allocator := context.allocator) -> (arc: Archive, ok: bool) {
	context.allocator = allocator

	f, ferr := os.open(path)
	if ferr != nil {
		return {}, false
	}
	defer if !ok {
		os.close(f)
	}

	hdr: [HEADER_SIZE]u8
	if n, err := os.read_at(f, hdr[:], 0); err != nil || n != HEADER_SIZE {
		return {}, false
	}
	if string(hdr[0:4]) != "BSA\x00" {
		return {}, false
	}
	version, _              := endian.get_u32(hdr[4:8], .Little)
	folder_off, _           := endian.get_u32(hdr[8:12], .Little)
	flags, _                := endian.get_u32(hdr[12:16], .Little)
	folder_count, _         := endian.get_u32(hdr[16:20], .Little)
	file_count, _           := endian.get_u32(hdr[20:24], .Little)
	total_folder_name_len, _ := endian.get_u32(hdr[24:28], .Little)
	total_file_name_len, _   := endian.get_u32(hdr[28:32], .Little)
	// hdr[32:36] = content-type flags — unused for now.

	folder_rec: u32
	method: Compression
	switch version {
	case VERSION_LE:
		folder_rec, method = FOLDER_REC_LE, .Zlib
	case VERSION_SE:
		folder_rec, method = FOLDER_REC_SE, .LZ4
	case:
		return {}, false // Oblivion v103, Fallout 4 .ba2, etc. — unsupported
	}
	has_folder_names := flags & FLAG_FOLDER_NAMES != 0
	has_file_names := flags & FLAG_FILE_NAMES != 0
	default_compressed := flags & FLAG_COMPRESSED != 0

	// Read the whole front matter in one shot (it ends where file data begins).
	folder_blocks := file_count * FILE_REC
	if has_folder_names {
		folder_blocks += total_folder_name_len + folder_count // names(+null) + 1 len byte each
	}
	front := folder_off + folder_count * folder_rec + folder_blocks
	if has_file_names {
		front += total_file_name_len
	}
	buf := make([]u8, int(front), context.temp_allocator)
	if n, err := os.read_at(f, buf, 0); err != nil || n != int(front) {
		return {}, false
	}

	// Per-folder file counts come from the folder-record table; the blocks
	// themselves follow contiguously. Walk them in order.
	counts := make([]u32, int(folder_count), context.temp_allocator)
	for i in 0 ..< int(folder_count) {
		rec := buf[int(folder_off) + i * int(folder_rec):] // count is at +8 in both versions
		counts[i], _ = endian.get_u32(rec[8:12], .Little)
	}

	entries := make([]Entry, int(file_count))
	// First pass: walk folder blocks → per-global-file (folder name, offset, size,
	// compressed). File names are filled from the name block in a second pass.
	folder_for_file := make([]string, int(file_count), context.temp_allocator)
	cur := int(folder_off + folder_count * folder_rec)
	gi := 0
	for i in 0 ..< int(folder_count) {
		folder_name := ""
		if has_folder_names {
			name_len := int(buf[cur]) // bzstring: length includes the null terminator
			start := cur + 1
			folder_name = string(buf[start:start + name_len - 1]) // drop the null
			cur = start + name_len
		}
		for _ in 0 ..< int(counts[i]) {
			if gi >= int(file_count) {
				return {}, false
			}
			rec := buf[cur:]
			raw_size, _ := endian.get_u32(rec[8:12], .Little)
			off, _ := endian.get_u32(rec[12:16], .Little)
			compressed := default_compressed
			if raw_size & SIZE_FLIP_COMPRESS != 0 {
				compressed = !default_compressed
			}
			entries[gi] = Entry {
				offset     = off,
				size       = raw_size & SIZE_MASK,
				compressed = compressed,
			}
			folder_for_file[gi] = folder_name
			cur += FILE_REC
			gi += 1
		}
	}

	// Second pass: the file-name block is null-terminated names in global order.
	if has_file_names {
		names := buf[cur:cur + int(total_file_name_len)]
		ni := 0
		for f2 in 0 ..< int(file_count) {
			end := ni
			for end < len(names) && names[end] != 0 {
				end += 1
			}
			file_name := string(names[ni:end])
			entries[f2].path = path_join(folder_for_file[f2], file_name)
			ni = end + 1
		}
	} else {
		// No names: fall back to the folder name so entries are at least present.
		for f2 in 0 ..< int(file_count) {
			entries[f2].path = path_join(folder_for_file[f2], "")
		}
	}

	arc = Archive {
		file        = f,
		path        = strings.clone(path),
		method      = method,
		embed_names = flags & FLAG_EMBED_NAMES != 0,
		entries     = entries,
	}
	return arc, true
}

close :: proc(arc: ^Archive) {
	if arc.file != nil {
		os.close(arc.file)
	}
	for e in arc.entries {
		delete(e.path)
	}
	delete(arc.entries)
	delete(arc.path)
	arc^ = {}
}

// extract returns a file's decompressed bytes. The result is freshly allocated in
// `allocator`; the caller owns it (delete when done).
extract :: proc(arc: ^Archive, e: Entry, allocator := context.allocator) -> (data: []u8, ok: bool) {
	context.allocator = allocator

	block := make([]u8, int(e.size))
	defer delete(block)
	if n, err := os.read_at(arc.file, block, i64(e.offset)); err != nil || n != int(e.size) {
		return nil, false
	}

	payload := block[:]
	if arc.embed_names {
		// Leading bstring: u8 length + name bytes. Skip it.
		if len(payload) < 1 {
			return nil, false
		}
		skip := 1 + int(payload[0])
		if skip > len(payload) {
			return nil, false
		}
		payload = payload[skip:]
	}

	if e.compressed {
		// Both editions prefix the block with a 4-byte decompressed size, then the
		// compressed stream — only the codec differs by edition.
		if len(payload) < 4 {
			return nil, false
		}
		decomp_size, _ := endian.get_u32(payload[0:4], .Little)
		switch arc.method {
		case .Zlib:
			return decompress_zlib(payload[4:], int(decomp_size), allocator)
		case .LZ4:
			return decompress_lz4(payload[4:], int(decomp_size), allocator)
		}
		return nil, false
	}

	return slice.clone(payload, allocator), true
}

// decompress_zlib inflates a zlib stream (LE / v104).
@(private)
decompress_zlib :: proc(stream: []u8, decomp_size: int, allocator := context.allocator) -> ([]u8, bool) {
	out: bytes.Buffer
	if err := zlib.inflate(stream, &out, false, decomp_size); err != nil {
		bytes.buffer_destroy(&out)
		return nil, false
	}
	return bytes.buffer_to_bytes(&out), true // buffer-owned slice; caller deletes
}

// decompress_lz4 inflates an LZ4 block stream (SE / v105). TODO(SE): Odin core has
// no LZ4 — drop in an LZ4 block decompressor here (the algorithm is ~50 lines) and
// SE archives extract. This is the ONLY codec work the LE→SE jump needs.
@(private)
decompress_lz4 :: proc(stream: []u8, decomp_size: int, allocator := context.allocator) -> ([]u8, bool) {
	return nil, false
}

// --- internals ---

// path_join builds "folder\file" (Bethesda separator), or just one side when the
// other is empty. Uses the ambient allocator (open() sets it from its parameter).
@(private)
path_join :: proc(folder, file: string) -> string {
	switch {
	case file == "":
		return strings.clone(folder)
	case folder == "":
		return strings.clone(file)
	case:
		return strings.concatenate({folder, "\\", file})
	}
}
