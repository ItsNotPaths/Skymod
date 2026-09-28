package unit_tests

// A Queue drains whole in push order; a Latest hands over only the newest, once.

import "core:testing"
import "../../src/handoff"

@(test)
test_handoff :: proc(t: ^testing.T) {
	q: handoff.Queue(int)
	defer handoff.destroy(&q)
	into: [dynamic]int
	defer delete(into)
	handoff.push(&q, 1)
	handoff.push(&q, 2)
	handoff.drain(&q, &into)
	testing.expect(t, len(into) == 2 && into[0] == 1 && into[1] == 2, "drained in order")
	handoff.drain(&q, &into)
	testing.expect_value(t, len(into), 0)
	handoff.push(&q, 3)
	first, ok := handoff.take_first(&q)
	testing.expect(t, ok && first == 3, "take_first pops the oldest")

	l: handoff.Latest(int)
	back, cur := 1, 0
	testing.expect(t, !handoff.take(&l, &cur), "nothing published yet")
	handoff.publish(&l, &back)
	back = 2
	handoff.publish(&l, &back)
	testing.expect(t, handoff.take(&l, &cur) && cur == 2, "the newest")
	testing.expect(t, !handoff.take(&l, &cur), "taken once")
}
