package script

// Weather: what is in force, and a script's asks to change it (worldstate/weather.odin).

import "../gamedb"
import "../worldstate"

register_weather :: proc(reg: ^Registry) {
	register(reg, "Weather", "GetCurrentWeather", n_weather_current)
	register(reg, "Weather", "GetOutgoingWeather", n_weather_outgoing)
	register(reg, "Weather", "GetCurrentWeatherTransition", n_weather_transition)
	register(reg, "Weather", "GetSkyMode", n_weather_sky_mode)
	register(reg, "Weather", "FindWeather", n_weather_find)
	register(reg, "Weather", "ReleaseOverride", n_weather_release)
	register(reg, "Weather", "SetActive", n_weather_set_active)
	register(reg, "Weather", "ForceActive", n_weather_force_active)
	register(reg, "Weather", "GetClassification", n_weather_classification)
}

n_weather_current :: proc(c: ^Call, args: []Value) -> Value {return c.ws.weather.current}
n_weather_outgoing :: proc(c: ^Call, args: []Value) -> Value {return c.ws.weather.outgoing}
n_weather_transition :: proc(c: ^Call, args: []Value) -> Value {return c.ws.weather.transition}

// GetSkyMode: 1 = interior, 3 = full sky. (0 none and 2 skydome only are never answered.)
n_weather_sky_mode :: proc(c: ^Call, args: []Value) -> Value {
	return i32(1) if c.ws.weather.inside else i32(3)
}

// FindWeather(auiType): 0 pleasant, 1 cloudy, 2 rainy, 3 snow.
n_weather_find :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.find_weather(c.ws, c.db, gamedb.Weather_Class(arg_i32(args, 0, -1) + 1))
}

n_weather_release :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.release_weather_override(c.ws)
	return nil
}

// SetActive(abOverride, abAccelerate) and ForceActive(abOverride); ForceActive skips the transition.
n_weather_set_active :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.request_weather(c.ws, c.self, arg_bool(args, 0, false), arg_bool(args, 1, false))
	return nil
}

n_weather_force_active :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.request_weather(c.ws, c.self, arg_bool(args, 0, false), true)
	return nil
}

// GetClassification: -1 none, 0 pleasant, 1 cloudy, 2 rainy, 3 snow.
n_weather_classification :: proc(c: ^Call, args: []Value) -> Value {
	return i32(gamedb.weather_classification(c.db, c.self)) - 1
}
