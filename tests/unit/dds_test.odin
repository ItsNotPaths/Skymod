package unit_tests

// DDS parser tests (ROADMAP Iteration 1, Milestone B4). Hermetic + SYNTHETIC:
// hand-built minimal DDS headers (no game bytes). Regression guard on the header
// field offsets + mip-chain math only — REAL correctness is proven by sweeping the
// install's Textures BSA (tools/nifdump --dds), where every static-world format must
// parse and the computed mip chain must fit each file.

import "core:encoding/endian"
import "core:testing"
import "../../src/formats/dds"

@(test)
test_dds_bc1_mips :: proc(t: ^testing.T) {
	// 8x8 BC1 with 4 mip levels: 8x8(32B) + 4x4(8B) + 2x2(8B) + 1x1(8B) = 56 bytes.
	file := build_dds("DXT1", 8, 8, 4, 56)
	defer delete(file)

	img, ok := dds.parse(file[:])
	testing.expect(t, ok, "parse BC1")
	testing.expect_value(t, img.format, dds.Format.BC1)
	testing.expect_value(t, img.width, u32(8))
	testing.expect_value(t, img.height, u32(8))
	testing.expect_value(t, img.mip_count, u32(4))

	chain := dds.mip_chain(img)
	defer delete(chain)
	testing.expect_value(t, len(chain), 4)
	testing.expect_value(t, len(chain[0].data), 32) // 8x8 → 4 blocks * 8
	testing.expect_value(t, chain[0].width, u32(8))
	testing.expect_value(t, len(chain[1].data), 8) // 4x4 → 1 block
	testing.expect_value(t, len(chain[3].data), 8) // 1x1 → still 1 block, 8 bytes
}

@(test)
test_dds_bc3_format :: proc(t: ^testing.T) {
	// 4x4 BC3 (DXT5), 1 mip: one 16-byte block.
	file := build_dds("DXT5", 4, 4, 1, 16)
	defer delete(file)
	img, ok := dds.parse(file[:])
	testing.expect(t, ok, "parse BC3")
	testing.expect_value(t, img.format, dds.Format.BC3)
	testing.expect_value(t, dds.level_bytes(.BC3, 4, 4), 16)
}

@(test)
test_dds_bad_magic :: proc(t: ^testing.T) {
	file := build_dds("DXT1", 4, 4, 1, 8)
	defer delete(file)
	file[0] = 'X' // corrupt the magic
	_, ok := dds.parse(file[:])
	testing.expect(t, !ok, "reject bad magic")
}

// build_dds lays out a minimal DDS: 4-byte magic + 124-byte header (only the fields
// the parser reads are set; the rest stay zero) + `payload` zero bytes for the mip
// chain. Caller frees.
@(private = "file")
build_dds :: proc(fourcc: string, width, height, mips: u32, payload: int) -> []u8 {
	file := make([]u8, 4 + 124 + payload)
	d32 :: proc(b: []u8, off: int, v: u32) {
		endian.put_u32(b[off:off + 4], .Little, v)
	}
	d32(file, 0, 0x20534444) // "DDS "
	d32(file, 4, 124) // dwSize
	d32(file, 4 + 8, height) // dwHeight (header offset 8)
	d32(file, 4 + 12, width) // dwWidth (header offset 12)
	d32(file, 4 + 24, mips) // dwMipMapCount (header offset 24)
	d32(file, 4 + 72, 32) // ddspf.dwSize
	d32(file, 4 + 76, 0x4) // ddspf.dwFlags = DDPF_FOURCC
	copy(file[4 + 80:4 + 84], transmute([]u8)fourcc) // ddspf.dwFourCC
	return file
}
