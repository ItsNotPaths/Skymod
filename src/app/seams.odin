package main

// The host side of the plugin seams (ws.md Workstream H): the actor snapshot every seam reads, and
// each seam's host procs over worldstate.

import "base:runtime"
import "../actorstate"
import "../detection"
import "../gamedb"
import smath "../math"
import "../plugin"
import "../sight"
import "../worldstate"

// Actor_Snapshot is the loaded actors as the seams see them, rebuilt each tick.
Actor_Snapshot :: struct {
	actors: [dynamic]plugin.Actor,
	last:   map[Form_ID][3]f32, // where each stood at the last snapshot
	ticks:  u64, // snapshots built
}

actor_snapshot :: proc(s: ^Actor_Snapshot, ws: ^worldstate.World_State, db: ^gamedb.DB, loaded: map[Form_ID]bool, dt: f32) {
	s.ticks += 1
	clear(&s.actors)
	for a in loaded {
		pos := worldstate.ref_pos(ws, db, a)
		cell, _ := gamedb.cell_by_formid(db, worldstate.ref_cell(ws, db, a))
		was, moved := s.last[a]
		append(&s.actors, plugin.Actor {
			id       = a,
			space    = worldstate.ref_space(ws, db, a),
			interior = cell.interior,
			pos      = pos,
			speed    = smath.length3(pos - was) / dt if moved else 0,
			dead     = worldstate.is_dead(ws, db, a),
			sneaking = actorstate.current(&ws.states, a) == actorstate.SNEAK,
		})
	}
	clear(&s.last)
	for a in s.actors {s.last[a.id] = a.pos}
}

actor_snapshot_destroy :: proc(s: ^Actor_Snapshot) {
	delete(s.actors)
	delete(s.last)
}

Detection_Host :: struct {
	ctx:  runtime.Context,
	ws:   ^worldstate.World_State,
	db:   ^gamedb.DB,
	sets: [dynamic]detection.Pair,
}

// detection_tick runs the detection seam over the snapshot and applies what it sets.
detection_tick :: proc(t: ^detection.Table, s: ^Actor_Snapshot, ws: ^worldstate.World_State, db: ^gamedb.DB, dt: f32) {
	known := make([dynamic]detection.Pair, 0, len(ws.awareness), context.temp_allocator)
	for k, a in ws.awareness {append(&known, detection.Pair{k[0], k[1], {a.level, a.detected}})}
	h := Detection_Host{context, ws, db, make([dynamic]detection.Pair, context.temp_allocator)}
	inp := detection.Input {
		host   = {&h, detection_sight, detection_range, detection_light, detection_known, detection_set},
		table  = t,
		tick   = s.ticks,
		dt     = dt,
		actors = plugin.span(s.actors[:]),
		known  = plugin.span(known[:]),
	}
	t.tick(&inp)
	for p in h.sets {worldstate.set_awareness(ws, p.viewer, p.target, {p.awareness.level, p.awareness.detected})}
}

@(private = "file")
detection_sight :: proc "c" (data: rawptr, viewer, target: Form_ID) -> f32 {
	h := (^Detection_Host)(data)
	context = h.ctx
	return sight.level(h.ws, h.db, viewer, target, .Cone)
}

@(private = "file")
detection_range :: proc "c" (data: rawptr, viewer: Form_ID) -> f32 {
	h := (^Detection_Host)(data)
	context = h.ctx
	return sight.range(h.ws, h.db, viewer)
}

@(private = "file")
detection_light :: proc "c" (data: rawptr, target: Form_ID) -> f32 {
	h := (^Detection_Host)(data)
	context = h.ctx
	return sight.light_at(h.ws, h.db, worldstate.ref_pos(h.ws, h.db, target))
}

@(private = "file")
detection_known :: proc "c" (data: rawptr, viewer, target: Form_ID) -> detection.Awareness {
	h := (^Detection_Host)(data)
	context = h.ctx
	a := worldstate.awareness(h.ws, viewer, target)
	return {a.level, a.detected}
}

@(private = "file")
detection_set :: proc "c" (data: rawptr, p: detection.Pair) {
	h := (^Detection_Host)(data)
	context = h.ctx
	append(&h.sets, p)
}
