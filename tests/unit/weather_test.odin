package unit_tests

import "core:testing"
import "../../src/plugin"
import "../../src/weather"
import "../../src/worldstate"

// The built-in weather: the highest-priority region's first weather, else the climate's first; a
// script's override holds, a one-off request holds until the natural pick changes, inside keeps it.
@(test)
test_weather_builtin :: proc(t: ^testing.T) {
	low := []weather.Chance{{0xA1, 100, 0}}
	high := []weather.Chance{{0xB1, 90, 0}, {0xB2, 10, 0}}
	climate := []weather.Chance{{0xC1, 100, 0}}
	regions := []weather.Region{{1, false, 50, plugin.span(low)}, {2, true, 95, plugin.span(high)}}
	tick := proc(inp: ^weather.Input) -> weather.Now {
		inp.now = weather.BUILTIN.tick(inp)
		return inp.now
	}

	inp := weather.Input{regions = plugin.span(regions), climate = plugin.span(climate)}
	testing.expect_value(t, tick(&inp), weather.Now{0xB1, 0, 1, 0xB1})

	inp.regions = {}
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xC1))

	inp.request = 0xD1
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xD1))
	inp.request = 0
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xD1)) // holds: the climate did not change
	inp.regions = plugin.span(regions)
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xB1)) // the natural pick changed

	inp.override = 0xE1
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xE1))
	inp.interior = true
	inp.override = 0
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xE1)) // inside: nothing offered, it stays
	inp.interior = false
	testing.expect_value(t, tick(&inp).current, weather.Form_ID(0xE1)) // back out: the same region pick

	// ReleaseOverride goes back to the natural pick through a one-off request.
	ws: worldstate.World_State
	ws.weather = {current = 0xE1, natural = 0xB1}
	worldstate.request_weather(&ws, 0xE1, true, false)
	worldstate.release_weather_override(&ws)
	testing.expect_value(t, ws.weather.override, weather.Form_ID(0))
	testing.expect_value(t, ws.weather.request, weather.Form_ID(0xB1))
}
