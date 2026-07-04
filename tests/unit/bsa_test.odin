package unit_tests

// BSA reader tests (ROADMAP Iteration 1, Milestone A). Hermetic and SYNTHETIC: we
// build a valid v104/v105 archive in memory (no game bytes, ever), write it to a
// temp file, and round-trip it through bsa.open + bsa.extract. The builder is
// shared with the VFS test. Compression is exercised by the dev-only goldens
// against the real LE install (zlib path); CI stays uncompressed.

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import "../../src/formats/bsa"

// Synthetic archive description (folders in order, files in order).
TFile :: struct {
	name: string,
	data: string, // bytes, as a string for literal convenience
}
TFolder :: struct {
	name:  string,
	files: []TFile,
}

@(test)
test_bsa_roundtrip_v104 :: proc(t: ^testing.T) {
	bsa_roundtrip(t, bsa.VERSION_LE)
}

@(test)
test_bsa_roundtrip_v105_uncompressed :: proc(t: ^testing.T) {
	// Proves the v105 (SE) folder-record stride parameterization: an uncompressed
	// v105 archive indexes + extracts. (LZ4 is the only remaining SE work.)
	bsa_roundtrip(t, bsa.VERSION_SE)
}

@(test)
test_bsa_lz4_frame_extract :: proc(t: ^testing.T) {
	// v105 + FLAG_COMPRESSED: each data block is <u32 decomp size> + an LZ4 *frame*
	// (magic, descriptor, blocks, EndMark) — the exact shape real SSE archives use
	// (verified against the install: magic 0x184D2204 follows the size prefix).
	// One block: 3 literals "abc", match(offset 3, len 9) -> "abcabcabcabc", then
	// the final literals-only sequence "XYZ".
	lz4_seq := [10]u8{0x35, 'a', 'b', 'c', 0x03, 0x00, 0x30, 'X', 'Y', 'Z'}
	framed := [?]u8 {
		15, 0, 0, 0, // decompressed size (Bethesda's prefix, not part of the frame)
		0x04, 0x22, 0x4D, 0x18, // frame magic
		0x60, // FLG: version 01, block-independent, no checksums/content-size/dict
		0x40, // BD: 64 KB max block size
		0x00, // header checksum (reader skips it)
		10, 0, 0, 0, // block: 10 bytes, high bit clear = LZ4-compressed
		0x35, 'a', 'b', 'c', 0x03, 0x00, 0x30, 'X', 'Y', 'Z',
		0, 0, 0, 0, // EndMark
	}
	// Same block without the frame wrapper: the raw-block fallback path
	// (third-party packers that skip the frame).
	raw := [?]u8{15, 0, 0, 0, 0x35, 'a', 'b', 'c', 0x03, 0x00, 0x30, 'X', 'Y', 'Z'}
	_ = lz4_seq

	files := [2]TFile{{"framed.nif", string(framed[:])}, {"raw.nif", string(raw[:])}}
	folders := [1]TFolder{{"meshes", files[:]}}
	archive_bytes := build_synthetic_bsa(bsa.VERSION_SE, folders[:], flags_extra = 0x4)
	defer delete(archive_bytes)

	dir := unit_temp_dir(t, "skymod_bsa_lz4")
	defer os.remove_all(dir)
	defer delete(dir)
	path, _ := filepath.join({dir, "test.bsa"}, context.allocator)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, archive_bytes) == nil, "write bsa")

	arc, ok := bsa.open(path)
	testing.expect(t, ok, "open bsa")
	defer bsa.close(&arc)

	testing.expect_value(t, len(arc.entries), 2)
	for e in arc.entries {
		testing.expect(t, e.compressed, "entry marked compressed")
		data, eok := bsa.extract(&arc, e)
		testing.expectf(t, eok, "extract %s", e.path)
		defer delete(data)
		testing.expectf(t, string(data) == "abcabcabcabcXYZ", "decoded bytes for %s", e.path)
	}
}

bsa_roundtrip :: proc(t: ^testing.T, version: u32) {
	folders := test_folders()
	archive_bytes := build_synthetic_bsa(version, folders)
	defer delete(archive_bytes)

	dir := unit_temp_dir(t, fmt.tprintf("skymod_bsa_v%d", version))
	defer os.remove_all(dir)
	defer delete(dir)
	path, _ := filepath.join({dir, "test.bsa"}, context.allocator)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, archive_bytes) == nil, "write bsa")

	arc, ok := bsa.open(path)
	testing.expect(t, ok, "open bsa")
	defer bsa.close(&arc)

	testing.expect_value(t, len(arc.entries), 3)
	testing.expect_value(t, arc.entries[0].path, "meshes\\clutter\\barrel.nif")
	testing.expect_value(t, arc.entries[1].path, "meshes\\clutter\\crate.nif")
	testing.expect_value(t, arc.entries[2].path, "textures\\rock.dds")

	flat := flatten(folders)
	defer delete(flat)
	for e, i in arc.entries {
		data, eok := bsa.extract(&arc, e)
		testing.expect(t, eok, "extract")
		defer delete(data)
		testing.expectf(t, slice.equal(data, transmute([]u8)flat[i]), "bytes match for %s", e.path)
	}
}

