package unit_tests

import "core:testing"
import "../../src/gamedb"

@(test)
test_output_level :: proc(t: ^testing.T) {
	// SOMDialogue3DDefault_verb: 70..3000, curve 100 50 20 5 0.
	o := gamedb.Sound_Output{min = 70, max = 3000, curve = {1, 0.5, 0.2, 0.05, 0}, attenuates = true}
	testing.expect_value(t, gamedb.output_level(o, 0), 1)
	testing.expect_value(t, gamedb.output_level(o, 70), 1)
	testing.expect_value(t, gamedb.output_level(o, 70 + 2930.0 / 4), 0.5)
	testing.expect_value(t, gamedb.output_level(o, 70 + 2930.0 / 8), 0.75) // halfway between the first two points
	testing.expect_value(t, gamedb.output_level(o, 3000), 0)
	testing.expect_value(t, gamedb.output_level(o, 1e6), 0)

	// The Sovngarde portal rises, then falls: silent at its own centre.
	portal := gamedb.Sound_Output{min = 500, max = 10000, curve = {0, 0.5, 1, 0.5, 0}, attenuates = true}
	testing.expect_value(t, gamedb.output_level(portal, 0), 0)
	testing.expect_value(t, gamedb.output_level(portal, 5250), 1)

	o.attenuates = false
	testing.expect_value(t, gamedb.output_level(o, 1e6), 1)
}
