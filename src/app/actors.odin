package main

// Actor bodies: every loaded actor ref gets a capsule, as the player does. The only differences are
// that nothing drives it yet and it is drawn.

import "../formid"
import "../gamedb"
import smath "../math"
import "../physics"
import "../render"
import "../script"
import "../world"
import "../worldstate"

// (hole actor-hitboxes :tags combat :sev gap :needs (animation)) a hit can only land on the one capsule; combat wants the race skeleton's per-bone colliders, posed each tick, with the weapon swept through them (Precision-style, the default).
// (hole actor-fall-through :tags physics :sev gap) seen 2026-09-25: one NPC capsule fell through the world and could not be picked; the cause is unknown and nothing catches a falling actor.
// (hole actor-ragdoll :tags (combat physics) :sev gap) a dead actor keeps its standing capsule; nothing falls as a ragdoll.

// Actor_Body is an actor's capsule. `placed` is the ref position it was last put at, so a script
// move teleports it and a fall does not.
Actor_Body :: struct {
	char:    physics.Character,
	placed:  smath.Vec3,
	capsule: Capsule,
}

Capsule :: struct {
	radius, half_h: f32,
}

// (hole actor-capsule-source :tags (player physics) :sev polish) the capsule is fitted to the OBND box (radius = mean half-width, height = box height); whether Skyrim sizes its controller from OBND is unsourced, and a long body (horse, mammoth) is one upright cylinder.
// actor_capsule fits an upright capsule to an actor's bounds at its scale.
actor_capsule :: proc(g: ^Game, form: Form_ID) -> Capsule {
	c := script.Call{ws = &g.ws, db = &g.db}
	box := gamedb.actor_bounds(&g.db, worldstate.record_of(&g.ws, form), worldstate.actor_pick(&g.ws, &g.db, form))
	size := (box[1] - box[0]) * script.ref_scale(&c, form)
	radius := (size.x + size.y) / 4
	return {radius, max(size.z / 2 - radius, 1)}
}

// tick_actor_bodies gives each actor in the active scene's loaded cells a capsule, moves it one
// tick, and drops the capsules of actors that left or were disabled.
tick_actor_bodies :: proc(g: ^Game) {
	phys := g.fr.active_scene.phys
	if phys == nil {return}
	c := script.Call{ws = &g.ws, db = &g.db}
	seen := make(map[Form_ID]bool, context.temp_allocator)
	for cell, &chunk in g.fr.active_scene.chunks {
		for form in chunk.actors {
			if d, ok := worldstate.get(&g.ws, form); !ok || .Moved not_in d.live || d.cell == cell {actor_body_keep(g, &c, phys, form, &seen)}
		}
		for form in worldstate.created_in(&g.ws, cell) {actor_body_keep(g, &c, phys, form, &seen)}
		for form in worldstate.refs_in(&g.ws, cell) {
			if d, _ := worldstate.get(&g.ws, form); .Moved in d.live {actor_body_keep(g, &c, phys, form, &seen)} // moved in by a script
		}
	}
	gone := make([dynamic]Form_ID, context.temp_allocator)
	for form, &b in g.actor_bodies {
		if form in seen {
			physics.character_move(phys, &b.char, {}, false, TICK_DT)
		} else {
			physics.character_destroy(&b.char)
			append(&gone, form)
		}
	}
	for form in gone {delete_key(&g.actor_bodies, form)}
}

@(private = "file")
actor_body_keep :: proc(g: ^Game, c: ^script.Call, phys: ^physics.World, form: Form_ID, seen: ^map[Form_ID]bool) {
	if form == formid.PLAYER || form in seen || !is_actor_ref(g, form) || !script.ref_enabled(&g.ws, &g.db, form) {return}
	seen[form] = true
	pos := script.ref_pos(c, form)
	capsule := actor_capsule(g, form)
	if b, ok := &g.actor_bodies[form]; ok && b.capsule == capsule {
		if b.placed != pos {
			physics.character_set_position(&b.char, pos)
			b.placed = pos
		}
		return
	} else if ok {
		physics.character_destroy(&b.char) // resized (SetScale): rebuild at the ref
	}
	if ch, ok := physics.character_create(phys, pos, capsule.radius, capsule.half_h); ok {
		g.actor_bodies[form] = {ch, pos, capsule}
	} else {
		delete_key(&g.actor_bodies, form)
	}
}

@(private = "file")
is_actor_ref :: proc(g: ^Game, form: Form_ID) -> bool {
	return gamedb.is_actor(&g.db, worldstate.ref_base(&g.ws, &g.db, form))
}

actor_bodies_clear :: proc(g: ^Game) {
	for _, &b in g.actor_bodies {physics.character_destroy(&b.char)}
	clear(&g.actor_bodies)
}

// actor_box is the wire box drawn and picked for an actor capsule, from its feet to its top.
@(private = "file")
actor_box :: proc(g: ^Game, b: ^Actor_Body, grow: f32 = 0) -> [2]smath.Vec3 {
	feet := physics.character_render_position(&b.char, g.tick.alpha)
	r := b.capsule.radius + grow
	return {feet - {r, r, grow}, feet + {r, r, 2 * (b.capsule.half_h + b.capsule.radius) + grow}}
}

// pick_actor is the nearest actor box along a ray.
pick_actor :: proc(g: ^Game, origin, dir: smath.Vec3) -> (form: Form_ID, dist: f32, ok: bool) {
	dist = max(f32)
	for f, &b in g.actor_bodies {
		box := actor_box(g, &b)
		if t, hit := world.ray_aabb(origin, dir, box[0], box[1]); hit && t < dist {
			form, dist, ok = f, t, true
		}
	}
	return
}

// draw_actor_bodies draws each NPC capsule as a wire box; the hovered one gets a second, larger box.
draw_actor_bodies :: proc(g: ^Game, vp: smath.Mat4) {
	render.release_mesh(&g.r, g.actor_wire)
	g.actor_wire = {}
	if len(g.actor_bodies) == 0 {return}
	verts := make([dynamic]render.Mesh_Vertex, 0, 8 * len(g.actor_bodies), context.temp_allocator)
	idx := make([dynamic]u16, 0, 36 * len(g.actor_bodies), context.temp_allocator)
	for f, &b in g.actor_bodies {
		if len(verts) > 60000 {break}
		world.emit_aabb(&verts, &idx, actor_box(g, &b))
		if f == g.hover_actor {world.emit_aabb(&verts, &idx, actor_box(g, &b, 3))}
	}
	g.actor_wire = render.upload_mesh(&g.r, verts[:], idx[:])
	render.draw_wire(&g.r, g.actor_wire, vp)
}
