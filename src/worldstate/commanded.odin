package worldstate

import "core:slice"
import "../gamedb"

// Commanded is an actor a magic effect summoned or raised: it takes the side of the effect's caster
// until the effect ends.
Commanded :: struct {
	by, effect: Form_ID,
}

// command makes `actor` fight for the caster of `effect`. Past the caster's CommandedActorLimit, the
// effects of its oldest commanded actors end.
command :: proc(ws: ^World_State, db: ^gamedb.DB, actor, effect: Form_ID) {
	e, ok := ws.effects[effect]
	if !ok || e.ended {return}
	ws.commanded[actor] = {e.caster, effect}
	mine := make([dynamic]Form_ID, context.temp_allocator)
	for _, c in ws.commanded {
		if c.by == e.caster {append(&mine, c.effect)}
	}
	slice.sort(mine[:]) // handles grow: the first is the oldest
	limit := max(int(av_current(ws, db, e.caster, "CommandedActorLimit")), 1)
	for h in mine[:max(len(mine) - limit, 0)] {end_effect(ws, h)}
}

// commander_of is the actor whose side `actor` takes: its commander, else itself.
commander_of :: proc(ws: ^World_State, actor: Form_ID) -> Form_ID {
	c, ok := ws.commanded[actor]
	return c.by if ok else actor
}

// release drops the actors that the effect `h` commanded.
@(private)
release :: proc(ws: ^World_State, h: Form_ID) {
	gone := make([dynamic]Form_ID, context.temp_allocator)
	for actor, c in ws.commanded {
		if c.effect == h {append(&gone, actor)}
	}
	for actor in gone {delete_key(&ws.commanded, actor)}
}

// create_commanded_limit makes CommandedActorLimit, how many summoned or raised actors one caster
// keeps at once: 1.
create_commanded_limit :: proc(ws: ^World_State) {
	av_create(ws, "CommandedActorLimit", 1, .Static)
}

@(private)
save_commanded :: proc(ws: ^World_State) -> []Saved_Commanded {
	out := make([dynamic]Saved_Commanded, 0, len(ws.commanded), context.temp_allocator)
	for actor, c in ws.commanded {append(&out, Saved_Commanded{actor, c})}
	return out[:]
}
