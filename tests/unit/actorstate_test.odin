package unit_tests

import "core:testing"
import "../../src/actorstate"

// The stub: names get fixed IDs, every actor stands and every request is refused.
@(test)
test_actorstate_stub :: proc(t: ^testing.T) {
	m: actorstate.Model
	actorstate.init(&m)
	defer actorstate.destroy(&m)
	testing.expect_value(t, actorstate.state_id(&m, "Stand"), actorstate.STAND)
	dodge := actorstate.state_id(&m, "DodgeRoll")
	testing.expect_value(t, actorstate.state_id(&m, "DodgeRoll"), dodge)
	testing.expect_value(t, actorstate.state_name(&m, dodge), "DodgeRoll")
	testing.expect(t, !actorstate.request(&m, 0xA1, dodge), "the stub refuses")
	testing.expect_value(t, actorstate.current(&m, 0xA1).id, actorstate.STAND)
}
