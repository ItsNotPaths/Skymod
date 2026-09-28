package main

// The sim's boundary (ws.md Workstream R): what main hands the tick and what the tick hands back.
// The sim still runs inline on main; these types are what cross once it has its own thread.

import "core:strings"
import "core:sync"

import "../ai"
import "../audio"
import "../detection"
import "../dialogue"
import "../input"
import smath "../math"
import "../physics"
import "../render"
import "../script"
import slua "../script/lua"
import "../world"
import "../worldstate"

// Sim is the sim's own state. Only the tick, a script phase, or main while it holds the sim
// parked (sim_drain) touches it; main otherwise reads the snapshot.
Sim :: struct {
	ws:           worldstate.World_State,
	repl:         slua.Repl, // the gameplay VM (with the dev console on it)
	trans:        slua.Transitions, // what OnLoad/OnCellAttach were last told (the script phase)
	agents:       ai.World, // every actor's running package
	detection:    detection.State, // who has seen whom
	actor_bodies: map[Form_ID]Actor_Body, // every loaded actor ref but the player
	// The player's capsule, and the physics world it lives in: the exterior `phys` until a load door
	// swaps the active scene to an interior (its own world); on each swap the capsule is re-homed.
	// nil when physics is off (free-fly). `noclip`'s address rides the console's tcl command.
	character:    physics.Character,
	char_ok:      bool,
	noclip:       bool,
	cur_phys:     ^physics.World,
	published:    Placement, // the player's cell and feet as player_publish last wrote them
	input:        Sim_Input, // the controls the tick reads
	input_was:    Sim_Input, // the last tick's: a press is down now and up then
	carried:      Cmd_Carry, // the dev carry
	interact:     Interact, // crosshair interaction: a press in flight, a telekinesis grab
	talk:         Conversation, // the player's conversation (dialogue.odin)
	music:        audio.Music,
	ambient:      audio.Ambient,
	drops:        [dynamic]physics.Body, // the dev drop-test balls
	snap_back:    Snapshot, // the snapshot the sim fills
	ext:          world.Space, // the exterior's live cells and bodies (the interior's is the traversal's)
}

// active_space is the sim's side of the scene the player is in (nil when it has none).
active_space :: proc(g: ^Game) -> ^world.Space {
	return g.fr.active_scene.space if g.fr.active_scene != nil else nil
}

// Sim_Input is what the player's controls hold, latched by main once per frame. The tick reads
// its controls only from here. Buttons are held state: the sim finds a press by comparing ticks.
Sim_Input :: struct {
	move:   [3]f32, // x forward, y right, z up (jump); zero while the UI has the keyboard
	sprint: bool,
	yaw:    f32, // the camera's: main owns the look
	eye:    smath.Vec3, // the camera's; in noclip, where main flew the player
	view:   smath.Mat4, // the camera's view-projection: what the player can see
	aim:    Form_ID, // the ref the crosshair is on, within reach (aim_at); 0 = none
	aim_dir: smath.Vec3, // the crosshair ray from `eye`
	activate, sneak, cast_left, cast_right: bool,
	wheel:   f32, // wheel notches turned since the session began
	in_menu: bool, // a menu is open (dialogue does not park the sim, but blocks interaction)
}

// latch_input is this frame's Sim_Input.
latch_input :: proc(g: ^Game) -> Sim_Input {
	g.wheel += g.p.input.scroll
	_, dir := camera_ray(g.cam, render.aspect(&g.r), {0, 0})
	si := Sim_Input {
		move       = g.p.input.move,
		sprint     = g.p.input.fast,
		yaw        = g.cam.yaw,
		eye        = g.cam.pos,
		view       = camera_view_proj(g.cam, render.aspect(&g.r)),
		aim        = aim_at(g),
		aim_dir    = dir,
		activate   = input.held(&g.imgr, "Activate"),
		sneak      = input.held(&g.imgr, "Sneak"),
		cast_left  = input.held(&g.imgr, "CastLeft"),
		cast_right = input.held(&g.imgr, "CastRight"),
		wheel      = g.wheel,
		in_menu    = g.menu != .None,
	}
	if g.fr.kb_cap {si.move = {}}
	return si
}

