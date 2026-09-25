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
import "core:os"
import sdl "vendor:sdl3"

// Window is the opaque handle the render layer needs. Re-exported so callers can
// pass it to render.init without naming vendor:sdl3 types themselves.
Window :: ^sdl.Window

// Input is the per-frame snapshot a camera/controller consumes — no SDL types.
Input :: struct {
	move:      [3]f32, // x=forward(+W/-S), y=right(+D/-A), z=up(+E/Space, -Q)
	look:      [2]f32, // mouse delta px this pump, only while look is captured (hold RMB)
	scroll:    f32,    // mouse-wheel notches this pump (+up/away, -down/toward) — telekinesis reach
	fast:      bool,   // shift held -> speed boost
	select:    bool,   // left mouse pressed this pump (edge) — pick the hovered model
	activate:  bool,   // F pressed this pump (edge) — use the nearby door
	hover:     bool,   // Ctrl held — inspect mode: highlight + pick the model under the cursor
	mouse_ndc: [2]f32, // cursor in normalized device coords: x right [-1,1], y up [-1,1]
	toggle_overlay: bool, // ` (backtick/tilde) pressed this pump (edge) — show/hide the dev overlay
	drop:      bool,   // G pressed this pump (edge) — physics drop-test: spawn a ball at the camera
	shove:     bool,   // H pressed this pump (edge) — physics: shove nearby movable clutter (3b verify)
	quicksave: bool,   // F5 pressed this pump (edge) — write the world-state overlay to quicksave.skysave
	quickload: bool,   // F9 pressed this pump (edge) — load quicksave.skysave back into the overlay
	noclip:    bool,   // V pressed this pump (edge) — toggle walk vs free-fly (no-clip) camera
	disable:   bool,   // X pressed this pump (edge) — disable the Ctrl-hovered ref (mutation-layer verify)
	spawn:     bool,   // B pressed this pump (edge) — spawn a copy of the Ctrl-hovered ref at the camera (created-ref verify)
	hitbox:    bool,   // K pressed this pump (edge) — toggle the collision-hitbox wireframe overlay (static + dynamic)
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
	mouse_captured: bool, // DESIRED pointer-lock state (right mouse held)
	relative_on:    bool, // ACTUAL relative-mouse state (only true once SDL confirmed the lock)
	relative_warned: bool, // logged the "relative mode failed" reason once this capture attempt
	keep_escape:    bool, // Escape is the app's key (the game's pause menu), not a quit
}

