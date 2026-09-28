package main

import "core:log"
import "../formid"
import "../gamedb"
import "../script"
import "../worldstate"

// tick_jail carries out the jail orders crime queued. Going in: the actor moves to the prison marker
// inside its faction's jail, its gear goes to the evidence chest (PLCN), it wears the jail outfit
// (JOUT) and the JAIL event goes out. Coming out: it moves to the jail's exterior marker (JAIL),
// gets its gear back, wears what it wore before, loses skill progress and the bounty clears.
tick_jail :: proc(g: ^Game) {
	c := script.Call{ws = &g.sim.ws, db = &g.db, audio = &g.audio, vfs = &g.v}
	for o in g.sim.ws.jail_orders {
		f, _ := worldstate.faction(&g.sim.ws, &g.db, o.faction)
		inside, outside, ok := worldstate.jail_spots(&g.sim.ws, &g.db, o.faction)
		if !ok {
			log.warnf("jail: faction 0x%X has no jail spots", o.faction)
			continue
		}
		log.infof("jail: %s 0x%X, faction 0x%X, cell 0x%X", "release" if o.release else "imprison", o.actor, o.faction, outside.cell if o.release else inside.cell)
		if o.release {release(g, &c, o, f, outside)} else {imprison(g, &c, o, f, inside)}
	}
	clear(&g.sim.ws.jail_orders)
}

@(private = "file")
imprison :: proc(g: ^Game, c: ^script.Call, o: worldstate.Jail_Order, f: gamedb.Faction, inside: worldstate.Jail_Spot) {
	bounty := worldstate.wanted(&g.sim.ws, o.actor, o.faction).bounty
	days := worldstate.jail_days(bounty)
	cell := inside.cell
	worldstate.relocate(&g.sim.ws, o.actor, cell, inside.pos, inside.rot)
	give_all(c, o.actor, f.player_chest, f.stolen_chest)
	before := g.sim.ws.outfits[o.actor]
	if f.jail_outfit != 0 {worldstate.set_outfit(&g.sim.ws, &g.db, o.actor, f.jail_outfit)}
	g.sim.ws.jailed[o.actor] = {faction = o.faction, cell = cell, until = g.sim.ws.clock.hours + f64(days) * 24, outfit = before}
	worldstate.queue_story_event(&g.sim.ws, {
		type      = worldstate.STORY_JAIL,
		ref1      = o.guard,
		form      = f.crime_group,
		location1 = worldstate.ref_location(&g.sim.ws, &g.db, f.jail),
		value1    = worldstate.total(bounty),
	})
}

@(private = "file")
release :: proc(g: ^Game, c: ^script.Call, o: worldstate.Jail_Order, f: gamedb.Faction, outside: worldstate.Jail_Spot) {
	j := g.sim.ws.jailed[o.actor]
	delete_key(&g.sim.ws.jailed, o.actor)
	worldstate.relocate(&g.sim.ws, o.actor, outside.cell, outside.pos, outside.rot)
	if f.jail_outfit != 0 {worldstate.restore_outfit(&g.sim.ws, &g.db, o.actor, j.outfit)}
	take_all(c, o.actor, f.player_chest)
	days := worldstate.jail_days(worldstate.wanted(&g.sim.ws, o.actor, o.faction).bounty)
	g.sim.ws.days_jailed[o.actor] += days
	worldstate.lose_skill_progress(&g.sim.ws, o.actor, days)
	worldstate.pay_bounty(&g.sim.ws, o.actor, o.faction)
}

// give_all moves everything `actor` carries, quest objects aside, into `chest`, its stolen things
// into `stolen_chest` when the jail has one.
@(private = "file")
give_all :: proc(c: ^script.Call, actor, chest, stolen_chest: Form_ID) {
	if chest == 0 {return}
	worldstate.unequip_all(c.ws, c.db, actor)
	for s in worldstate.inv_stacks(c.ws, c.db, actor) {
		to := stolen_chest if s.stolen && stolen_chest != 0 else chest
		if worldstate.quest_object_kept(c.ws, c.db, actor, s.item, to) {continue}
		script.move_items(c, {base = s.item, from = actor, to = to, count = s.count, stolen = s.stolen})
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
