package main

// The host side of the magicphys seam (src/magicphys): the casts since the last tick, the live
// spell bodies, and applying what the model answers.

import "base:runtime"
import "core:math"
import "core:strings"
import "../gamedb"
import "../magic"
import "../magicphys"
import "../physics"
import "../plugin"
import "../script"
import smath "../math"
import "../worldhost"
import "../world"
import "../worldstate"

Spell_Bodies :: struct {
	list:    [dynamic]magicphys.Body,
	next:    magicphys.Body_ID,
	markers: [dynamic]Form_ID, // where placing spells landed, kept while an effect targets them
}

@(private = "file")
Magicphys_Host :: struct {
	ctx:     runtime.Context,
	ws:      ^worldstate.World_State,
	db:      ^gamedb.DB,
	phys:    ^physics.World, // nil: nothing is struck
	bodies:  ^Spell_Bodies,
	puts:    [dynamic]magicphys.Body, // spawns too
	removes: [dynamic]magicphys.Body_ID,
	hits:    [dynamic]magic.Hit,
	places:  [dynamic]Place,
}

@(private = "file")
Place :: struct {
	spell, caster: Form_ID,
	pos:           [3]f32,
}

// tick_magicphys runs the magicphys seam over the casts since the last tick.
tick_magicphys :: proc(g: ^Game) {
	ws := &g.sim.ws
	defer clear(&ws.launches)
	casts := make([dynamic]magicphys.Cast, 0, len(ws.launches), context.temp_allocator)
	for l in ws.launches {
		from := worldstate.actor_chest(ws, &g.db, l.caster)
		aim := smath.normalize3(worldstate.actor_chest(ws, &g.db, l.target) - from) if l.target != 0 else facing(ws, &g.db, l.caster)
		append(&casts, magicphys.Cast{l.spell, l.caster, l.target, from, aim})
	}
	sp := active_space(g)
	h := Magicphys_Host{ctx = context, ws = ws, db = &g.db, phys = sp.phys if sp != nil else nil, bodies = &g.sim.spell_bodies}
	h.puts.allocator, h.removes.allocator, h.hits.allocator, h.places.allocator = context.temp_allocator, context.temp_allocator, context.temp_allocator, context.temp_allocator
	wd := worldhost.Data{context, ws, &g.db}
	view := worldhost.world(&wd)
	inp := magicphys.Input {
		host    = {&view, &h, magicphys_def, magicphys_anchor, magicphys_strike, magicphys_spawn, magicphys_put, magicphys_remove, magicphys_hit, magicphys_place},
		table   = &g.sim.magicphys,
		dt      = TICK_DT,
		gravity = physics.GRAVITY,
		actors  = plugin.span(g.sim.actors.actors[:]),
		casts   = plugin.span(casts[:]),
		bodies  = plugin.span(g.sim.spell_bodies.list[:]),
	}
	g.sim.magicphys.tick(&inp)
	apply_bodies(&g.sim.spell_bodies, h.puts[:], h.removes[:])
	c := script.Call{ws = ws, db = &g.db}
	for hit in h.hits {script.start_spell(&c, hit.spell, hit.target, hit.caster)}
	for p in h.places {
		marker := worldstate.create_ref(ws, world.XMARKER, landing_cell(ws, &g.db, p.caster, p.pos), p.pos, {}, 1)
		append(&g.sim.spell_bodies.markers, marker)
		script.start_spell(&c, p.spell, marker, p.caster)
	}
	drop_markers(ws, &g.db, &g.sim.spell_bodies.markers)
}

// landing_cell is the cell at `pos` in `near`'s worldspace; in an interior, `near`'s cell.
@(private = "file")
landing_cell :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, near: Form_ID, pos: [3]f32) -> Form_ID {
	cell := worldstate.ref_cell(ws, db, near)
	if c, ok := db.cells[cell]; ok && c.interior {return cell}
	under := gamedb.cell_under(db, worldstate.ref_space(ws, db, near), pos)
	return under if under != 0 else cell
}

