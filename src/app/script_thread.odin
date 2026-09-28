package main

// The script thread runs a tick's script phase while the main thread renders (docs/script-rewrite.md
// "Threading"). It owns worldstate and the VM from script_start to script_join; the main thread
// owns them otherwise.

import "base:runtime"
import "core:sync"
import "core:thread"
import "core:time"

import slua "../script/lua"
import "../world"
import "../worldstate"

Script_Thread :: struct {
	th:       ^thread.Thread,
	go, done: sync.Sema,
	quit:     bool,
	pending:  bool, // a tick's script phase is due and has not started
	running:  bool, // started, not joined
	ms:       f64, // the last phase's time, written by the script thread before `done`
	// The phase's inputs, owned here: the main thread's copies change or free while it runs.
	loaded:   [dynamic]Form_ID,
	attached: [dynamic]Form_ID,
}

script_thread_init :: proc(g: ^Game) {
	g.scripts.th = thread.create(script_thread_proc)
	g.scripts.th.data = g
	g.scripts.th.init_context = context
	thread.start(g.scripts.th)
}

script_thread_destroy :: proc(g: ^Game) {
	st := &g.scripts
	if st.th != nil {
		script_join(g)
		st.quit = true
		sync.sema_post(&st.go)
		thread.join(st.th)
		thread.destroy(st.th)
	}
	delete(st.loaded)
	delete(st.attached)
}

// script_start hands a pending script phase to the script thread.
script_start :: proc(g: ^Game) {
	st := &g.scripts
	if !st.pending || st.th == nil {return}
	st.pending = false
	worldstate.sim_enter() // the phase's setup is sim work that main still does
	defer worldstate.sim_leave()

	player_publish(g)
	clear(&st.loaded)
	for sp in ([]^world.Space{&g.sim.ext, &g.sim.trav.int_space}) {
		append(&st.loaded, ..sp.loaded[:])
		clear(&sp.loaded)
	}
	clear(&st.attached)
	if sp := active_space(g); sp != nil {
		for cell in sp.cells {append(&st.attached, cell)}
	}

	st.running = true
	g.sim.ws.script_phase = true
	sync.sema_post(&st.go)
}

// script_join waits for a running script phase and gives worldstate back to the main thread.
script_join :: proc(g: ^Game) {
	st := &g.scripts
	if !st.running {return}
	sync.sema_wait(&st.done)
	st.running = false
	g.tick.prof.scripts += st.ms
	g.sim.ws.script_phase = false
}

// script_run_pending runs a pending script phase to the end: a tick's scripts finish before the
// next tick's sim.
script_run_pending :: proc(g: ^Game) {
	script_start(g)
	script_join(g)
}

@(private = "file")
script_thread_proc :: proc(t: ^thread.Thread) {
	g := (^Game)(t.data)
	st := &g.scripts
	worldstate.on_script_thread = true
	defer runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	for {
		sync.sema_wait(&st.go)
		if st.quit {return}
		t := time.tick_now()
		slua.tick_begin(&g.sim.repl.vm, &g.db, &g.sim.ws, &g.sim.trans, st.loaded[:], st.attached[:], TICK_DT)
		slua.tick_end(&g.sim.repl.vm, TICK_DT)
		st.ms = time.duration_milliseconds(time.tick_since(t))
		free_all(context.temp_allocator)
		sync.sema_post(&st.done)
	}
}
