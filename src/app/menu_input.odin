package main

// Keyboard navigation for the Lua main menu. The platform calls one Event_Hook per raw SDL event;
// this hook forwards to imgui (so the dev overlay keeps working) and records edge-triggered nav keys
// (down on this pump, not held), which the menu loop drains each frame with menu_nav_take. Mouse
// position + left-click come from platform's Input snapshot, so only the keyboard lives here.
//
// Note: platform.pump treats Esc as quit (returns false), so the menu uses Backspace for "back".

import "../render"
import sdl "vendor:sdl3"

// Menu_Nav is the per-frame edge-triggered navigation intent.
Menu_Nav :: struct {
	up:     bool,
	down:   bool,
	accept: bool,
	back:   bool,
}

@(private = "file")
g_nav: Menu_Nav

// menu_event_hook is wired as platform.on_event while the Lua menu runs. Forwards to imgui + records
// nav-key edges. Held repeats are ignored so one keypress moves the cursor one step.
menu_event_hook :: proc(ev: ^sdl.Event) {
	render.ui_process_event(ev)
	#partial switch ev.type {
	case .KEY_DOWN:
		if ev.key.repeat {
			return
		}
		#partial switch ev.key.scancode {
		case .UP, .W:
			g_nav.up = true
		case .DOWN, .S:
			g_nav.down = true
		case .RETURN, .KP_ENTER, .SPACE:
			g_nav.accept = true
		case .BACKSPACE:
			g_nav.back = true
		}
	}
}

// menu_nav_take returns the nav intent accumulated since the last call and clears it.
menu_nav_take :: proc() -> Menu_Nav {
	v := g_nav
	g_nav = {}
	return v
}