init :: proc(title: cstring, width, height: i32) -> (p: Platform, ok: bool) {
	// Pointer lock (relative mouse mode) for mouse-look: pick the video driver by what the
	// SESSION actually is, not by which env vars happen to be set.
	//  - Real Xorg session (XDG_SESSION_TYPE=x11): force x11. A leaked WAYLAND_DISPLAY (from a
	//    profile export or an old compositor) would otherwise steer SDL onto the Wayland driver
	//    with no live compositor behind it — pointer lock dies. X11 relative mode works via
	//    XInput2 (dlopened libXi at runtime).
	//  - Wayland session: force native Wayland. On the wlroots stack SDL's XWayland backend
	//    REFUSES relative mode for the focused window ("not supported"), but the NATIVE Wayland
	//    backend does it fine. (Reverse of sdl3-pointerlock-wayland.txt's x11 advice — confirmed
	//    against projects/dimsalt.)
	// NORMAL priority either way, so SDL_VIDEO_DRIVER still overrides both.
	session := os.get_env("XDG_SESSION_TYPE", context.temp_allocator)
	wl := os.get_env("WAYLAND_DISPLAY", context.temp_allocator)
	switch {
	case session == "x11":
		sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "x11")
	case wl != "":
		sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "wayland")
	}
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("platform: SDL_Init failed: %s", sdl.GetError())
		return {}, false
	}
	fmt.printfln("platform: video driver = %s (native Wayland/wlroots does pointer lock; XWayland refuses it)", sdl.GetCurrentVideoDriver())
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
	scroll: f32
	select := false
	activate := false
	toggle_overlay := false
	drop := false
	shove := false
	quicksave := false
	quickload := false
	noclip := false
	disable := false
	spawn := false
	hitbox := false

	ev: sdl.Event
	for sdl.PollEvent(&ev) {
		if p.on_event != nil {
			p.on_event(&ev)
		}
		#partial switch ev.type {
		case .QUIT:
			running = false
		case .KEY_DOWN:
			if ev.key.scancode == .ESCAPE && !p.keep_escape {
				running = false
			}
			if ev.key.scancode == .F && !ev.key.repeat {
				activate = true
			}
			if ev.key.scancode == .GRAVE && !ev.key.repeat {
				toggle_overlay = true
			}
			if ev.key.scancode == .G && !ev.key.repeat {
				drop = true
			}
			if ev.key.scancode == .H && !ev.key.repeat {
				shove = true
			}
			if ev.key.scancode == .F5 && !ev.key.repeat {
				quicksave = true
			}
			if ev.key.scancode == .F9 && !ev.key.repeat {
				quickload = true
			}
			if ev.key.scancode == .V && !ev.key.repeat {
				noclip = true
			}
			if ev.key.scancode == .X && !ev.key.repeat {
				disable = true
			}
			if ev.key.scancode == .B && !ev.key.repeat {
				spawn = true
			}
			if ev.key.scancode == .K && !ev.key.repeat {
				hitbox = true
			}
		case .MOUSE_BUTTON_DOWN:
			if ev.button.button == sdl.BUTTON_LEFT {
				select = true
			}
		case .MOUSE_MOTION:
			// Only consume deltas once the lock is actually engaged, so the frame the lock turns on
			// doesn't inject a jump from the pre-lock cursor motion.
			if p.relative_on {
				look += {ev.motion.xrel, ev.motion.yrel}
			}
		case .MOUSE_WHEEL:
			// Accumulate wheel notches this pump (SDL flips sign when the OS has "natural" scrolling).
			scroll += ev.wheel.y if ev.wheel.direction == .NORMAL else -ev.wheel.y
		}
	}

	// Pointer lock reconcile: drive the ACTUAL relative-mouse state toward the desired capture. Relative
	// mode can fail until the window has input focus / is mapped, so RETRY every frame while desired and
	// only cache success — caching a failure would leave the cursor free forever (see the .txt). Also
	// grab the pointer to physically confine it (belt-and-suspenders).
	reconcile_pointer_lock(p)

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
		scroll    = scroll,
		fast      = fast,
		select    = select,
		activate  = activate,
		hover     = hover,
		mouse_ndc = mouse_ndc,
		toggle_overlay = toggle_overlay,
		drop      = drop,
		shove     = shove,
		quicksave = quicksave,
		quickload = quickload,
		noclip    = noclip,
		disable   = disable,
		spawn     = spawn,
		hitbox    = hitbox,
	}

	now := sdl.GetTicks()
	p.dt = f32(now - p.last_tick) / 1000.0
	p.last_tick = now
	return running
}

// set_mouse_capture requests pointer lock (relative mouse / mouse-look). Pointer lock is the DEFAULT in
// gameplay — the app calls this each frame with the desired state (on while playing, off while a menu or
// the dev overlay needs the cursor). The actual SDL lock is reconciled in pump (retry-until-success), so
// this is a cheap flag set. No mouse button is involved — mouse-look is always active during play.
set_mouse_capture :: proc(p: ^Platform, on: bool) {
	p.mouse_captured = on
}

// reconcile_pointer_lock drives the actual SDL relative-mouse state toward `p.mouse_captured`. Enabling
// can fail transiently (window not yet focused/mapped) or hard (compositor lacks the protocol), so we
// retry while desired and only set `relative_on` on success — never cache a failure. On success we also
// grab the pointer. On failure we surface SDL's reason ONCE per capture attempt (it names the missing
// driver/protocol) instead of swallowing it. See sdl3-pointerlock-wayland.txt.
@(private = "file")
reconcile_pointer_lock :: proc(p: ^Platform) {
	if p.window == nil {
		return
	}
	if p.mouse_captured && !p.relative_on {
		if sdl.SetWindowRelativeMouseMode(p.window, true) {
			_ = sdl.SetWindowMouseGrab(p.window, true) // confine the pointer to the window (best-effort)
			p.relative_on = true
			p.relative_warned = false
		} else if !p.relative_warned {
			fmt.eprintfln("platform: pointer lock failed: %s (try SDL_VIDEO_DRIVER=x11)", sdl.GetError())
			p.relative_warned = true // don't spam every frame the button is held
		}
	} else if !p.mouse_captured && p.relative_on {
		_ = sdl.SetWindowMouseGrab(p.window, false)
		_ = sdl.SetWindowRelativeMouseMode(p.window, false)
		p.relative_on = false
		p.relative_warned = false
	}
}
