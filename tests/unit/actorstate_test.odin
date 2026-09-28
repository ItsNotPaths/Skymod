package unit_tests

import "core:testing"
import "../../src/actorstate"

// Names get fixed IDs; one state per actor; every change is recorded for the host.
@(test)
test_actorstate_model :: proc(t: ^testing.T) {
	m: actorstate.Model
	actorstate.init(&m)
	defer actorstate.destroy(&m)
	testing.expect_value(t, actorstate.state_id(&m, "Sneak"), actorstate.SNEAK)
	dodge := actorstate.state_id(&m, "DodgeRoll")
	testing.expect_value(t, actorstate.state_name(&m, dodge), "DodgeRoll")

	testing.expect(t, actorstate.request(&m, 0xA1, actorstate.SIT), "granted")
	testing.expect_value(t, actorstate.sit_state(&m, 0xA1), actorstate.SEATED)
	actorstate.leave(&m, 0xA1, actorstate.SNEAK)
	testing.expect_value(t, actorstate.current(&m, 0xA1), actorstate.SIT) // leaving a state it is not in does nothing
	actorstate.reset(&m, 0xA1)
	testing.expect_value(t, actorstate.current(&m, 0xA1), actorstate.STAND)

	changes: [dynamic]actorstate.Change
	defer delete(changes)
	actorstate.drain(&m, &changes)
	testing.expect_value(t, len(changes), 2)
	testing.expect_value(t, changes[1], actorstate.Change{0xA1, actorstate.SIT, actorstate.STAND})
	testing.expect_value(t, len(m.changes), 0)
}
