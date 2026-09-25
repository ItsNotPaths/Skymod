package unit_tests

import "core:testing"
import ws "../../src/worldstate"
import "../../src/formid"

@(test)
test_calendar_round_trip :: proc(t: ^testing.T) {
	for d in i64(0) ..< 3 * ws.YEAR_DAYS {
		y, m, day := ws.calendar_date(d)
		testing.expect_value(t, ws.calendar_day(y, m, day), d)
	}
	y, m, day := ws.calendar_date(ws.calendar_day(201, 11, 31) + 1)
	testing.expect_value(t, [3]i64{y, m, day}, [3]i64{202, 0, 1})
}

@(test)
test_clock_start_and_tick :: proc(t: ^testing.T) {
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)

	// Skyrim.esm's start: 17 Last Seed 201, 8:00, one day passed.
	ws.start_clock(&s, 201, 7, 17, 8, 1)
	testing.expect_value(t, s.globals[formid.GAME_HOUR], 8)
	testing.expect_value(t, s.globals[formid.GAME_DAY], 17)
	testing.expect_value(t, s.globals[formid.GAME_MONTH], 7)
	testing.expect_value(t, s.globals[formid.GAME_YEAR], 201)

	// 16 hours at TimeScale 20 is 2880 real seconds; one more passes midnight into 18 Last Seed.
	passed: f64
	for _ in 0 ..< 2881 {passed += ws.advance_clock(&s, 1, 20)}
	testing.expectf(t, abs(passed - (16 + 1.0 / 180)) < 1e-9, "passed %v hours", passed)
	testing.expect_value(t, s.globals[formid.GAME_DAY], 18)
	testing.expectf(t, abs(s.globals[formid.GAME_DAYS_PASSED] - 2) < 1e-3, "days passed %v", s.globals[formid.GAME_DAYS_PASSED])
}

@(test)
test_clock_game_hour_writes :: proc(t: ^testing.T) {
	s: ws.World_State
	ws.init(&s)
	defer ws.destroy(&s)

	// Unset: the write waits in the global for the start.
	ws.set_game_hour(&s, 7)
	testing.expect_value(t, s.globals[formid.GAME_HOUR], 7)

	// Starting: the write sets the hour, even backwards (MQ101's 7.0 at a new game).
	ws.start_clock(&s, 201, 7, 17, 8, 1)
	ws.set_game_hour(&s, 7)
	testing.expect_value(t, s.clock.hours, 31)
	testing.expect_value(t, s.globals[formid.GAME_DAY], 17)

	// Running: the write skips forward to the next 23:00, and the next tick owes those hours.
	ws.end_first_tick(&s)
	ws.set_game_hour(&s, 23)
	testing.expect_value(t, s.clock.hours, 47)
	passed := ws.advance_clock(&s, 0, 20)
	testing.expect_value(t, passed, 16)

	// Running, an earlier hour: the next day.
	ws.set_game_hour(&s, 2)
	testing.expect_value(t, s.clock.hours, 50)
	testing.expect_value(t, s.globals[formid.GAME_DAY], 18)
}
