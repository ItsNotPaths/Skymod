package main

import "core:log"
import "core:math/linalg"
import "../audio"
import "../collisions"
import "../formid"
import "../gamedb"
import "../models"
import smath "../math"
import "../physics"
import "../script"
import "../world"
import "../worldstate"

// tick_projectiles launches the Weapon.Fire calls scripts made, then moves each flight one tick.
tick_projectiles :: proc(g: ^Game) {
	if sp := active_space(g); sp == nil || sp.phys == nil {return}
	for f in g.sim.ws.fires {fire(g, f)}
	clear(&g.sim.ws.fires)
	c := script.Call{ws = &g.sim.ws, db = &g.db}
	flights := &g.sim.ws.projectiles
	for i := len(flights) - 1; i >= 0; i -= 1 {
		if !fly(g, &c, &flights[i]) {unordered_remove(flights, i)}
	}
}

// (hole fire-without-ammo :tags (combat script mods) :sev polish) Weapon.Fire with no ammo launches nothing. No vanilla ref does it (the two scripts that pass None attach to nothing), and a WEAP names no projectile, so a default would be ours: a data-driven projectile per weapon type, for mods.
// fire launches a Weapon.Fire from the source's ProjectileNode (an actor's chest, else its origin
// without one), along the node's +Y, once the archcost hooks let it go; the Stamina they set is spent.
@(private = "file")
fire :: proc(g: ^Game, f: worldstate.Fire) {
	ammo, _ := gamedb.equip_slot_of(&g.db, f.ammo)
	if ammo.projectile == 0 {
		log.warnf("Weapon.Fire: 0x%X fired no ammo projectile (ammo 0x%X)", u64(f.weapon), u64(f.ammo))
		return
	}
	cost, ok := worldstate.weapon_cost(&g.sim.ws, f.source, f.weapon, {}, true, 0)
	if !ok {return}
	if cost > 0 {worldstate.av_damage(&g.sim.ws, &g.db, f.source, "Stamina", cost)}
	weapon, _ := gamedb.equip_slot_of(&g.db, f.weapon)
	m := smath.trs(worldstate.ref_pos(&g.sim.ws, &g.db, f.source), worldstate.ref_rot(&g.sim.ws, &g.db, f.source), worldstate.ref_scale(&g.sim.ws, &g.db, f.source))
	has_node := false
	if modl, ok := gamedb.model_of(&g.db, worldstate.ref_base(&g.sim.ws, &g.db, f.source)); ok {
		if node, nok := collisions.projectile_node(&g.collisions, models.intern(modl)); nok {m, has_node = m * node, true}
	}
	pos, dir := (m * [4]f32{0, 0, 0, 1}).xyz, (m * [4]f32{0, 1, 0, 0}).xyz
	if is_actor_ref(g, f.source) && !has_node {pos = worldstate.actor_chest(&g.sim.ws, &g.db, f.source)}
	cell := worldstate.ref_cell(&g.sim.ws, &g.db, f.source)
	worldstate.launch(&g.sim.ws, &g.db, ammo.projectile, cell, pos, dir, f.source, f.weapon, weapon.damage + ammo.damage)
}

// fly moves one flight a tick; false once it is done. Its body gets the flight's pos and velocity the
// first tick it exists. Past its range it falls, and it is lost at twice the range.
@(private = "file")
fly :: proc(g: ^Game, c: ^script.Call, f: ^worldstate.Flight) -> bool {
	sp := active_space(g)
	if worldstate.is_deleted(&g.sim.ws, f.ref) {return false}
	if worldstate.ref_cell(&g.sim.ws, &g.db, f.ref) not_in sp.cells {return true} // unloaded: it waits
	r, _, ok := world.find_ref(sp, f.ref)
	if !ok {return true}
	if r.dyn_body == 0 {return !r.phys_built} // body not built yet, or it never will be
	b := r.dyn_body
	p, _ := gamedb.projectile_of(&g.db, r.base)
	if !f.launched {
		physics.launch(sp.phys, b, f.pos, f.vel, p.gravity)
		f.launched = true
	}
	f.pos, f.vel = physics.body_origin(sp.phys, b), physics.body_velocity(sp.phys, b)
	if linalg.length(f.vel) < 1 {return true}
	dir := linalg.normalize(f.vel)
	aim := smath.normalize3((r.world * [4]f32{0, 1, 0, 0}).xyz) // the body turns the placed ref
	physics.set_rotation(sp.phys, b, linalg.quaternion_between_two_vector3(aim, dir))

	// From the body to its tip one step on: an arrow's origin is its tip, a dart's is mid-shaft.
	mc, _ := collisions.of(sp.collisions, r.model_id)
	tip := mc.hi.y * r.scale if mc != nil else 0
	from := physics.body_position(sp.phys, b)
	to := f.pos + dir * tip + f.vel * TICK_DT
	for h in physics.ray_hits(sp.phys, from, to) {
		target := Form_ID(h.owner)
		if target == f.ref || target == f.shooter || is_projectile(g, target) {continue}
		audio.impact_sound(&g.db, r.base, target, from + (to - from) * h.fraction)
		if live_actor(g, target) {
			script.projectile_hit(c, f^, target)
			worldstate.set_deleted(&g.sim.ws, f.ref, worldstate.ref_cell(&g.sim.ws, &g.db, f.ref))
			worldstate.mark_scene_dirty(&g.sim.ws, f.ref)
			return false
		}
		if target != 0 {
			script.queue_hit(c, f^, target)
			worldstate.damage_object(&g.sim.ws, &g.db, target, f.damage, true)
		}
		embed(g, sp, r, from + (to - from) * h.fraction - dir * (tip - EMBED_DEPTH), dir)
		return false
	}
	f.travelled += linalg.length(f.vel) * TICK_DT
	if f.travelled > p.range {physics.set_gravity_factor(sp.phys, b, 1)}
	return f.travelled <= 2 * p.range
}

// How far a landed projectile's tip sinks into what it hit.
EMBED_DEPTH :: f32(4)

// (hole projectile-ricochet :tags (physics combat unclaimed) :sev polish) every projectile embeds where it lands; none ricochets, bounces, slides or breaks. Wanted: by angle, speed and surface material.
// (hole spent-projectile-cleanup :tags (world save) :sev polish) embedded darts and arrows stay as created refs forever; nothing removes them after a while.
// embed stops a projectile with its origin at `pos`, pointing along dir: a still ref with no body.
@(private = "file")
embed :: proc(g: ^Game, sp: ^world.Space, r: ^world.Sim_Ref, pos, dir: [3]f32) {
	r.in_flight = false // its body goes when the move below rebuilds its collision
	physics.launch(sp.phys, r.dyn_body, pos, {}, 0)
	worldstate.relocate(&g.sim.ws, r.form_id, worldstate.ref_cell(&g.sim.ws, &g.db, r.form_id), pos, worldstate.heading_rot(dir))
}

@(private = "file")
is_projectile :: proc(g: ^Game, form: Form_ID) -> bool {
	_, ok := gamedb.projectile_of(&g.db, worldstate.ref_base(&g.sim.ws, &g.db, form))
	return ok
}

@(private)
live_actor :: proc(g: ^Game, form: Form_ID) -> bool {
	return form != 0 && gamedb.is_actor(&g.db, worldstate.ref_base(&g.sim.ws, &g.db, form)) && !worldstate.is_dead(&g.sim.ws, &g.db, form)
}
