package unit_tests

// Unit tests for the installer's boot gate: source validation, the install step,
// and the content_ready() marker that lets boot decide install-vs-play. Hermetic:
// a synthetic "Skyrim" tree (an empty Data/Skyrim.esm — NO real assets) under a
// temp dir, cleaned up after.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../../src/installer"

@(test)
test_installer_boot_gate :: proc(t: ^testing.T) {
	// We deliberately exercise the bad-source path, which logs at ERROR level; the
	// test runner fails a test on any ERROR through its logger, so silence it.
	context.logger = log.nil_logger()

	base, terr := os.temp_dir(context.allocator)
	testing.expect(t, terr == nil, "temp_dir")
	defer delete(base)
	root, _ := filepath.join({base, "skymod_installer_test"}, context.allocator)
	defer delete(root)
	os.remove_all(root)
	_ = os.make_directory(root)
	defer os.remove_all(root)

	// Two subdirs: where the binary "lives" (gets content/), and a fake source.
	install_base, _ := filepath.join({root, "app"}, context.allocator)
	defer delete(install_base)
	source, _ := filepath.join({root, "Skyrim"}, context.allocator)
	defer delete(source)
	_ = os.make_directory(install_base)

	// Fresh install dir: not ready, and a missing/bad source is rejected.
	testing.expect(t, !installer.content_ready(install_base), "no content yet")
	testing.expect(t, !installer.valid_source(""), "empty source invalid")
	testing.expect(t, !installer.valid_source(source), "source without Data/Skyrim.esm invalid")
	testing.expect(t, !installer.install(source, install_base), "install rejects bad source")
	testing.expect(t, !installer.content_ready(install_base), "still no content after rejected install")

	// Build a synthetic source: Data/ with the base master + a fake archive and a
	// plugin (all empty — zero Bethesda bytes), to exercise the manifest index.
	data_dir, _ := filepath.join({source, "Data"}, context.allocator)
	defer delete(data_dir)
	_ = os.make_directory(source)
	_ = os.make_directory(data_dir)
	for name in ([]string{"Skyrim.esm", "Dawnguard.esm", "MyMod.esp", "Skyrim - Meshes.bsa"}) {
		fp, _ := filepath.join({data_dir, name}, context.allocator)
		defer delete(fp)
		testing.expect(t, os.write_entire_file(fp, []byte{}) == nil, "write synthetic Data file")
	}

	// Now it validates, installs, and the boot gate flips to ready.
	testing.expect(t, installer.valid_source(source), "valid source accepted")
	testing.expect(t, installer.install(source, install_base), "install succeeds")
	testing.expect(t, installer.content_ready(install_base), "content ready after install")

	// The manifest exists and records the BSA set + plugins (the VFS/gamedb index).
	manifest, _ := filepath.join({install_base, installer.CONTENT_DIR, installer.MANIFEST}, context.allocator)
	defer delete(manifest)
	testing.expect(t, os.exists(manifest), "manifest written")
	man, merr := os.read_entire_file(manifest, context.allocator)
	testing.expect(t, merr == nil, "read manifest")
	defer delete(man)
	ms := string(man)
	testing.expect(t, strings.contains(ms, "archive = Skyrim - Meshes.bsa"), "manifest lists the bsa")
	testing.expect(t, strings.contains(ms, "plugin = Skyrim.esm"), "manifest lists the master")
	testing.expect(t, strings.contains(ms, "plugin = MyMod.esp"), "manifest lists the plugin")
}
