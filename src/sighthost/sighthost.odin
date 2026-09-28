package sighthost

// The host side of the sight seam (src/sight): the table in force, the player's view and the ray
// casts; the world is worldhost's. Callers see through here.

import "core:time"
import "../gamedb"
import "../physics"
import "../plugin"
import "../sight"
import "../worldhost"
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
ms: f64 // time in the table's procs since the profile last took it

level :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID, mode: Mode) -> f32 {
	d := worldhost.Data{context, ws, db}
	w := worldhost.world(&d)
	h := host(&d, &w)
	defer timed(time.tick_now())
	return table.level(&h, viewer, target, mode)
}

has_los :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID) -> bool {
	d := worldhost.Data{context, ws, db}
	w := worldhost.world(&d)
	h := host(&d, &w)
	defer timed(time.tick_now())
	return table.has_los(&h, viewer, target)
}

range :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer: Form_ID) -> f32 {
	d := worldhost.Data{context, ws, db}
	w := worldhost.world(&d)
	h := host(&d, &w)
	defer timed(time.tick_now())
	return table.range(&h, viewer)
}

light :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, ref: Form_ID) -> f32 {
	d := worldhost.Data{context, ws, db}
	w := worldhost.world(&d)
	h := host(&d, &w)
	defer timed(time.tick_now())
	return table.light(&h, ref)
}

@(private = "file")
timed :: proc(from: time.Tick) {
	ms += time.duration_milliseconds(time.tick_since(from))
}

@(private = "file")
host :: proc(d: ^worldhost.Data, w: ^plugin.World) -> sight.Host {
	return {w, d, view.eye, view.vp, view.space != nil, hits}
}

@(private = "file")
hits :: proc "c" (data: rawptr, ray: sight.Ray, out: [^]sight.Hit, cap: int) -> int {
	context = (^worldhost.Data)(data).ctx
	if view.space == nil {return 0}
	n := 0
	for h in physics.ray_hits(view.space, ray.from, ray.to, cutouts = true) {
		if n == cap {break}
		out[n] = {Form_ID(h.owner), h.cutout}
		n += 1
	}
	return n
}
