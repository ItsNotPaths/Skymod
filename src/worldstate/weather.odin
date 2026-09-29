package worldstate

// The weather in force and what scripts asked of it. The weather seam (src/weather) picks; this holds
// its answer and the script requests it reads next tick.

import "../gamedb"

Weather_State :: struct {
	current, outgoing: Form_ID, // outgoing 0 = no transition
	transition:        f32, // 0..1 of the way from outgoing to current
	natural:           Form_ID, // the seam's last own pick
	override:          Form_ID, // held by SetActive/ForceActive with override until ReleaseOverride; 0 = none
	request:           Form_ID, // a one-off SetActive/ForceActive, taken by the next tick
	instant:           bool, // the override or request skips the transition
	inside:            bool, // the player is in an interior: the sky is the interior's
}

// request_weather is Weather.SetActive / ForceActive: `override` holds the weather until released.
request_weather :: proc(ws: ^World_State, weather: Form_ID, override, instant: bool) {
	if override {ws.weather.override = weather} else {ws.weather.request = weather}
	ws.weather.instant = instant
}

// release_weather_override is Weather.ReleaseOverride: back to the seam's own pick.
release_weather_override :: proc(ws: ^World_State) {
	if ws.weather.override == 0 {return}
	ws.weather.override = 0
	ws.weather.request = ws.weather.natural
}

// find_weather is Weather.FindWeather: the first weather the player's place offers of that class.
find_weather :: proc(ws: ^World_State, db: ^gamedb.DB, class: gamedb.Weather_Class) -> Form_ID {
	for w in ws.weathers_offered {
		if gamedb.weather_classification(db, w) == class {return w}
	}
	return 0
}
