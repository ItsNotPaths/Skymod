package unit_tests

// promptpak round-trip: write → parse reproduces the directory + qoi payload byte-for-byte.
// Hermetic — hand-built entries, a fake qoi blob (parse never decodes it).

import "core:testing"
import "../../src/formats/promptpak"

@(test)
promptpak_roundtrip :: proc(t: ^testing.T) {
	entries := []promptpak.Entry {
		{name = "kbm/keyboard_f", x = 1, y = 1, w = 64, h = 64},
		{name = "xbox/xbox_button_color_a", x = 67, y = 1, w = 64, h = 64},
	}
	qoi := []u8{0xDE, 0xAD, 0xBE, 0xEF}
	blob := promptpak.write(2048, 132, entries, qoi)
	defer delete(blob)

	p, ok := promptpak.parse(blob)
	defer promptpak.destroy(&p)
	testing.expect(t, ok, "parse ok")
	testing.expect_value(t, p.atlas_w, 2048)
	testing.expect_value(t, p.atlas_h, 132)
	testing.expect_value(t, len(p.entries), 2)
	testing.expect_value(t, p.entries[0].name, "kbm/keyboard_f")
	testing.expect_value(t, p.entries[1].x, u16(67))
	testing.expect_value(t, len(p.qoi), 4)
	testing.expect_value(t, p.qoi[3], u8(0xEF))
}

@(test)
promptpak_rejects_garbage :: proc(t: ^testing.T) {
	_, ok := promptpak.parse([]u8{1, 2, 3})
	testing.expect(t, !ok, "truncated header rejected")
	blob := promptpak.write(64, 64, {}, {})
	defer delete(blob)
	blob[0] = 'X' // wrong magic
	_, ok = promptpak.parse(blob)
	testing.expect(t, !ok, "bad magic rejected")
}
