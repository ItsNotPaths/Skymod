package unit_tests

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
	testing.expect_value(t, len(p.list), 4)

	table := u32(1)
	plugin.apply(&p, "skymod_test", 2, &table)
	testing.expect_value(t, table, 1)
	plugin.apply(&p, "skymod_test", 1, &table)
	testing.expect_value(t, table, 7)
}
