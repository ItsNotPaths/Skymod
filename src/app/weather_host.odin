package main

// The host side of the weather seam (src/weather): what the player's place offers, the tick, and
// keeping its answer in ws.weather.

import "core:math"
import "../gamedb"
import "../plugin"
import "../weather"
import "../world"
import "../worldhost"

// tick_weather runs the weather table once. Call after traversal, so the player's place is this tick's.
tick_weather :: proc(g: ^Game) {
	ws := &g.sim.ws
	st := &ws.weather
	interior := inside(&g.sim.trav)
	regions := make([dynamic]weather.Region, 0, 4, context.temp_allocator)
	climate: []gamedb.Weather_Chance
	if !interior {
		space := g.sim.trav.place.world
		gxy := world.grid_of(player_feet(g))
		if cell, ok := gamedb.cell_at(&g.db, space, gxy.x, gxy.y); ok {
			for id in gamedb.cell_regions(&g.db, cell) {
				if r, rok := gamedb.region_weather(&g.db, id); rok {
					append(&regions, weather.Region{id, r.override, r.priority, chances(r.weathers)})
				}
			}
		}
		climate = gamedb.climate_weathers(&g.db, gamedb.world_climate(&g.db, space))
	}
	wd := worldhost.Data{context, ws, &g.db}
	view := worldhost.world(&wd)
	inp := weather.Input {
		host     = {&view, nil},
		table    = &g.sim.weather,
		dt       = TICK_DT,
		hour     = f32(math.mod(ws.clock.hours, 24)),
		interior = interior,
		regions  = plugin.span(regions[:]),
		climate  = chances(climate),
		override = st.override,
		request  = st.request,
		instant  = st.instant,
		now      = {st.current, st.outgoing, st.transition, st.natural},
	}
	now := g.sim.weather.tick(&inp)
	st.current, st.outgoing, st.transition, st.natural = now.current, now.outgoing, now.transition, now.natural
	st.request, st.instant, st.inside = 0, false, interior
	clear(&ws.weathers_offered)
	for r in regions {
		for c in plugin.items(r.weathers) {append(&ws.weathers_offered, c.weather)}
	}
	for c in climate {append(&ws.weathers_offered, c.weather)}
}

// chances is a gamedb weather list as the seam's plain data: the same layout, so no copy.
@(private = "file")
chances :: proc(l: []gamedb.Weather_Chance) -> plugin.Span(weather.Chance) {
	#assert(size_of(gamedb.Weather_Chance) == size_of(weather.Chance))
	return {([^]weather.Chance)(raw_data(l)), len(l)}
}