// --- shared helpers (used by the VFS test too) ---

// The synthetic asset set, as file-private globals (a composite literal that
// slices another global can't be a `@(static)` local — it isn't constant).
@(private = "file") g_files0 := [2]TFile{{"barrel.nif", "NIF-BARREL-BYTES"}, {"crate.nif", "crate!"}}
@(private = "file") g_files1 := [1]TFile{{"rock.dds", "DDS\x00rock-pixels-here"}}
@(private = "file") g_folders := [2]TFolder{{"meshes\\clutter", g_files0[:]}, {"textures", g_files1[:]}}

test_folders :: proc() -> []TFolder {
	return g_folders[:]
}

// flatten returns each file's data (as strings) in global order.
flatten :: proc(folders: []TFolder) -> []string {
	out := make([dynamic]string, 0, 8)
	for fd in folders {
		for fl in fd.files {
			append(&out, fl.data)
		}
	}
	return out[:]
}

// build_synthetic_bsa lays out a valid archive: flags = folder names + file names
// (+ flags_extra, e.g. FLAG_COMPRESSED — then each TFile.data must already be the
// on-disk block: decomp-size prefix + compressed stream), no embedded names.
// version selects LE (16-byte folder records) or SE (24-byte). The caller frees
// the returned bytes.
build_synthetic_bsa :: proc(version: u32, folders: []TFolder, flags_extra: u32 = 0, allocator := context.allocator) -> []u8 {
	folder_rec := u32(16) if version == bsa.VERSION_LE else u32(24)
	folder_count := u32(len(folders))
	file_count := u32(0)
	total_folder_name_len := u32(0)
	total_file_name_len := u32(0)
	for fd in folders {
		total_folder_name_len += u32(len(fd.name) + 1)
		file_count += u32(len(fd.files))
		for fl in fd.files {
			total_file_name_len += u32(len(fl.name) + 1)
		}
	}
	folder_off := u32(36)
	folder_blocks := total_folder_name_len + folder_count + file_count * 16
	data_start := folder_off + folder_count * folder_rec + folder_blocks + total_file_name_len

	b := make([dynamic]u8, 0, 256, allocator)

	// header
	append(&b, 'B', 'S', 'A', 0)
	put_u32(&b, version)
	put_u32(&b, folder_off)
	put_u32(&b, 0x3 | flags_extra) // folder names + file names (+ caller extras)
	put_u32(&b, folder_count)
	put_u32(&b, file_count)
	put_u32(&b, total_folder_name_len)
	put_u32(&b, total_file_name_len)
	put_u32(&b, 0) // content-type flags

	// folder records (offset field = block position + total_file_name_len)
	block_pos := folder_off + folder_count * folder_rec
	for fd in folders {
		put_u64(&b, 0) // hash (reader ignores)
		put_u32(&b, u32(len(fd.files)))
		if version != bsa.VERSION_LE {
			put_u32(&b, 0) // v105 padding
			put_u64(&b, u64(block_pos + total_file_name_len))
		} else {
			put_u32(&b, block_pos + total_file_name_len)
		}
		block_pos += 1 + u32(len(fd.name) + 1) + u32(len(fd.files)) * 16
	}

	// file data offsets, global order
	file_offsets := make([dynamic]u32, 0, int(file_count), context.temp_allocator)
	off := data_start
	for fd in folders {
		for fl in fd.files {
			append(&file_offsets, off)
			off += u32(len(fl.data))
		}
	}

	// folder blocks: bzstring name + file records
	gi := 0
	for fd in folders {
		append(&b, u8(len(fd.name) + 1))
		append(&b, ..transmute([]u8)fd.name)
		append(&b, 0)
		for fl in fd.files {
			put_u64(&b, 0) // hash
			put_u32(&b, u32(len(fl.data))) // size, no flip bit (uncompressed)
			put_u32(&b, file_offsets[gi])
			gi += 1
		}
	}

	// file-name block (null-terminated, global order)
	for fd in folders {
		for fl in fd.files {
			append(&b, ..transmute([]u8)fl.name)
			append(&b, 0)
		}
	}

	// file data
	for fd in folders {
		for fl in fd.files {
			append(&b, ..transmute([]u8)fl.data)
		}
	}
	return b[:]
}

// unit_temp_dir makes a fresh, empty dir under the OS temp root, unique per `name`
// so parallel tests don't collide. Caller frees the path and removes the dir.
unit_temp_dir :: proc(t: ^testing.T, name: string) -> string {
	base, terr := os.temp_dir(context.allocator)
	testing.expect(t, terr == nil, "temp_dir")
	defer delete(base)
	dir, _ := filepath.join({base, name}, context.allocator)
	os.remove_all(dir)
	_ = os.make_directory(dir)
	return dir
}

@(private = "file")
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	t: [4]u8
	endian.put_u32(t[:], .Little, v)
	append(b, ..t[:])
}

@(private = "file")
put_u64 :: proc(b: ^[dynamic]u8, v: u64) {
	t: [8]u8
	endian.put_u64(t[:], .Little, v)
	append(b, ..t[:])
}
