package unit_tests

// Unit tests (ROADMAP Phase 0, step 8 / testing strategy): per-parser, on SYNTHETIC
// fixtures only — never game assets. This first test proves the harness is wired
// into the CI gate (build/test.sh) and exercises the VFS path normalizer.

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"
import vfs "../../src/vfs"

@(test)
test_vfs_mount_override_and_loose :: proc(t: ^testing.T) {
	dir := unit_temp_dir(t, "skymod_vfs")
	defer os.remove_all(dir)
	defer delete(dir)

	// Two archives: the second redefines meshes\clutter\barrel.nif → it must win
	// (later mount overrides earlier).
	base := test_folders()
	a1 := build_synthetic_bsa(vfs_version(), base)
	defer delete(a1)
	over := []TFolder{{"meshes\\clutter", []TFile{{"barrel.nif", "OVERRIDDEN-BARREL"}}}}
	a2 := build_synthetic_bsa(vfs_version(), over)
	defer delete(a2)

	p1, _ := filepath.join({dir, "a.bsa"}, context.allocator); defer delete(p1)
	p2, _ := filepath.join({dir, "b.bsa"}, context.allocator); defer delete(p2)
	testing.expect(t, os.write_entire_file(p1, a1) == nil, "write a.bsa")
	testing.expect(t, os.write_entire_file(p2, a2) == nil, "write b.bsa")

	v: vfs.VFS
	defer vfs.destroy(&v)
	testing.expect(t, vfs.mount_archive(&v, p1), "mount a")
	testing.expect(t, vfs.mount_archive(&v, p2), "mount b")

	// Case-insensitive + separator-insensitive lookup resolves.
	testing.expect(t, vfs.exists(&v, "Meshes/Clutter/Crate.nif"), "exists via normalized path")
	testing.expect(t, !vfs.exists(&v, "nope/missing.dds"), "missing path absent")

	got, ok := vfs.read(&v, "meshes\\clutter\\barrel.nif")
	testing.expect(t, ok, "read barrel")
	defer delete(got)
	testing.expectf(t, slice.equal(got, transmute([]u8)string("OVERRIDDEN-BARREL")), "later archive wins: %q", string(got))

	// A loose file beats every archive.
	loose_root, _ := filepath.join({dir, "loose"}, context.allocator); defer delete(loose_root)
	clutter, _ := filepath.join({loose_root, "meshes", "clutter"}, context.allocator); defer delete(clutter)
	testing.expect(t, os.make_directory_all(clutter) == nil, "mkdir loose tree")
	loose_file, _ := filepath.join({clutter, "barrel.nif"}, context.allocator); defer delete(loose_file)
	testing.expect(t, os.write_entire_file(loose_file, transmute([]u8)string("LOOSE-BARREL")) == nil, "write loose")
	vfs.mount_loose(&v, loose_root)

	got2, ok2 := vfs.read(&v, "meshes\\clutter\\barrel.nif")
	testing.expect(t, ok2, "read loose barrel")
	defer delete(got2)
	testing.expectf(t, slice.equal(got2, transmute([]u8)string("LOOSE-BARREL")), "loose wins: %q", string(got2))
}

vfs_version :: proc() -> u32 {
	return 104 // LE; matches bsa.VERSION_LE (avoids a render-free test importing bsa)
}

@(test)
test_normalize_path :: proc(t: ^testing.T) {
	Case :: struct {
		in_, want: string,
	}
	cases := []Case {
		// backslashes -> slashes, lowercased
		{"Meshes\\Architecture\\Whiterun\\WRTower01.nif", "meshes/architecture/whiterun/wrtower01.nif"},
		// leading/trailing slashes trimmed
		{"/Textures/Sky/", "textures/sky"},
		// already-normal stays put
		{"data/loose.txt", "data/loose.txt"},
		// mixed separators, interior "//" preserved (literal-string lookup)
		{"A\\\\B", "a//b"},
	}
	for c in cases {
		got := vfs.normalize_path(c.in_)
		defer delete(got)
		testing.expectf(t, got == c.want, "normalize_path(%q) = %q, want %q", c.in_, got, c.want)
	}
}
