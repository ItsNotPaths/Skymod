package platform

// The device bridge: translate live SDL keyboard/mouse state into an input.Frame the
// (SDL-free) src/input resolver can consume. This is the ONE place SDL scancodes meet
// our device-agnostic input.Key vocabulary. Gamepad polling lands here too (a later
// step in the input wave); for now the frame reports keyboard + mouse only.

import "core:c"
import sdl "vendor:sdl3"
import "../input"

// input_frame samples the current held device state (call once per pump, after pump()
// has reconciled pointer lock and refreshed p.input.look with this frame's mouse delta).
input_frame :: proc(p: ^Platform) -> input.Frame {
	f: input.Frame
	f.now_ms = f64(sdl.GetTicks())
	// (hole gamepad :tags input :sev gap) the device never flips to .Gamepad — SDL pad polling is not wired, so a controller does nothing and the prompts always show keyboard art.
	f.device = .Key_Mouse // TODO(input wave): flip to .Gamepad on pad activity

	nkeys: c.int
	keys := sdl.GetKeyboardState(&nkeys)
	for k in input.Key {
		sc := sdl_scancode(k)
		if sc != .UNKNOWN && c.int(sc) < nkeys {
			f.keys[k] = keys[int(sc)]
		}
	}

	mx, my: f32
	mstate := sdl.GetMouseState(&mx, &my)
	f.mouse[.Left]   = .LEFT   in mstate
	f.mouse[.Right]  = .RIGHT  in mstate
	f.mouse[.Middle] = .MIDDLE in mstate
	f.mouse[.X1]     = .X1     in mstate
	f.mouse[.X2]     = .X2     in mstate
	f.mouse[.WheelUp]   = p.input.scroll > 0 // a notch reads as held for the pump it turned in
	f.mouse[.WheelDown] = p.input.scroll < 0

	// This pump's accumulated relative-mouse delta (only non-zero while look is locked).
	f.mouse_delta = p.input.look
	return f
}

// sdl_scancode maps an input.Key onto its SDL scancode. Keys we don't translate return
// .UNKNOWN and are simply never held (they also have no glyph). Letters/digits/F-keys
// are contiguous in the SDL enum but spelled out for clarity and grep-ability.
@(private = "file")
sdl_scancode :: proc(k: input.Key) -> sdl.Scancode {
	#partial switch k {
	case .A: return .A
	case .B: return .B
	case .C: return .C
	case .D: return .D
	case .E: return .E
	case .F: return .F
	case .G: return .G
	case .H: return .H
	case .I: return .I
	case .J: return .J
	case .K: return .K
	case .L: return .L
	case .M: return .M
	case .N: return .N
	case .O: return .O
	case .P: return .P
	case .Q: return .Q
	case .R: return .R
	case .S: return .S
	case .T: return .T
	case .U: return .U
	case .V: return .V
	case .W: return .W
	case .X: return .X
	case .Y: return .Y
	case .Z: return .Z
	case .N0: return ._0
	case .N1: return ._1
	case .N2: return ._2
	case .N3: return ._3
	case .N4: return ._4
	case .N5: return ._5
	case .N6: return ._6
	case .N7: return ._7
	case .N8: return ._8
	case .N9: return ._9
	case .F1: return .F1
	case .F2: return .F2
	case .F3: return .F3
	case .F4: return .F4
	case .F5: return .F5
	case .F6: return .F6
	case .F7: return .F7
	case .F8: return .F8
	case .F9: return .F9
	case .F10: return .F10
	case .F11: return .F11
	case .F12: return .F12
	case .Space: return .SPACE
	case .Enter: return .RETURN
	case .Tab: return .TAB
	case .Esc: return .ESCAPE
	case .Backspace: return .BACKSPACE
	case .CapsLock: return .CAPSLOCK
	case .LShift: return .LSHIFT
	case .RShift: return .RSHIFT
	case .LCtrl: return .LCTRL
	case .RCtrl: return .RCTRL
	case .LAlt: return .LALT
	case .RAlt: return .RALT
	case .Up: return .UP
	case .Down: return .DOWN
	case .Left: return .LEFT
	case .Right: return .RIGHT
	case .Grave: return .GRAVE
	case .Minus: return .MINUS
	case .Equals: return .EQUALS
	case .LBracket: return .LEFTBRACKET
	case .RBracket: return .RIGHTBRACKET
	case .Backslash: return .BACKSLASH
	case .Semicolon: return .SEMICOLON
	case .Apostrophe: return .APOSTROPHE
	case .Comma: return .COMMA
	case .Period: return .PERIOD
	case .Slash: return .SLASH
	}
	// .Ctrl/.Shift/.Alt are logical-only (resolved to L/R in code_down) and never sampled.
	return .UNKNOWN
}