// player_feet is where the sim has the player: the capsule when walking, else where main flew.
player_feet :: proc(g: ^Game) -> smath.Vec3 {
	return physics.character_position(&g.sim.character) if g.sim.char_ok && !g.sim.noclip else g.sim.input.eye - {0, 0, EYE_HEIGHT}
}

// (hole sim-primitives-package :tags threading :sev struct) sim.odin holds generic concurrency primitives (Queue, Latest) beside the sim boundary protocol; the primitives want a small package of their own, so this file reads as the protocol only.
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

// take_first pops the oldest item.
take_first :: proc(q: ^Queue($T)) -> (item: T, ok: bool) {
	sync.guard(&q.mu)
	if len(q.items) == 0 {return}
	item = q.items[0]
	ordered_remove(&q.items, 0)
	return item, true
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
	Cmd_Talk_Next,
	Cmd_Talk_Choose,
	Cmd_Talk_Leave,
	Cmd_Select,
}

Cmd_Noclip :: struct {} // toggle walking and free-fly
Cmd_Drop :: struct {at: smath.Vec3} // drop-test ball
Cmd_Shove :: struct {at: smath.Vec3} // kick the clutter near a point
Cmd_Disable :: struct {ref, cell: Form_ID}
Cmd_Spawn :: struct {base, cell: Form_ID, at: smath.Vec3} // a created copy of a base
Cmd_Shoot :: struct {from, dir: smath.Vec3} // the dev shot
Cmd_Carry :: struct {actor: Form_ID, at: smath.Vec3} // hold an actor's capsule centred on `at`
Cmd_Release :: struct {actor: Form_ID}
Cmd_Talk_Next :: struct {info: Form_ID, response: int} // skip the response showing when pressed
Cmd_Talk_Choose :: struct {choice: dialogue.Choice}
Cmd_Talk_Leave :: struct {}
Cmd_Select :: struct {form: Form_ID} // the console's `sel`

