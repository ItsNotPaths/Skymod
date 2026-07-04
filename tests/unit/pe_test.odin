package unit_tests

// PE version-resource reader test. Hermetic and SYNTHETIC: builds a minimal valid
// PE32+ image — DOS header, PE signature, optional header with a resource data
// directory, one .rsrc section whose raw data carries a VS_FIXEDFILEINFO — writes
// it to a temp file, and reads the file version back. (Real validation is the
// user's own SkyrimSE.exe/TESV.exe; see the golden pe_check harness.)

import "core:os"
import "core:path/filepath"
import "core:testing"
import pe "../../src/formats/pe"

@(test)
test_pe_file_version :: proc(t: ^testing.T) {
	img := build_synthetic_pe(1, 6, 1170, 0)
	defer delete(img)

	dir := unit_temp_dir(t, "skymod_pe")
	defer os.remove_all(dir)
	defer delete(dir)
	path, _ := filepath.join({dir, "fake.exe"}, context.allocator)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, img) == nil, "write exe")

	ver, ok := pe.file_version(path)
	testing.expect(t, ok, "file_version ok")
	testing.expect_value(t, ver, [4]u16{1, 6, 1170, 0})
}

@(test)
test_pe_rejects_non_pe :: proc(t: ^testing.T) {
	dir := unit_temp_dir(t, "skymod_pe_bad")
	defer os.remove_all(dir)
	defer delete(dir)
	path, _ := filepath.join({dir, "not.exe"}, context.allocator)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("BSA\x00 definitely not a PE")) == nil, "write file")
	_, ok := pe.file_version(path)
	testing.expect(t, !ok, "non-PE rejected")
}

// build_synthetic_pe lays out the smallest PE32+ that file_version accepts:
// headers in the first 512 bytes, one section (".rsrc") at raw offset 512 holding
// a VS_FIXEDFILEINFO with the given version. Caller frees.
@(private = "file")
build_synthetic_pe :: proc(major, minor, build, rev: u16, allocator := context.allocator) -> []u8 {
	img := make([]u8, 512 + 64, allocator)

	w16 :: proc(b: []u8, off: int, v: u16) {b[off] = u8(v);b[off + 1] = u8(v >> 8)}
	w32 :: proc(b: []u8, off: int, v: u32) {for i in 0 ..< 4 {b[off + i] = u8(v >> (u32(i) * 8))}}

	// DOS header: "MZ" + e_lfanew at 0x3C.
	img[0] = 'M'; img[1] = 'Z'
	pe_off := 0x80
	w32(img, 0x3C, u32(pe_off))

	// PE signature + COFF header.
	img[pe_off] = 'P'; img[pe_off + 1] = 'E' // + two zero bytes already there
	w16(img, pe_off + 4, 0x8664) // machine: x64
	w16(img, pe_off + 6, 1)      // one section
	opt_size := 112 + 16 * 8     // PE32+ fixed part + 16 data directories
	w16(img, pe_off + 20, u16(opt_size))

	// Optional header (PE32+): magic, NumberOfRvaAndSizes, resource directory (entry 2).
	opt := pe_off + 24
	w16(img, opt, 0x20B)
	w32(img, opt + 108, 16)            // NumberOfRvaAndSizes
	rsrc_rva := u32(0x1000)
	w32(img, opt + 112 + 2 * 8, rsrc_rva) // resource dir RVA
	w32(img, opt + 112 + 2 * 8 + 4, 64)   // resource dir size

	// Section table: ".rsrc", virtual 0x1000..+64, raw data at 512.
	s := opt + opt_size
	copy(img[s:], ".rsrc")
	w32(img, s + 8, 64)    // VirtualSize
	w32(img, s + 12, 0x1000) // VirtualAddress
	w32(img, s + 16, 64)   // SizeOfRawData
	w32(img, s + 20, 512)  // PointerToRawData

	// Section raw data: VS_FIXEDFILEINFO at a small offset inside.
	fx := 512 + 8
	w32(img, fx, 0xFEEF04BD)                          // dwSignature
	w32(img, fx + 4, 0x00010000)                      // dwStrucVersion
	w32(img, fx + 8, u32(major) << 16 | u32(minor))   // dwFileVersionMS
	w32(img, fx + 12, u32(build) << 16 | u32(rev))    // dwFileVersionLS
	return img
}
