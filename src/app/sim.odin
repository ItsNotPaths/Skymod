package main

// The sim's boundary (ws.md Workstream R): what main hands the tick and what the tick hands back.
// The sim still runs inline on main; these types are what cross once it has its own thread.

import "core:sync"

import "../ai"
import smath "../math"
import "../physics"
import "../render"

// Sim_Input is what the player's controls hold, latched by main once per frame. The tick reads
// its controls only from here. Buttons are held state: the sim finds a press by comparing ticks.
Sim_Input :: struct {
	move:   [3]f32, // x forward, y right, z up (jump); zero while the UI has the keyboard
	sprint: bool,
	yaw:    f32, // the camera's: main owns the look
	eye:    smath.Vec3, // the camera's; in noclip, where main flew the player
	view:   smath.Mat4, // the camera's view-projection: what the player can see
	aim:    Form_ID, // the ref the crosshair is on, within reach (aim_at); 0 = none
}

// latch_input is this frame's Sim_Input.
latch_input :: proc(g: ^Game) -> Sim_Input {
	si := Sim_Input{g.p.input.move, g.p.input.fast, g.cam.yaw, g.cam.pos, camera_view_proj(g.cam, render.aspect(&g.r)), aim_at(g)}
	if g.fr.kb_cap {si.move = {}}
	return si
}

// player_feet is where the sim has the player: the capsule when walking, else where main flew.
player_feet :: proc(g: ^Game) -> smath.Vec3 {
	return physics.character_position(&g.character) if g.char_ok && !g.noclip else g.input.eye - {0, 0, EYE_HEIGHT}
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

// Latest is a value one side publishes and the other takes the newest of. Three buffers turn —
// the publisher's back, the shared slot and the taker's current — so nothing is copied.
Latest :: struct($T: typeid) {
	mu:    sync.Mutex,
	slot:  T,
	fresh: bool,
}

// publish hands `back` over as the newest and gets an old buffer back to fill next.
publish :: proc(l: ^Latest($T), back: ^T) {
	sync.guard(&l.mu)
	l.slot, back^ = back^, l.slot
	l.fresh = true
}

// take swaps the newest into `cur`, if one arrived since the last take.
take :: proc(l: ^Latest($T), cur: ^T) -> bool {
	sync.guard(&l.mu)
	if !l.fresh {return false}
	l.slot, cur^ = cur^, l.slot
	l.fresh = false
	return true
}

// Snapshot is what the sim shows main after a tick. A pose is the segment it moved along in that
// tick, so main blends inside the newest snapshot and a teleport (from == to) never slides.
Snapshot :: struct {
	tick:    u64,
	walking: bool, // the player walks the capsule; else main flies the camera
	player:  Segment, // the player's feet
	bodies: physics.Poses, // every dynamic body in the active world
	actors: [dynamic]Actor_View,
	act:    Activation_Target, // what the crosshair is on
	text:   [dynamic]u8, // the strings the views name, copied: the sim may free its own
}

snapshot_destroy :: proc(s: ^Snapshot) {
	physics.poses_destroy(&s.bodies)
	delete(s.actors)
	delete(s.text)
}

// Text_Span is a string copied into Snapshot.text.
Text_Span :: struct {
	at, len: int,
}

add_text :: proc(s: ^Snapshot, str: string) -> Text_Span {
	span := Text_Span{len(s.text), len(str)}
	append(&s.text, str)
	return span
}

text :: proc(s: ^Snapshot, span: Text_Span) -> string {
	return string(s.text[span.at:][:span.len])
}

Segment :: struct {
	from, to: smath.Vec3,
}

// blend is the point `alpha` (0..1) of the way along a segment.
blend :: proc(s: Segment, alpha: f32) -> smath.Vec3 {
	return s.from + (s.to - s.from) * clamp(alpha, 0, 1)
}

// publish_snapshot shows main the sim as it stands. The tick calls it last, and so does any change
// main makes to the sim between ticks (a teleport).
publish_snapshot :: proc(g: ^Game) {
	s := &g.snap_back
	s.tick = g.tick.total
	s.walking = g.char_ok && !g.noclip
	clear(&s.text)
	if g.char_ok {s.player.from, s.player.to = physics.character_step(&g.character)}
	if g.cur_phys != nil {
		physics.capture_poses(g.cur_phys, &s.bodies)
	} else {
		clear(&s.bodies.list)
		clear(&s.bodies.at)
	}
	view_actors(g, s)
	s.act = resolve_activation(g, s, g.input.aim)
	publish(&g.snaps, s)
}

// Sim_Event is one thing the sim tells main. Main handles them after each tick, in order.
Sim_Event :: union {
	Evt_Open_Container,
	Evt_Open_Dialogue,
	Evt_Door,
	Evt_Follow,
}

Evt_Open_Container :: struct {container: Form_ID}
Evt_Open_Dialogue :: struct {speaker: Form_ID}
Evt_Door :: struct {hit: Door_Hit} // the player goes through a load door
Evt_Follow :: struct {} // a script moved the player's ref (MoveTo, jail)

// handle_events runs what the sim told main since the last call.
handle_events :: proc(g: ^Game) {
	drain(&g.events, &g.event_buf)
	for e in g.event_buf {
		switch v in e {
		case Evt_Open_Container: open_container(g, v.container)
		case Evt_Open_Dialogue:  open_dialogue(g, v.speaker)
		case Evt_Door:
			sim_drain(g)
			cross_door(g, v.hit)
			sim_resume(g)
		case Evt_Follow:
			sim_drain(g)
			player_follow(g)
			sim_resume(g)
		}
	}
}

// sim_drain brings the sim to rest and holds it there: the pending script phase finishes, queued
// commands apply and a snapshot goes out. Until the matching sim_resume no tick runs and main
// owns every piece of sim state. Holds nest.
sim_drain :: proc(g: ^Game) {
	if g.parks == 0 {
		script_run_pending(g)
		apply_commands(g)
		publish_snapshot(g)
	}
	g.parks += 1
}

// sim_resume drops one hold. The last one publishes what main changed while the sim was parked.
sim_resume :: proc(g: ^Game) {
	g.parks -= 1
	if g.parks == 0 {publish_snapshot(g)}
}

// park_for_menu holds the sim parked while an open menu pauses the world, so the menu's actions
// run with main as the sim's owner. Call it after anything that may open or close a menu.
park_for_menu :: proc(g: ^Game) {
	if world_paused(g) == g.menu_parked {return}
	g.menu_parked = !g.menu_parked
	if g.menu_parked {sim_drain(g)} else {sim_resume(g)}
}
