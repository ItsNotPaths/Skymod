package script

// Encounter zone levels for mods (ws.md, Workstream P): read or pin a zone's level and band, and
// hear when a zone first takes its level. Papyrus has none of these; they are engine natives.

import "../worldstate"

register_levels :: proc(reg: ^Registry) {
	register(reg, "Game", "GetEncounterZoneLevel", n_get_zone_level)
	register(reg, "Game", "SetEncounterZoneLevel", n_set_zone_level)
	register(reg, "Game", "GetEncounterZoneMinLevel", n_get_zone_min_level)
	register(reg, "Game", "GetEncounterZoneMaxLevel", n_get_zone_max_level)
	register(reg, "Game", "SetEncounterZoneRange", n_set_zone_range)
	for class in ([]string{"Form", "Alias", "ActiveMagicEffect"}) {
		register(reg, class, "RegisterForZoneLevelSet", n_register_zone_levels)
		register(reg, class, "UnregisterForZoneLevelSet", n_unregister_zone_levels)
	}
}

n_get_zone_level :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.zone_level(c.ws, c.db, arg_form(args, 0))
}

// SetEncounterZoneLevel(akZone, aiLevel) pins the zone's level; later rolls in it use this.
n_set_zone_level :: proc(c: ^Call, args: []Value) -> Value {
	if zone := arg_form(args, 0); zone != 0 {c.ws.zone_levels[zone] = arg_i32(args, 1, 1)}
	return nil
}

n_get_zone_min_level :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.zone_band(c.ws, c.db, arg_form(args, 0)).min_level
}

n_get_zone_max_level :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.zone_band(c.ws, c.db, arg_form(args, 0)).max_level
}

// SetEncounterZoneRange(akZone, aiMin, aiMax) changes the band a zone's first level clamps to; a
// max of 0 is no cap.
n_set_zone_range :: proc(c: ^Call, args: []Value) -> Value {
	if zone := arg_form(args, 0); zone != 0 {c.ws.zone_ranges[zone] = {arg_i32(args, 1, 0), arg_i32(args, 2, 0)}}
	return nil
}

// RegisterForZoneLevelSet: the form hears OnZoneLevelSet(akZone, aiLevel) each time a zone takes its
// first level. Saved.
n_register_zone_levels :: proc(c: ^Call, args: []Value) -> Value {
	c.ws.zone_listeners[c.self] = true
	return nil
}

n_unregister_zone_levels :: proc(c: ^Call, args: []Value) -> Value {
	delete_key(&c.ws.zone_listeners, c.self)
	return nil
}
