package weather

// Which weather is in force. Each tick the host hands in what the player's place offers (its
// regions' weathers, else its worldspace's climate), the game hour and what scripts asked for, and
// keeps the Now that tick returns. The built-in takes the first weather offered and switches at once.
// A plugin replaces Table.tick.

import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_weather"
VERSION :: u32(1)

// Now is the weather in force: `transition` of the way (0..1) from `outgoing` to `current`.
Now :: struct {
	current, outgoing: Form_ID, // outgoing 0 = no transition
	transition:        f32,
	natural:           Form_ID, // the model's last own pick: a script's one-off weather holds until it changes
}

Chance :: struct {
	weather: Form_ID,
	chance:  i32,
	global:  Form_ID, // 0 = none
}

// Region is one weather region of the player's cell. An override region hides lower ones.
Region :: struct {
	id:       Form_ID,
	override: bool,
	priority: u8,
	weathers: plugin.Span(Chance),
}

Host :: struct {
	world: ^plugin.World,
	data:  rawptr,
}

Input :: struct {
	host:     Host,
	table:    ^Table,
	dt:       f32,
	hour:     f32, // game hour, 0..24
	interior: bool, // the player is inside: nothing is offered
	regions:  plugin.Span(Region), // the player's cell's weather regions
	climate:  plugin.Span(Chance), // its worldspace's climate
	override: Form_ID, // a script's held weather (SetActive/ForceActive with override); 0 = none
	request:  Form_ID, // a script's one-off weather this tick; 0 = none
	instant:  bool, // the script asked to skip the transition
	now:      Now, // as of the last tick
}

Table :: struct {
	tick: proc "c" (inp: ^Input) -> Now,
}

BUILTIN :: Table{tick_builtin}

// (hole weather-select :tags (world unclaimed) :sev gap) the built-in takes the first weather of the highest-priority region, else the climate's first, and switches at once. Wanted: a chance roll among the offered weathers (with their globals), weather changes timed by the hour and the climate's volatility, and a blend over the transition.
tick_builtin :: proc "c" (inp: ^Input) -> Now {
	now := inp.now
	natural := now.natural if inp.interior else first_offered(inp)
	target := now.current
	switch {
	case inp.override != 0:
		target = inp.override
	case inp.request != 0:
		target = inp.request
	case natural != now.natural:
		target = natural
	}
	return {target, 0, 1, natural}
}

@(private = "file")
first_offered :: proc "contextless" (inp: ^Input) -> Form_ID {
	best: ^Region
	for &r in plugin.items(inp.regions) {
		if r.weathers.len > 0 && (best == nil || r.priority > best.priority) {best = &r}
	}
	if best != nil {return best.weathers.data[0].weather}
	if inp.climate.len > 0 {return inp.climate.data[0].weather}
	return 0
}
