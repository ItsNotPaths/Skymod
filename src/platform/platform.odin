package platform

// Platform layer (ROADMAP Phase 0, step 2): owns the SDL3 window, the event pump,
// input, and timing. The render package borrows the window handle to drive
// SDL3_gpu; everything else flows through this thin interface so app/ never
// imports SDL.
//
// (platform legitimately imports vendor:sdl3 — it IS the SDL window/input layer.
// The "render-only" rule is specifically about the SDL3_gpu API, which lives in
// src/render. See README / ROADMAP §1.)

import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"

// Window is the opaque handle the render layer needs. Re-exported so callers can
// pass it to render.init without naming vendor:sdl3 types themselves.
Window :: ^sdl.Window

// Input is the per-frame snapshot a camera/controller consumes — no SDL types.
Input :: struct {
	move:      [3]f32, // x=forward(+W/-S), y=right(+D/-A), z=up(+E/Space, -Q)
	look:      [2]f32, // mouse delta px this pump, only while look is captured (hold RMB)
	fast:      bool,   // shift held -> speed boost
	select:    bool,   // left mouse pressed this pump (edge) — pick the hovered model
	activate:  bool,   // F pressed this pump (edge) — use the nearby door
	hover:     bool,   // Ctrl held — inspect mode: highlight + pick the model under the cursor
	mouse_ndc: [2]f32, // cursor in normalized device coords: x right [-1,1], y up [-1,1]
}

// Event_Hook is called for every raw SDL event during pump(). Used to forward
// events into Dear ImGui (render.ui_process_event) without platform depending on
// the UI. Platform owns vendor:sdl3, so exposing ^sdl.Event here is fine.
Event_Hook :: proc(ev: ^sdl.Event)

Platform :: struct {
	window:         Window,
	input:          Input,
	dt:             f32, // seconds elapsed during the last pump()
	on_event:       Event_Hook, // optional; called per raw SDL event
	last_tick:      u64,
	mouse_captured: bool,
}

init :: proc(title: cstring, width, height: i32) -> (p: Platform, ok: bool) {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("platform: SDL_Init failed: %s", sdl.GetError())
		return {}, false
	}
	window := sdl.CreateWindow(title, width, height, {.RESIZABLE})
	if window == nil {
		fmt.eprintfln("platform: CreateWindow failed: %s", sdl.GetError())
		sdl.Quit()
		return {}, false
	}
	p.window = window
	p.last_tick = sdl.GetTicks()
	return p, true
}

shutdown :: proc(p: ^Platform) {
	if p.window != nil {
		sdl.DestroyWindow(p.window)
	}
	sdl.Quit()
	p^ = {}
}

// base_path is the directory containing the running executable (with a trailing
// separator), per SDL. Used to anchor settings.txt, the log, and the installed
// content/ folder "next to the executable" — all resolved at boot, before any
// window exists, so we tolerate being called pre-Init (GetBasePath works either
// way; the fallback Init is a cheap, refcounted no-op if it's already up). The
// returned string views SDL-owned memory valid for the program's lifetime.
base_path :: proc() -> string {
	p := sdl.GetBasePath()
	if p == nil {
		_ = sdl.Init({})
		p = sdl.GetBasePath()
	}
	return string(p)
}

// pump drains the event queue, refreshes input + dt, and returns false once the
// user asks to quit (window close or Esc). Mouse-look is captured while the right
// button is held (relative mouse mode); WASD/QE feed the move vector.
pump :: proc(p: ^Platform) -> bool {
	running := true
	look: [2]f32
	select := false
	activate := false

	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		if p.on_event != nil {
			p.on_event(&ev)
		}
		#partial switch ev.type {
		case .QUIT:
			running = false
		case .KEY_DOWN:
			if ev.key.scancode == .ESCAPE {
				running = false
			}
			if ev.key.scancode == .F && !ev.key.repeat {
				activate = true
			}
		case .MOUSE_BUTTON_DOWN:
			if ev.button.button == sdl.BUTTON_LEFT {
				select = true
			}
			if ev.button.button == sdl.BUTTON_RIGHT {
				p.mouse_captured = true
				_ = sdl.SetWindowRelativeMouseMode(p.window, true)
			}
		case .MOUSE_BUTTON_UP:
			if ev.button.button == sdl.BUTTON_RIGHT {
				p.mouse_captured = false
				_ = sdl.SetWindowRelativeMouseMode(p.window, false)
			}
		case .MOUSE_MOTION:
			if p.mouse_captured {
				look += {ev.motion.xrel, ev.motion.yrel}
			}
		}
	}

	nkeys: c.int
	keys := sdl.GetKeyboardState(&nkeys)
	held :: proc(keys: [^]bool, sc: sdl.Scancode) -> bool {
		return keys[int(sc)]
	}
	move: [3]f32
	if held(keys, .W) {move.x += 1}
	if held(keys, .S) {move.x -= 1}
	if held(keys, .D) {move.y += 1}
	if held(keys, .A) {move.y -= 1}
	if held(keys, .E) || held(keys, .SPACE) {move.z += 1}
	if held(keys, .Q) {move.z -= 1}
	fast := held(keys, .LSHIFT) || held(keys, .RSHIFT)
	hover := held(keys, .LCTRL) || held(keys, .RCTRL) // inspect-mode modifier

	// Cursor → NDC (x right, y up), for picking the model under the mouse. Meaningless
	// while look is captured (relative mouse mode), but hover-pick only runs when it isn't.
	mx, my: f32
	_ = sdl.GetMouseState(&mx, &my)
	ww, wh: c.int
	sdl.GetWindowSize(p.window, &ww, &wh)
	mouse_ndc: [2]f32
	if ww > 0 && wh > 0 {
		mouse_ndc = {2 * mx / f32(ww) - 1, 1 - 2 * my / f32(wh)}
	}

	p.input = Input {
		move      = move,
		look      = look,
		fast      = fast,
		select    = select,
		activate  = activate,
		hover     = hover,
		mouse_ndc = mouse_ndc,
	}

	now := sdl.GetTicks()
	p.dt = f32(now - p.last_tick) / 1000.0
	p.last_tick = now
	return running
}
