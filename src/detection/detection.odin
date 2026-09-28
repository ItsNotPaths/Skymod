package detection

// Detection: each loaded NPC looks at each loaded actor in its range ten times a second, and the
// model (model.odin) turns what it senses into awareness. This is a seam (ws.md Workstream H): the
// host hands in the actor snapshot and the awareness store, answers the sight queries, and applies
// the awareness each `set` reports. A plugin replaces entries of Table.

import "core:math"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_detection"
VERSION :: u32(1)

GROUPS :: 6 // viewers take turns: at 60 Hz each looks every 0.1 s
FAR :: f32(1e9) // the distance to a target not in the viewer's space

Awareness :: struct {
	level:    f32,
	detected: bool,
}

// Pair is one viewer's awareness of one target.
Pair :: struct {
	viewer, target: Form_ID,
	awareness:      Awareness,
}

// Host is what the engine answers and takes; each proc gets `data` back.
Host :: struct {
	data:  rawptr,
	sight: proc "c" (data: rawptr, viewer, target: Form_ID) -> f32, // sight.Mode.Cone, 0..1
	range: proc "c" (data: rawptr, viewer: Form_ID) -> f32, // how far the viewer sees
	light: proc "c" (data: rawptr, target: Form_ID) -> f32, // at the target, 0 dark .. 1 lit
	known: proc "c" (data: rawptr, viewer, target: Form_ID) -> Awareness, // the store before this tick
	set:   proc "c" (data: rawptr, p: Pair), // applied in order after tick returns: a later set of a pair wins
}

Input :: struct {
	host:   Host,
	table:  ^Table, // the table in force, so the built-in tick calls a replaced judge
	tick:   u64,
	dt:     f32,
	actors: plugin.Span(plugin.Actor), // the loaded actors, the player's too
	known:  plugin.Span(Pair), // the whole awareness store before this tick
}

Table :: struct {
	tick:  proc "c" (inp: ^Input),
	judge: proc "c" (was: Awareness, s: Senses, dt: f32) -> Awareness,
}

BUILTIN :: Table{tick_builtin, judge_builtin}

// tick_builtin runs one group of viewers: what each knows fades, then it looks at every living
// actor in its range.
tick_builtin :: proc "c" (inp: ^Input) {
	h := inp.host
	step := inp.dt * GROUPS
	for k in plugin.items(inp.known) {
		if my_turn(inp.tick, k.viewer) {h.set(h.data, {k.viewer, k.target, inp.table.judge(k.awareness, {distance = FAR}, step)})}
	}
	actors := plugin.items(inp.actors)
	for viewer in actors {
		if !my_turn(inp.tick, viewer.id) || viewer.dead {continue}
		reach := h.range(h.data, viewer.id)
		for target in actors {
			d, ok := looks_at(viewer, target, reach)
			if !ok {continue}
			senses := Senses {
				sight    = h.sight(h.data, viewer.id, target.id),
				distance = d,
				speed    = target.speed,
				sneaking = target.sneaking,
				light    = h.light(h.data, target.id),
				noise    = heard(viewer.id, target.id),
			}
			h.set(h.data, {viewer.id, target.id, inp.table.judge(h.known(h.data, viewer.id, target.id), senses, step)})
		}
	}
}

@(private = "file")
my_turn :: proc "contextless" (tick: u64, viewer: Form_ID) -> bool {
	return (u64(viewer) + tick) % GROUPS == 0
}

// looks_at: the viewer looks at the target this tick, at distance d.
@(private = "file")
looks_at :: proc "contextless" (viewer, target: plugin.Actor, reach: f32) -> (d: f32, ok: bool) {
	if target.id == viewer.id || target.dead {return}
	v := viewer.pos - target.pos
	d = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z) if viewer.space != 0 && viewer.space == target.space else FAR
	return d, d <= reach
}

// (hole noise-events :tags (ai audio unclaimed) :sev gap) nothing is heard: every target is silent to every viewer.
@(private = "file")
heard :: proc "contextless" (viewer, target: Form_ID) -> f32 {
	return 0
}
