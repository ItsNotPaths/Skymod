package pe

// Minimal PE (Windows executable) reader: just enough to pull VS_FIXEDFILEINFO's
// file version — the "File version" Windows shows in exe Properties — out of the
// version resource. Used to identify a Skyrim install's edition/patch precisely
// (SkyrimSE.exe 1.6.1170.0 = AE, 1.5.97.0 = SE; TESV.exe 1.9.32.0 = LE final).
//
// Approach: parse the DOS + PE headers and the section table to locate the section
// holding the resource directory (data directory entry 2), then SCAN that section
// for VS_FIXEDFILEINFO's signature (0xFEEF04BD) instead of walking the resource
// tree — the signature is unique, the section is small, and this sidesteps every
// directory-encoding subtlety. Pure parser, no engine deps.

import "core:encoding/endian"
import "core:os"

// file_version returns {major, minor, build, revision} from the version resource
// of the executable at `path`. ok=false when the file isn't a PE or carries no
// version resource.
file_version :: proc(path: string) -> (ver: [4]u16, ok: bool) {
	f, ferr := os.open(path)
	if ferr != nil {
		return
	}
	defer os.close(f)

	// The DOS header, PE headers, and section table all sit inside the first 4 KB
	// in practice (SizeOfHeaders is 1-4 KB for every shipped Skyrim exe).
	head: [4096]u8
	hn, _ := os.read_at(f, head[:], 0)
	if hn < 0x40 {
		return
	}
	h := head[:hn]
	if h[0] != 'M' || h[1] != 'Z' {
		return
	}
	pe_off := int(rd32(h, 0x3C) or_return)
	if pe_off <= 0 || pe_off + 24 > len(h) {
		return
	}
	if h[pe_off] != 'P' || h[pe_off + 1] != 'E' || h[pe_off + 2] != 0 || h[pe_off + 3] != 0 {
		return
	}
	nsections := int(rd16(h, pe_off + 6) or_return)
	opt_size := int(rd16(h, pe_off + 20) or_return)
	opt := pe_off + 24
	magic := rd16(h, opt) or_return
	// PE32 (0x10B) vs PE32+ (0x20B): the data directories shift by 16 bytes.
	ndirs_off := opt + 108 if magic == 0x20B else opt + 92
	dirs := opt + 112 if magic == 0x20B else opt + 96
	if magic != 0x10B && magic != 0x20B {
		return
	}
	if int(rd32(h, ndirs_off) or_return) < 3 {
		return // no resource directory entry
	}
	rsrc_rva := int(rd32(h, dirs + 2 * 8) or_return) // data directory entry 2 = resources
	if rsrc_rva == 0 {
		return
	}

	// Find the section whose virtual range contains the resource RVA and read its
	// raw bytes (capped defensively — game exes keep resources well under this).
	sects := opt + opt_size
	for i in 0 ..< nsections {
		s := sects + i * 40
		if s + 40 > len(h) {
			return
		}
		vsize := int(rd32(h, s + 8) or_return)
		va := int(rd32(h, s + 12) or_return)
		raw_size := int(rd32(h, s + 16) or_return)
		raw_off := int(rd32(h, s + 20) or_return)
		if rsrc_rva < va || rsrc_rva >= va + max(vsize, raw_size) {
			continue
		}
		size := min(raw_size, 8 << 20)
		if size <= 16 {
			return
		}
		buf := make([]u8, size, context.temp_allocator)
		rn, rerr := os.read_at(f, buf, i64(raw_off))
		if rerr != nil || rn <= 16 {
			return
		}
		return scan_fixedfileinfo(buf[:rn])
	}
	return
}

// scan_fixedfileinfo finds VS_FIXEDFILEINFO by its dwSignature (0xFEEF04BD, unique
// in a resource section) and reads dwFileVersionMS/LS: {major, minor, build, rev}.
@(private)
scan_fixedfileinfo :: proc(b: []u8) -> (ver: [4]u16, ok: bool) {
	for i := 0; i + 16 <= len(b); i += 1 {
		// 0xFEEF04BD little-endian
		if b[i] != 0xBD || b[i + 1] != 0x04 || b[i + 2] != 0xEF || b[i + 3] != 0xFE {
			continue
		}
		ms := rd32(b, i + 8) or_continue  // dwFileVersionMS: major<<16 | minor
		ls := rd32(b, i + 12) or_continue // dwFileVersionLS: build<<16 | revision
		return {u16(ms >> 16), u16(ms & 0xFFFF), u16(ls >> 16), u16(ls & 0xFFFF)}, true
	}
	return
}

@(private)
rd16 :: proc(b: []u8, off: int) -> (u16, bool) {
	if off < 0 || off + 2 > len(b) {
		return 0, false
	}
	v, _ := endian.get_u16(b[off:off + 2], .Little)
	return v, true
}

@(private)
rd32 :: proc(b: []u8, off: int) -> (u32, bool) {
	if off < 0 || off + 4 > len(b) {
		return 0, false
	}
	v, _ := endian.get_u32(b[off:off + 4], .Little)
	return v, true
}
