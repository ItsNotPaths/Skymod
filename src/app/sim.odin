package main

// The sim's boundary (ws.md Workstream R): what main hands the tick and what the tick hands back.
// The sim still runs inline on main; these types are what cross once it has its own thread.

import "core:sync"

import "../ai"
import smath "../math"

// Sim_Input is what the player's controls hold, latched by main once per frame. The tick reads
// its controls only from here. Buttons are held state: the sim finds a press by comparing ticks.
Sim_Input :: struct {
	move:   [3]f32, // x forward, y right, z up (jump); zero while the UI has the keyboard
	sprint: bool,
	yaw:    f32, // the camera's: main owns the look
}

// latch_input is this frame's Sim_Input.
latch_input :: proc(g: ^Game) -> Sim_Input {
	si := Sim_Input{g.p.input.move, g.p.input.fast, g.cam.yaw}
	if g.fr.kb_cap {si.move = {}}
	return si
}

// Queue is a list one side appends to and the other drains whole.
Queue :: struct($T: typeid) {
	mu:    sync.Mutex,
	items: [dynamic]T,
}

push :: proc(q: ^Queue($T), item: T) {
	sync.guard(&q.mu)
	append(&q.items, item)
}

// drain moves everything queued into `into` (cleared first). The two buffers swap, so neither
// side allocates once both have grown.
drain :: proc(q: ^Queue($T), into: ^[dynamic]T) {
	clear(into)
	sync.guard(&q.mu)
	q.items, into^ = into^, q.items
}

queue_destroy :: proc(q: ^Queue($T)) {
	delete(q.items)
}

// Sim_Command is one thing main asks of the sim; the tick applies them in order before it runs.
Sim_Command :: union {
	Cmd_Noclip,
	Cmd_Drop,
	Cmd_Shove,
	Cmd_Disable,
	Cmd_Spawn,
	Cmd_Shoot,
	Cmd_Carry,
	Cmd_Release,
}

Cmd_Noclip :: struct {} // toggle walking and free-fly
Cmd_Drop :: struct {at: smath.Vec3} // drop-test ball
Cmd_Shove :: struct {at: smath.Vec3} // kick the clutter near a point
Cmd_Disable :: struct {ref, cell: Form_ID}
Cmd_Spawn :: struct {base, cell: Form_ID, at: smath.Vec3} // a created copy of a base
Cmd_Shoot :: struct {from, dir: smath.Vec3} // the dev shot
Cmd_Carry :: struct {actor: Form_ID, at: smath.Vec3} // hold an actor's capsule centred on `at`
Cmd_Release :: struct {actor: Form_ID}

// apply_commands runs what main sent since the last tick.
apply_commands :: proc(g: ^Game) {
	drain(&g.commands, &g.command_buf)
	for c in g.command_buf {
		switch v in c {
		case Cmd_Noclip:  g.noclip = !g.noclip
		case Cmd_Drop:    drop_ball(g, v.at)
		case Cmd_Shove:   shove(g, v.at)
		case Cmd_Disable: dev_disable(g, v)
		case Cmd_Spawn:   dev_spawn(g, v)
		case Cmd_Shoot:   dev_shoot(g, v)
		case Cmd_Carry:   g.carried = v
		case Cmd_Release:
			if g.carried.actor == v.actor {g.carried = {}}
			ai.interrupt(&g.agents, v.actor)
		}
	}
}
