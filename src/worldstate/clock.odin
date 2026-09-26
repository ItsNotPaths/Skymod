package worldstate

// The game clock. It is the source of game time; the time globals are written from it.

import "core:math"
import "../formid"

// Tamriel's month lengths. No leap years.
MONTH_DAYS :: [12]i64{31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
YEAR_DAYS :: 365

// Clock_State: a GameHour write sets the start until the first tick ends, and skips forward after.
Clock_State :: enum u8 {
	Unset, // a new game or an old save; the next tick starts the clock
	Starting,
	Running,
}

// Game_Clock is game time. An f64 hour count keeps a tick's 0.33 game seconds for centuries of play.
Game_Clock :: struct {
	hours:     f64, // game hours since day 0 began; GameDaysPassed is hours / 24
	start_day: i64, // calendar day of day 0, counted from 1 Morning Star of year 0
	skipped:   f64, // hours skipped since the last tick, still owed to the script clocks
	played:    f64, // real seconds of ticks in this game, across saves (GetCurrentRealTime)
	state:     Clock_State,
}

// start_clock places the clock at the date and hour the time globals hold, with `days_passed` whole
// days behind it.
start_clock :: proc(ws: ^World_State, year, month, day, hour, days_passed: f32) {
	whole := math.floor(f64(days_passed))
	ws.clock = {
		hours     = whole * 24 + f64(hour),
		start_day = calendar_day(i64(year), i64(month), i64(day)) - i64(whole),
		played    = ws.clock.played,
		state     = .Starting,
	}
	write_time_globals(ws)
}

// advance_clock moves the clock by one tick. Returns the game hours that passed, skips included.
advance_clock :: proc(ws: ^World_State, dt, time_scale: f32) -> f64 {
	c := &ws.clock
	step := f64(dt) * f64(time_scale) / 3600
	c.hours += step
	c.played += f64(dt)
	passed := step + c.skipped
	c.skipped = 0
	write_time_globals(ws)
	return passed
}

// end_first_tick ends the start: later GameHour writes skip forward.
end_first_tick :: proc(ws: ^World_State) {
	if ws.clock.state == .Starting {ws.clock.state = .Running}
}

// (hole time-skip :tags world :sev gap) no Sleep/Wait menu, fast travel or jail calls skip_game_time; only the console `wait` and a script GameHour write do.
// skip_game_time jumps the clock forward. The next tick passes the hours to the script clocks.
skip_game_time :: proc(ws: ^World_State, hours: f64) {
	if hours <= 0 {return}
	ws.clock.hours += hours
	ws.clock.skipped += hours
	write_time_globals(ws)
}

// set_game_hour is a script's GameHour write. Time never runs backwards: once the clock runs, the
// write skips forward to the next time the hour comes round.
set_game_hour :: proc(ws: ^World_State, hour: f32) {
	c := &ws.clock
	h := f64(hour)
	switch c.state {
	case .Unset:
		set_global(ws, formid.GAME_HOUR, hour) // the start reads it
	case .Starting:
		c.hours = math.floor(c.hours / 24) * 24 + h
		write_time_globals(ws)
	case .Running:
		skip_game_time(ws, math.mod(h - math.mod(c.hours, 24) + 24, 24))
	}
}

// calendar_day counts days from 1 Morning Star of year 0. `month` counts from 0, `day` from 1.
calendar_day :: proc(year, month, day: i64) -> i64 {
	d := year * YEAR_DAYS + day - 1
	months := MONTH_DAYS
	for m in 0 ..< clamp(month, 0, 12) {d += months[m]}
	return d
}

// calendar_date is calendar_day's inverse.
calendar_date :: proc(d: i64) -> (year, month, day: i64) {
	year = d / YEAR_DAYS
	day = d % YEAR_DAYS
	months := MONTH_DAYS
	for day >= months[month] {
		day -= months[month]
		month += 1
	}
	return year, month, day + 1
}

// game_date is the clock's calendar date and hour of the day.
game_date :: proc(ws: ^World_State) -> (year, month, day: i64, hour: f64) {
	year, month, day = calendar_date(ws.clock.start_day + i64(math.floor(ws.clock.hours / 24)))
	return year, month, day, math.mod(ws.clock.hours, 24)
}

// (hole start-weekday :tags quest :sev polish) that 17 Last Seed 4E 201 is a Morndas is from memory, not the data: check the wait menu on a new game.
// weekday is the day of the week: 0 Sundas, 1 Morndas .. 6 Loredas.
weekday :: proc(ws: ^World_State) -> i64 {
	today := ws.clock.start_day + i64(math.floor(ws.clock.hours / 24))
	return ((today - calendar_day(201, 7, 17) + 1) % 7 + 7) % 7
}

@(private = "file")
write_time_globals :: proc(ws: ^World_State) {
	year, month, day, hour := game_date(ws)
	set_global(ws, formid.GAME_YEAR, f32(year))
	set_global(ws, formid.GAME_MONTH, f32(month))
	set_global(ws, formid.GAME_DAY, f32(day))
	set_global(ws, formid.GAME_HOUR, f32(hour))
	set_global(ws, formid.GAME_DAYS_PASSED, f32(ws.clock.hours / 24))
}
