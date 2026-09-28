package main

// The sim thread (ws.md Workstream R) runs the ticks on its own clock, each tick's script phase
// inline at its end. Main owns the sim only while it is parked: main parks it with sim_drain and
// frees it with sim_resume; an event that needs main (send_parked) parks it as it is sent, and main
// frees that hold once it has handled the event (sim_wait, then sim_resume).

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

import slua "../script/lua"
import "../world"
import "../worldstate"

Sim_Thread :: struct {
	th:     ^thread.Thread, // nil before the first tick and after the last: main owns the sim
	mu:     sync.Mutex,
	cond:   sync.Cond,
	holds:  int, // parks asked for: main's, and the sim's own for events that need main
	ticking: bool, // the sim thread runs, not parked; guarded by mu
	quit:   bool,
	inputs: Latest(Sim_Input), // the controls main latched each frame
	// The script phase's inputs, kept to reuse their buffers.
	loaded:   [dynamic]Form_ID,
	attached: [dynamic]Form_ID,
}

sim_thread_start :: proc(g: ^Game) {
	s := &g.simt
	s.th = thread.create(sim_thread_proc)
	s.th.data = g
	s.th.init_context = context
	thread.start(s.th)
}

// sim_thread_stop ends the sim thread between ticks; main owns the sim from here.
sim_thread_stop :: proc(g: ^Game) {
	s := &g.simt
	if s.th != nil {
		sync.mutex_lock(&s.mu)
		s.quit = true
		sync.cond_broadcast(&s.cond)
		sync.mutex_unlock(&s.mu)
		thread.join(s.th)
		thread.destroy(s.th)
		s.th = nil
	}
	delete(s.loaded)
	delete(s.attached)
}

@(private = "file")
sim_thread_proc :: proc(t: ^thread.Thread) {
	g := (^Game)(t.data)
	s := &g.simt
	worldstate.sim_enter() // the sim's own thread owns the sim whenever it is not parked
	defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	for {
		sync.mutex_lock(&s.mu)
		for s.holds > 0 && !s.quit {
			s.ticking = false
			sync.cond_broadcast(&s.cond)
			sync.cond_wait(&s.cond, &s.mu)
		}
		s.ticking = !s.quit
		quit := s.quit
		sync.mutex_unlock(&s.mu)
		if quit {break}
		if clock_due(&g.sim.clock) {
			game_tick(g)
		} else {
			time.sleep(time.tick_diff(time.tick_now(), g.sim.clock.next))
		}
	}
}

// sim_hold asks the sim to park at its next tick boundary. Any thread.
sim_hold :: proc(g: ^Game) {
	sync.guard(&g.simt.mu)
	g.simt.holds += 1
}

// send_parked sends main an event it must handle with the sim parked, and parks the sim.
send_parked :: proc(g: ^Game, e: Sim_Event) {
	sim_hold(g)
	push(&g.events, e)
}

// sim_drain brings the sim to rest and holds it there: queued commands apply and a snapshot goes
// out. Until the matching sim_resume no tick runs and main owns every piece of sim state. Holds nest.
sim_drain :: proc(g: ^Game) {
	sim_hold(g)
	sim_wait(g)
}

// sim_wait waits, under a hold already taken, for the sim to park, and makes main its owner.
sim_wait :: proc(g: ^Game) {
	worldstate.sim_enter()
	if g.parks == 0 {
		s := &g.simt
		sync.mutex_lock(&s.mu)
		for s.ticking {sync.cond_wait(&s.cond, &s.mu)}
		sync.mutex_unlock(&s.mu)
		apply_commands(g)
		publish_snapshot(g)
	}
	g.parks += 1
}

// sim_resume drops one hold. The last of main's publishes what main changed while the sim was parked.
sim_resume :: proc(g: ^Game) {
	g.parks -= 1
	if g.parks == 0 {
		g.sim.clock.next = {} // the parked time is not the sim's to make up
		publish_snapshot(g)
		forward_ref_events(g)
	}
	worldstate.sim_leave()
	s := &g.simt
	sync.guard(&s.mu)
	s.holds -= 1
	sync.cond_broadcast(&s.cond)
}

// run_scripts is a tick's script phase: the player's placement, the cells made live since the last
// phase and the cells attached now go to the VM, then its handlers and timers run.
run_scripts :: proc(g: ^Game) {
	if !g.repl_ok {return}
	t := time.tick_now()
	s := &g.simt
	player_publish(g)
	clear(&s.loaded)
	for sp in ([]^world.Space{&g.sim.ext, &g.sim.trav.int_space}) {
		append(&s.loaded, ..sp.loaded[:])
		clear(&sp.loaded)
	}
	clear(&s.attached)
	if sp := active_space(g); sp != nil {
		for cell in sp.cells {append(&s.attached, cell)}
	}
	slua.tick_begin(&g.sim.repl.vm, &g.db, &g.sim.ws, &g.sim.trans, s.loaded[:], s.attached[:], TICK_DT)
	lap(g, .Script_Events, &t)
	slua.tick_end(&g.sim.repl.vm, TICK_DT)
	lap(g, .Scripts, &t)
	if (g.tick.prof.ticks + 1) % PROF_REPORT_TICKS == 0 {slua.prof_report(&g.sim.repl.vm, PROF_REPORT_TICKS, 12)}
}