// drop_markers deletes the landing markers no running effect targets: what a landing placed (a
// zone, a summon) is its own ref.
@(private = "file")
drop_markers :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, markers: ^[dynamic]Form_ID) {
	#reverse for m, i in markers {
		held := false
		for _, e in ws.effects {
			if e.target == m && !e.ended {held = true; break}
		}
		if held {continue}
		worldstate.set_deleted(ws, m, worldstate.ref_cell(ws, db, m))
		unordered_remove(markers, i)
	}
}

// (hole spell-body-saves :tags (magic save) :sev gap) spell bodies and landing markers are not saved: a spell in flight at a save is gone after a load, and a marker an effect still held at the save is never deleted.
spell_bodies_destroy :: proc(b: ^Spell_Bodies) {
	delete(b.list)
	delete(b.markers)
}

@(private = "file")
apply_bodies :: proc(b: ^Spell_Bodies, puts: []magicphys.Body, removes: []magicphys.Body_ID) {
	put: for p in puts {
		for &have in b.list {
			if have.id == p.id {have = p; continue put}
		}
		append(&b.list, p)
	}
	for id in removes {
		for have, i in b.list {
			if have.id == id {unordered_remove(&b.list, i); break}
		}
	}
}

@(private = "file")
facing :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: Form_ID) -> [3]f32 {
	yaw := worldstate.ref_rot(ws, db, actor).z
	return {math.sin(yaw), math.cos(yaw), 0}
}

// magicphys_def is a defined spell's shape; a record's has none until magic-translate defines it.
@(private = "file")
magicphys_def :: proc "c" (data: rawptr, spell: Form_ID) -> magicphys.Def {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	d, ok := h.ws.spell_defs[spell]
	if !ok {return {}}
	return {d.shape, strings.clone_to_cstring(d.anchor, context.temp_allocator)}
}

// (hole thick-strike :tags (magic physics) :sev polish :needs (shape-cast)) a strike is a thin ray: the radius is ignored, so a thick beam or projectile slips past what only its edge would touch.
@(private = "file")
magicphys_strike :: proc "c" (data: rawptr, from, to: [3]f32, radius: f32, skip: Form_ID) -> magicphys.Strike {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	if h.phys == nil {return {}}
	for r in physics.ray_hits(h.phys, from, to) {
		other := Form_ID(r.owner)
		if other == skip && skip != 0 {continue}
		return {true, other, from + (to - from) * r.fraction}
	}
	return {}
}

// (hole anchor-names :tags (magic animation) :sev gap :needs (animation)) every anchor is the chest, facing the actor's way: "hand.left", "hand.right" and the rest need the skeleton's nodes.
@(private = "file")
magicphys_anchor :: proc "c" (data: rawptr, actor: Form_ID, name: cstring) -> magicphys.Anchor {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	return {worldstate.actor_chest(h.ws, h.db, actor), facing(h.ws, h.db, actor)}
}

@(private = "file")
magicphys_spawn :: proc "c" (data: rawptr, b: magicphys.Body) -> magicphys.Body_ID {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	h.bodies.next += 1
	body := b
	body.id = h.bodies.next
	append(&h.puts, body)
	return body.id
}

@(private = "file")
magicphys_put :: proc "c" (data: rawptr, b: magicphys.Body) {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	append(&h.puts, b)
}

@(private = "file")
magicphys_remove :: proc "c" (data: rawptr, id: magicphys.Body_ID) {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	append(&h.removes, id)
}

// (hole area-entries :tags magic :sev gap) a hit lands every entry of the spell: `hits = "direct"` entries (62 of 227 area spells mix areas) land on area hits too, and an actor struck and in the burst gets the spell once, as a direct hit.
@(private = "file")
magicphys_hit :: proc "c" (data: rawptr, hit: magic.Hit) {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	append(&h.hits, hit)
}

@(private = "file")
magicphys_place :: proc "c" (data: rawptr, spell, caster: Form_ID, pos: [3]f32) {
	h := (^Magicphys_Host)(data)
	context = h.ctx
	append(&h.places, Place{spell, caster, pos})
}
