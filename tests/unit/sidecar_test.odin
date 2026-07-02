package unit_tests

// Mod-identity sidecar tests (docs/mods.md "Two tiers"). Writes a mods/<name>/skymod/mod.txt to a
// temp dir and asserts parse (uuid/name/version/requires), the "no uuid ⇒ not an identity" rule, the
// content-hash fallback's determinism + order-independence, and a missing-file miss.

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../../src/mods"

@(test)
test_sidecar_read :: proc(t: ^testing.T) {
	dir := "/tmp/skymod_sidecar_test_mod"
	sub, _ := filepath.join({dir, mods.SIDECAR_SUBDIR}, context.temp_allocator)
	path, _ := filepath.join({sub, mods.SIDECAR_FILE}, context.temp_allocator)
	os.make_directory(dir)
	os.make_directory(sub)
	defer os.remove(path)

	_ = os.write_entire_file(
		path,
		transmute([]byte)string(
			"# a mod sidecar\nuuid = abc-123\nName = Cool Mod\nversion = 1.2.0\nrequires = Dawnguard.esm, Some Other Mod\n",
		),
	)

	id, ok := mods.read_sidecar(dir)
	defer mods.mod_identity_destroy(&id)
	testing.expect(t, ok, "sidecar with a uuid parses")
	testing.expect(t, id.uuid == "abc-123", "uuid parsed")
	testing.expect(t, id.name == "Cool Mod", "name parsed (key case-insensitive)")
	testing.expect(t, id.version == "1.2.0", "version parsed")
	testing.expect(t, len(id.requires) == 2, "two requires entries (comma-split, multi-word kept)")
	if len(id.requires) == 2 {
		testing.expect(t, id.requires[0] == "Dawnguard.esm", "first dep")
		testing.expect(t, id.requires[1] == "Some Other Mod", "multi-word dep preserved")
	}
}

@(test)
test_sidecar_missing_and_no_uuid :: proc(t: ^testing.T) {
	if _, ok := mods.read_sidecar("/tmp/skymod_no_such_mod_dir_xyz"); ok {
		testing.expect(t, false, "a missing sidecar must miss")
	}

	dir := "/tmp/skymod_sidecar_nouuid_mod"
	sub, _ := filepath.join({dir, mods.SIDECAR_SUBDIR}, context.temp_allocator)
	path, _ := filepath.join({sub, mods.SIDECAR_FILE}, context.temp_allocator)
	os.make_directory(dir)
	os.make_directory(sub)
	defer os.remove(path)
	_ = os.write_entire_file(path, transmute([]byte)string("name = No UUID Here\nversion = 0.1\n"))

	if _, ok := mods.read_sidecar(dir); ok {
		testing.expect(t, false, "a sidecar without a uuid is not a usable identity")
	}
}

@(test)
test_content_hash_identity :: proc(t: ^testing.T) {
	a := transmute([]byte)string("plugin-A-bytes")
	b := transmute([]byte)string("plugin-B-different")

	h1 := mods.content_hash_identity({a, b})
	h2 := mods.content_hash_identity({b, a}) // order-independent
	h3 := mods.content_hash_identity({a}) // different content set
	defer {delete(h1);delete(h2);delete(h3)}

	testing.expect(t, len(h1) > 3 && h1[:3] == "ch-", "hash identity is prefixed ch-")
	testing.expect(t, h1 == h2, "content hash is order-independent")
	testing.expect(t, h1 != h3, "different plugin set yields a different identity")
}
