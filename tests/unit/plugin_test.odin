package unit_tests

import "core:slice"
import "core:strings"
import "core:testing"
import "../../src/plugin"

// The test plugin is built by build/test.sh into TEST_PLUGINS before the tests run.
TEST_PLUGINS :: "build/out/test-plugins"

// A plugin changes a seam's table for a version it knows and leaves it alone for one it refuses.
@(test)
test_plugin_apply :: proc(t: ^testing.T) {
	p: plugin.Plugins
	defer plugin.destroy(&p)
	plugin.load(&p, {TEST_PLUGINS})
	testing.expect_value(t, len(p.list), 6)

	table := u32(1)
	plugin.apply(&p, "skymod_test", 2, &table)
	testing.expect_value(t, table, 1)
	plugin.apply(&p, "skymod_test", 1, &table)
	testing.expect_value(t, table, 7)
}

// The profile names each seam's owner: the plugin that last changed it, else the built-in.
@(test)
test_plugin_owner :: proc(t: ^testing.T) {
	p: plugin.Plugins
	defer plugin.destroy(&p)
	plugin.load(&p, {TEST_PLUGINS})
	testing.expect_value(t, plugin.owner(&p, "skymod_test"), "built-in")
	table := u32(1)
	plugin.apply(&p, "skymod_test", 1, &table)
	testing.expect_value(t, plugin.owner(&p, "skymod_test"), "build/out/test-plugins/seam_test.so")
}

// A plugin gets its saved data back by its ID; data of a plugin that is gone is kept.
@(test)
test_plugin_save_data :: proc(t: ^testing.T) {
	p: plugin.Plugins
	defer plugin.destroy(&p)
	plugin.load(&p, {TEST_PLUGINS})
	blobs := make(map[string][]u8)
	defer {
		for id, data in blobs {delete(id);delete(data)}
		delete(blobs)
	}
	blobs[strings.clone("gone.0000")] = slice.clone([]u8{1, 2, 3})
	blobs[strings.clone("save_counter.5b0f2c1e")] = slice.clone([]u8{7, 0, 0, 0})

	plugin.load_data(&p, blobs)
	plugin.save_data(&p, &blobs)
	testing.expect_value(t, len(blobs), 2)
	testing.expect(t, slice.equal(blobs["save_counter.5b0f2c1e"], []u8{7, 0, 0, 0}), "its data comes back")
	testing.expect(t, slice.equal(blobs["gone.0000"], []u8{1, 2, 3}), "the orphan is kept")

	plugin.load_data(&p, {}) // a new game
	plugin.save_data(&p, &blobs)
	testing.expect(t, slice.equal(blobs["save_counter.5b0f2c1e"], []u8{0, 0, 0, 0}), "it starts fresh")
}
