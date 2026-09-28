package sighthost

// The host side of the sight seam (src/sight): the table in force, the player's view, and the
// queries answered from worldstate and physics. Callers see through here.

import "base:runtime"
import "../gamedb"
import "../physics"
import "../sight"
import "../worldstate"

Form_ID :: sight.Form_ID
Mode :: sight.Mode

// View is what the player sees, published by the app before each script phase.
View :: struct {
	space: ^physics.World, // the active scene's physics; nil = nothing to see
	eye:   [3]f32,
	vp:    matrix[4, 4]f32,
}

view: View
table := sight.BUILTIN // the built-in, or a plugin's

level :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID, mode: Mode) -> f32 {
	d := Data{context, ws, db}
	h := host(&d)
	return table.level(&h, viewer, target, mode)
}

has_los :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID) -> bool {
	d := Data{context, ws, db}
	h := host(&d)
	return table.has_los(&h, viewer, target)
}

range :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer: Form_ID) -> f32 {
	d := Data{context, ws, db}
	h := host(&d)
	return table.range(&h, viewer)
}

light :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, ref: Form_ID) -> f32 {
	d := Data{context, ws, db}
	h := host(&d)
	return table.light(&h, ref)
}

@(private = "file")
Data :: struct {
	ctx: runtime.Context,
	ws:  ^worldstate.World_State,
	db:  ^gamedb.DB,
}

@(private = "file")
host :: proc(d: ^Data) -> sight.Host {
	return {d, d.ws.player, view.eye, view.vp, view.space != nil, body, hits, setting, awareness}
}

@(private = "file")
body :: proc "c" (data: rawptr, ref: Form_ID) -> (b: sight.Body) {
	d := (^Data)(data)
	context = d.ctx
	ws, db := d.ws, d.db
	b.loaded = worldstate.ref_3d_loaded(ws, db, ref)
	b.actor = gamedb.is_actor(db, worldstate.ref_base(ws, db, ref))
	if c, ok := gamedb.cell_by_formid(db, worldstate.ref_cell(ws, db, ref)); ok {b.interior = c.interior}
	b.pos = worldstate.ref_pos(ws, db, ref)
	b.heading = worldstate.ref_rot(ws, db, ref).z
	if b.actor {
		box := worldstate.actor_box(ws, db, ref)
		b.lo, b.hi = box[0].z, box[1].z
	} else if box, ok := gamedb.base_bounds(db, worldstate.ref_base(ws, db, ref)); ok {
		s := worldstate.ref_scale(ws, db, ref)
		b.lo, b.hi = box[0].z * s, box[1].z * s
	}
	return
}

@(private = "file")
hits :: proc "c" (data: rawptr, ray: sight.Ray, out: [^]sight.Hit, cap: int) -> int {
	d := (^Data)(data)
	context = d.ctx
	if view.space == nil {return 0}
	n := 0
	for h in physics.ray_hits(view.space, ray.from, ray.to, cutouts = true) {
		if n == cap {break}
		out[n] = {Form_ID(h.owner), h.cutout}
		n += 1
	}
	return n
}

@(private = "file")
setting :: proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32 {
	d := (^Data)(data)
	context = d.ctx
	return gamedb.setting_float(d.db, string(name), fallback)
}

@(private = "file")
awareness :: proc "c" (data: rawptr, viewer, target: Form_ID) -> f32 {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.awareness(d.ws, viewer, target).level
}
