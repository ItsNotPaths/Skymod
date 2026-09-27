package main

import "../formid"
import "../gamedb"
import "../script"
import "../worldstate"

// tick_jail carries out the jail orders crime queued. Going in: the actor moves to the prison marker
// inside its faction's jail, its gear goes to the evidence chest (PLCN), it wears the jail outfit
// (JOUT) and the JAIL event goes out. Coming out: it moves to the jail's exterior marker (JAIL),
// gets its gear back, wears what it wore before, loses skill progress and the bounty clears.
tick_jail :: proc(g: ^Game) {
	c := script.Call{ws = &g.ws, db = &g.db, audio = &g.audio, vfs = &g.v}
	for o in g.ws.jail_orders {
		f, _ := worldstate.faction(&g.ws, &g.db, o.faction)
		outside, ok := gamedb.ref_by_formid(&g.db, f.jail)
		if !ok || !outside.has_tp {continue}
		if o.release {release(g, &c, o, f, outside)} else {imprison(g, &c, o, f, outside)}
	}
	clear(&g.ws.jail_orders)
}

@(private = "file")
imprison :: proc(g: ^Game, c: ^script.Call, o: worldstate.Jail_Order, f: gamedb.Faction, outside: gamedb.Ref) {
	inside := outside.teleport
	bounty := worldstate.wanted(&g.ws, o.actor, o.faction).bounty
	days := worldstate.jail_days(bounty)
	cell := worldstate.ref_cell(&g.ws, &g.db, inside.door)
	worldstate.relocate(&g.ws, o.actor, cell, inside.pos, inside.rot)
	give_all(c, o.actor, f.player_chest)
	before := g.ws.outfits[o.actor]
	if f.jail_outfit != 0 {worldstate.set_outfit(&g.ws, &g.db, o.actor, f.jail_outfit)}
	g.ws.jailed[o.actor] = {faction = o.faction, cell = cell, until = g.ws.clock.hours + f64(days) * 24, outfit = before}
	worldstate.queue_story_event(&g.ws, {
		type      = worldstate.STORY_JAIL,
		ref1      = o.guard,
		form      = f.crime_group,
		location1 = worldstate.ref_location(&g.ws, &g.db, inside.door),
		value1    = worldstate.total(bounty),
	})
}

@(private = "file")
release :: proc(g: ^Game, c: ^script.Call, o: worldstate.Jail_Order, f: gamedb.Faction, outside: gamedb.Ref) {
	j := g.ws.jailed[o.actor]
	delete_key(&g.ws.jailed, o.actor)
	worldstate.relocate(&g.ws, o.actor, outside.cell_form_id, outside.pos, outside.rot)
	if f.jail_outfit != 0 {worldstate.restore_outfit(&g.ws, &g.db, o.actor, j.outfit)}
	take_all(c, o.actor, f.player_chest)
	worldstate.lose_skill_progress(&g.ws, o.actor, worldstate.jail_days(worldstate.wanted(&g.ws, o.actor, o.faction).bounty))
	worldstate.pay_bounty(&g.ws, o.actor, o.faction)
}

// give_all moves everything `actor` carries, quest objects aside, into `chest`.
@(private = "file")
give_all :: proc(c: ^script.Call, actor, chest: Form_ID) {
	if chest == 0 {return}
	worldstate.unequip_all(c.ws, c.db, actor)
	for item in worldstate.inv_items(c.ws, c.db, actor) {
		if worldstate.quest_object_kept(c.ws, c.db, actor, item, chest) {continue}
		script.move_items(c, {base = item, from = actor, to = chest, count = worldstate.inv_count(c.ws, c.db, actor, item)})
	}
}

// take_all moves everything in `chest` back to `actor`.
@(private = "file")
take_all :: proc(c: ^script.Call, actor, chest: Form_ID) {
	if chest == 0 {return}
	for item in worldstate.inv_items(c.ws, c.db, chest) {
		script.move_items(c, {base = item, from = chest, to = actor, count = worldstate.inv_count(c.ws, c.db, chest, item)})
	}
}
