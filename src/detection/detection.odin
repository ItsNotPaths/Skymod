package detection

// Detection: each loaded NPC looks at each loaded actor in its range ten times a second, and the
// model (model.odin) turns what it senses into awareness. This is a seam (ws.md Workstream H): the
// host hands in the actor snapshot, the noises and the awareness store, answers the sight
// queries, and applies the awareness each `set` reports. A plugin replaces entries of Table.

import "core:math"
import "../plugin"

Form_ID :: plugin.Form_ID

SEAM :: "skymod_detection"
VERSION :: u32(2)

GROUPS :: 6 // viewers take turns: at 60 Hz each looks every 0.1 s
FAR :: f32(1e9) // the distance to a target not in the viewer's space

Awareness :: plugin.Awareness

// Pair is one viewer's awareness of one target.
Pair :: struct {
	viewer, target: Form_ID,
	awareness:      Awareness,
}

// Noise is a sound `owner` made at `pos` in `space`, on the iSoundLevel scale.
Noise :: struct {
	owner, space: Form_ID,
	pos:          [3]f32,
	loudness:     f32,
}

// Host is what the engine answers and takes; each proc gets `data` back.
Host :: struct {
	world: ^plugin.World, // the awareness store before this tick is world.awareness
	data:  rawptr,
	sight: proc "c" (data: rawptr, viewer, target: Form_ID) -> f32, // sight.Mode.Cone, 0..1
	range: proc "c" (data: rawptr, viewer: Form_ID) -> f32, // how far the viewer sees
	light: proc "c" (data: rawptr, target: Form_ID) -> f32, // at the target, 0 dark .. 1 lit
	set:   proc "c" (data: rawptr, p: Pair), // applied in order after tick returns: a later set of a pair wins
}

Input :: struct {
	host:   Host,
	table:  ^Table, // the table in force, so the built-in tick calls a replaced judge
	tick:   u64,
	dt:     f32,
	actors: plugin.Span(plugin.Actor), // the loaded actors, the player's too
	known:  plugin.Span(Pair), // the whole awareness store before this tick
	noises: plugin.Span(Noise), // the sounds of the last GROUPS ticks, so each viewer hears each one
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
	noises := plugin.items(inp.noises)
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
				noise    = heard(viewer, target.id, noises, reach),
			}
			h.set(h.data, {viewer.id, target.id, inp.table.judge(h.world.awareness(h.world.data, viewer.id, target.id), senses, step)})
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
	d = distance(viewer.pos, target.pos) if viewer.space != 0 && viewer.space == target.space else FAR
	return d, d <= reach
}

// (hole sound-occlusion :tags (ai audio) :sev polish) a noise carries through walls: hearing is distance only, with no line of sound and no fSneakSoundLosMult.
// heard is how loud the target's loudest noise is at the viewer: it fades to nothing at the reach.
@(private = "file")
heard :: proc "contextless" (viewer: plugin.Actor, target: Form_ID, noises: []Noise, reach: f32) -> (loud: f32) {
	for n in noises {
		if n.owner != target || n.space == 0 || n.space != viewer.space {continue}
		loud = max(loud, n.loudness * (1 - distance(viewer.pos, n.pos) / reach))
	}
	return
}

@(private = "file")
distance :: proc "contextless" (a, b: [3]f32) -> f32 {
	v := a - b
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}