// apply_commands runs what main sent since the last tick.
apply_commands :: proc(g: ^Game) {
	drain(&g.commands, &g.command_buf)
	for c in g.command_buf {
		switch v in c {
		case Cmd_Noclip:  g.sim.noclip = !g.sim.noclip
		case Cmd_Drop:    drop_ball(g, v.at)
		case Cmd_Shove:   shove(g, v.at)
		case Cmd_Disable: dev_disable(g, v)
		case Cmd_Spawn:   dev_spawn(g, v)
		case Cmd_Shoot:   dev_shoot(g, v)
		case Cmd_Carry:   g.sim.carried = v
		case Cmd_Release:
			if g.sim.carried.actor == v.actor {g.sim.carried = {}}
			ai.interrupt(&g.sim.agents, v.actor)
		case Cmd_Talk_Next:   talk_next(g, v)
		case Cmd_Talk_Choose: talk_choose(g, v.choice)
		case Cmd_Talk_Leave:  back_out(g)
		case Cmd_Select:      if g.repl_ok {slua.repl_set_selection(&g.sim.repl, script.Form_ID(v.form))}
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
	walking: bool, // the player walks the capsule; else main flies the camera
	player:  Segment, // the player's feet
	bodies: world.Poses, // every dynamic body of the active scene's refs
	drops:  int, // the dev drop-test balls, posed in `bodies` as ref 0
	actors: [dynamic]Actor_View,
	act:    Act_View, // what the crosshair is on
	subtitles: [dynamic]Text_Span, // the lines being said now
	talk:   Talk_View, // the player's conversation
	text:   [dynamic]u8, // the strings the views name, copied: the sim may free its own
}

snapshot_destroy :: proc(s: ^Snapshot) {
	world.poses_destroy(&s.bodies)
	delete(s.actors)
	delete(s.subtitles)
	delete(s.talk.choices)
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
	s := &g.sim.snap_back
	s.walking = g.sim.char_ok && !g.sim.noclip
	clear(&s.text)
	if g.sim.char_ok {s.player.from, s.player.to = physics.character_step(&g.sim.character)}
	world.capture_poses(active_space(g), &s.bodies)
	for b, i in g.sim.drops {world.add_pose(&s.bodies, &g.phys, {0, i32(i)}, b)}
	s.drops = len(g.sim.drops)
	view_actors(g, s)
	s.act = view_act(s, resolve_activation(g, g.sim.input.aim))
	view_subtitles(g, s)
	view_talk(g, s)
	publish(&g.snaps, s)
}

// run_console evaluates the console lines main sent on the gameplay REPL and sends their output
// back. The lines in both string queues are heap copies the queue owns until drained.
run_console :: proc(g: ^Game) {
	drain(&g.console_in, &g.console_in_buf)
	for line in g.console_in_buf {
		for out in slua.repl_eval(&g.sim.repl, line) {push(&g.console_out, strings.clone(out))}
		delete(line)
	}
}

// strings_queue_destroy frees a string queue and whatever it still owns.
strings_queue_destroy :: proc(q: ^Queue(string), buf: ^[dynamic]string) {
	for s in q.items {delete(s)}
	queue_destroy(q)
	delete(buf^)
}

// Sim_Event is one thing the sim tells main. Main handles them after each tick, in order.
Sim_Event :: union {
	Evt_Open_Container,
	Evt_Door,
	Evt_Follow,
	Evt_Ref,
}

Evt_Open_Container :: struct {container: Form_ID}
Evt_Door :: struct {hit: Door_Hit} // the player goes through a load door
Evt_Follow :: struct {} // a script moved the player's ref (MoveTo, jail)
Evt_Ref :: struct {ext: bool, e: world.Ref_Event} // a change to a live cell, of the exterior's space or the interior's

event_destroy :: proc(e: Sim_Event) {
	if v, ok := e.(Evt_Ref); ok {world.ref_event_destroy(v.e)}
}

// forward_ref_events sends main what the sim changed in live cells since it last did.
forward_ref_events :: proc(g: ^Game) {
	forward :: proc(g: ^Game, sp: ^world.Space, ext: bool) {
		for e in sp.changes {push(&g.events, Evt_Ref{ext, e})}
		clear(&sp.changes)
	}
	forward(g, &g.sim.ext, true)
	forward(g, &g.trav.int_space, false)
}

// handle_events runs what the sim told main, oldest first. A handler may run it again (a door's load
// screen), and the inner run carries on in order.
handle_events :: proc(g: ^Game) {
	placed := false // the interior got placed refs
	for e in take_first(&g.events) {
		defer event_destroy(e)
		switch v in e {
		case Evt_Ref:
			s := ref_scene(g, v.ext)
			if s == nil {break}
			world.apply_ref_event(s, v.e)
			if v.ext {
				world.stream_apply(&g.streamer, v.e)
				break
			}
			#partial switch _ in v.e {
			case world.Ref_Placed, world.Cell_Rebuilt: placed = true
			}
		case Evt_Open_Container: open_container(g, v.container)
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
	if s := ref_scene(g, false); placed && s != nil {world.resolve_created_models(s)}
}

// ref_scene is the render scene a space's ref events apply to; nil for the interior when the player
// is outside.
ref_scene :: proc(g: ^Game, ext: bool) -> ^world.Scene {
	if ext {return &g.scene}
	return &g.trav.interior if g.trav.mode == .Interior else nil
}

// sim_drain brings the sim to rest and holds it there: the pending script phase finishes, queued
// commands apply and a snapshot goes out. Until the matching sim_resume no tick runs and main
// owns every piece of sim state. Holds nest.
sim_drain :: proc(g: ^Game) {
	worldstate.sim_enter()
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
	if g.parks == 0 {
		publish_snapshot(g)
		forward_ref_events(g)
	}
	worldstate.sim_leave()
}

// park_for_menu holds the sim parked while an open menu pauses the world, so the menu's actions
// run with main as the sim's owner. Call it after anything that may open or close a menu.
park_for_menu :: proc(g: ^Game) {
	if world_paused(g) == g.menu_parked {return}
	g.menu_parked = !g.menu_parked
	if g.menu_parked {sim_drain(g)} else {sim_resume(g)}
}
