package input

// The input substrate (a leaf package — NO SDL, NO app deps, so it type-checks and
// unit-tests without a window). It owns:
//   - the physical-input vocabulary (Key/Mouse/Pad + the Code union),
//   - a STRING-KEYED, dynamic action registry (so a mod can register a new action at
//     load time; there is no compiled action enum to edit),
//   - the gesture resolver: a per-frame state machine turning held device state into
//     action edges for Press / Release / Hold(ms) / Tap(N) (x-tap) + chords,
//   - analog axis actions (movement) composed from bound direction codes / a stick.
//
// The platform layer (which owns vendor:sdl3) fills a `Frame` of held device state
// each pump and calls update(); consumers query fired()/down()/axis3(). Binding text
// (`bind.<Action> = <gesture>`) is parsed/serialized in bind.odin and persisted in the
// per-profile settings.txt — this package never touches the filesystem.

import "core:strings"

// Tuning. Defaults chosen to feel snappy but forgiving; overridable per-gesture (Hold)
// and later per-profile.
HOLD_MS_DEFAULT :: 300 // a bare `hold` with no number waits this long
MULTI_TAP_MS    :: 300 // max gap between presses of an N-tap before the count resets

// ---- Physical input vocabulary -------------------------------------------------

// Key is a device-agnostic keyboard code. The platform bridge maps SDL scancodes onto
// these; keys we have no entry for simply aren't bindable (and have no glyph). Ctrl/
// Shift/Alt are LOGICAL "either side" keys used mainly as chord modifiers — code_down
// resolves them to (left OR right). Kept contiguous so [Key]bool is a tight array.
Key :: enum u16 {
	Invalid = 0,
	A, B, C, D, E, F, G, H, I, J, K, L, M,
	N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
	N0, N1, N2, N3, N4, N5, N6, N7, N8, N9,
	F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
	Space, Enter, Tab, Esc, Backspace, CapsLock,
	LShift, RShift, LCtrl, RCtrl, LAlt, RAlt,
	Ctrl, Shift, Alt, // logical: either side (chord modifiers)
	Up, Down, Left, Right,
	Grave, // the `/~ key (tilde)
	Minus, Equals, LBracket, RBracket, Backslash, Semicolon, Apostrophe, Comma, Period, Slash,
}

// Mouse buttons + wheel notches (wheel arrives as a momentary "down" for one frame).
Mouse :: enum u8 {
	Invalid = 0,
	Left, Right, Middle, X1, X2, WheelUp, WheelDown,
}

// Gamepad buttons (Xbox naming; the glyph layer maps these to 360_* art). Triggers
// appear here as buttons via a deadzone AND as analog axes (Pad_Axis) for movement.
Pad :: enum u8 {
	Invalid = 0,
	A, B, X, Y,
	LB, RB, LT, RT,
	Back, Start, LS, RS,
	DpadUp, DpadDown, DpadLeft, DpadRight,
}

// Pad_Axis: analog sticks + triggers, for axis actions (movement / look).
Pad_Axis :: enum u8 {
	LeftX, LeftY, RightX, RightY, LTrig, RTrig,
}

// Code is a single physical input source — the thing a gesture keys off. A nil union
// means "unbound". Unions of comparable enums are themselves comparable (== works).
Code :: union {
	Key,
	Mouse,
	Pad,
}

// Device: which family last produced input, for hot glyph switching.
Device :: enum u8 {
	Key_Mouse,
	Gamepad,
}

// ---- Gestures ------------------------------------------------------------------

Trigger :: enum u8 {
	Press,   // fires on the down edge (default)
	Release, // fires on the up edge
	Hold,    // fires once after the code is held hold_ms
	Tap,     // fires after `taps` quick presses within MULTI_TAP_MS (x-tap; taps=1 = single tap)
}

MAX_MODS :: 4

// Gesture: a fully-parsed binding for a Button action — a code, optional chord
// modifiers that must be held with it, and a trigger with its parameters.
Gesture :: struct {
	code:    Code,
	mods:    [MAX_MODS]Code,
	n_mods:  u8,
	trigger: Trigger,
	taps:    u8,  // Tap: N in 1..9
	hold_ms: u16, // Hold: milliseconds
}

// ---- Actions & registry --------------------------------------------------------

Action_Kind :: enum u8 {
	Button, // discrete: resolved by a Gesture into an edge (state.fired)
	Axis,   // analog: a [3]f32 vector composed from bound direction codes (+ pad stick)
}

// AXIS_CODES: the fixed slot order for an Axis action's bind string, producing a
// [3]f32 (x fwd, y right, z up), matching the engine's move vector convention.
Axis_Slot :: enum u8 { Fwd, Back, Right, Left, Up, Down }

Action_State :: struct {
	fired:      bool,    // Button: the trigger fired THIS frame (an edge)
	down:       bool,    // Button: code (and chord) currently held
	value:      [3]f32,  // Axis: composed vector this frame
	// internal timing / edge memory
	was_down:   bool,
	press_t:    f64,
	last_tap_t: f64,
	tap_count:  u8,
	hold_fired: bool,
}

// Action: one registered, rebindable control. `id` is the stable string key
// ("Activate", "Jump", "MyMod:Grapple"); `context` gates when it's live; `bind_str`
// is the current human binding text (round-trips to settings.txt); gesture/axis_codes
// are its parsed form.
Action :: struct {
	id:         string,
	ctx:        string,
	kind:       Action_Kind,
	default_bind: string,
	bind_str:   string,        // owned; current binding text
	gesture:    Gesture,       // Button
	axis_codes: [6]Code,       // Axis (indexed by Axis_Slot)
	pad_axis:   Maybe([2]Pad_Axis), // Axis: optional analog stick (x,y)
	state:      Action_State,
}

// Frame: the held device state for one pump, produced by the platform bridge. Level
// state only (the resolver derives edges vs the previous frame), plus analog + a
// monotonic clock in milliseconds.
Frame :: struct {
	now_ms:      f64,
	device:      Device,
	keys:        [Key]bool,
	mouse:       [Mouse]bool,
	pad:         [Pad]bool,
	mouse_delta: [2]f32,
	pad_axes:    [Pad_Axis]f32,
}

Manager :: struct {
	actions:  [dynamic]Action,
	index:    map[string]int,
	enabled:  map[string]bool, // active contexts (Step D grows this into a stack)
	last_device: Device,
}

// ---- Lifecycle & registration --------------------------------------------------

init :: proc(m: ^Manager, allocator := context.allocator) {
	context.allocator = allocator
	m.index = make(map[string]int)
	m.enabled = make(map[string]bool)
	// Sensible defaults; contexts are refined in Step D.
	m.enabled["global"] = true
	m.enabled["gameplay"] = true
}

destroy :: proc(m: ^Manager) {
	for &a in m.actions {
		delete(a.id)
		delete(a.ctx)
		delete(a.default_bind)
		delete(a.bind_str)
	}
	delete(m.actions)
	delete(m.index)
	delete(m.enabled)
}

// register adds (or, by id, replaces the binding of) an action. `default_bind` is the
// gesture/axis text used until settings.txt overrides it. Strings are cloned.
register :: proc(m: ^Manager, id, ctx: string, kind: Action_Kind, default_bind: string) {
	if idx, has := m.index[id]; has {
		// Re-registration keeps the live binding; just refresh metadata.
		a := &m.actions[idx]
		if a.ctx != ctx {
			delete(a.ctx); a.ctx = strings.clone(ctx)
		}
		return
	}
	a := Action {
		id           = strings.clone(id),
		ctx          = strings.clone(ctx),
		kind         = kind,
		default_bind = strings.clone(default_bind),
		bind_str     = strings.clone(default_bind),
	}
	reparse(&a)
	m.index[a.id] = len(m.actions)
	append(&m.actions, a)
}

// rebind sets an action's binding text and reparses it. Empty string = unbound. Used
// by settings load and the rebind UI. Returns false if the text doesn't parse (the old
// binding is kept).
rebind :: proc(m: ^Manager, id, bind_str: string) -> bool {
	idx, has := m.index[id]
	if !has do return false
	a := &m.actions[idx]
	// Validate against a scratch copy first so a bad string can't clobber the binding.
	probe := a^
	probe.bind_str = bind_str
	if !reparse(&probe) do return false
	delete(a.bind_str)
	a.bind_str = strings.clone(bind_str)
	reparse(a)
	return true
}

// reparse fills gesture / axis_codes from bind_str for the action's kind. Returns
// false on a malformed string (leaving the struct's parsed fields zeroed).
reparse :: proc(a: ^Action) -> bool {
	a.gesture = {}
	a.axis_codes = {}
	a.pad_axis = nil
	if strings.trim_space(a.bind_str) == "" do return true // unbound is valid
	switch a.kind {
	case .Button:
		g, ok := parse_gesture(a.bind_str)
		a.gesture = g
		return ok
	case .Axis:
		return parse_axis(a.bind_str, &a.axis_codes, &a.pad_axis)
	}
	return false
}

// ---- Per-frame resolve ---------------------------------------------------------

update :: proc(m: ^Manager, f: ^Frame) {
	m.last_device = f.device
	for &a in m.actions {
		a.state.fired = false
		if !context_live(m, a.ctx) {
			a.state.was_down = false
			a.state.value = {}
			continue
		}
		switch a.kind {
		case .Button: resolve_button(&a, f)
		case .Axis:   resolve_axis(&a, f)
		}
	}
}

context_live :: proc(m: ^Manager, ctx: string) -> bool {
	return ctx == "global" || m.enabled[ctx]
}

// set_context enables/disables a context group (Step D turns this into a proper stack
// with exclusive gameplay/menu switching; for now it's a flat enabled-set).
set_context :: proc(m: ^Manager, ctx: string, on: bool) {
	m.enabled[ctx] = on
}

resolve_button :: proc(a: ^Action, f: ^Frame) {
	g := a.gesture
	if g.code == nil {
		a.state.down = false
		a.state.was_down = false
		return
	}
	down := code_down(f, g.code)
	for i in 0 ..< int(g.n_mods) {
		if !code_down(f, g.mods[i]) {
			down = false
			break
		}
	}
	was := a.state.was_down
	switch g.trigger {
	case .Press:
		if down && !was do a.state.fired = true
	case .Release:
		if !down && was do a.state.fired = true
	case .Hold:
		if down && !was {
			a.state.press_t = f.now_ms
			a.state.hold_fired = false
		}
		if down && !a.state.hold_fired && f.now_ms - a.state.press_t >= f64(g.hold_ms) {
			a.state.fired = true
			a.state.hold_fired = true
		}
	case .Tap:
		if down && !was {
			if f.now_ms - a.state.last_tap_t <= MULTI_TAP_MS {
				a.state.tap_count += 1
			} else {
				a.state.tap_count = 1
			}
			a.state.last_tap_t = f.now_ms
			need := u8(1) if g.taps == 0 else g.taps
			if a.state.tap_count >= need {
				a.state.fired = true
				a.state.tap_count = 0
			}
		}
	}
	a.state.down = down
	a.state.was_down = down
}

resolve_axis :: proc(a: ^Action, f: ^Frame) {
	v: [3]f32
	if code_down(f, a.axis_codes[Axis_Slot.Fwd])   do v.x += 1
	if code_down(f, a.axis_codes[Axis_Slot.Back])  do v.x -= 1
	if code_down(f, a.axis_codes[Axis_Slot.Right]) do v.y += 1
	if code_down(f, a.axis_codes[Axis_Slot.Left])  do v.y -= 1
	if code_down(f, a.axis_codes[Axis_Slot.Up])    do v.z += 1
	if code_down(f, a.axis_codes[Axis_Slot.Down])  do v.z -= 1
	if pa, ok := a.pad_axis.?; ok {
		v.x += f.pad_axes[pa[1]] * -1 // stick Y up = forward (SDL Y is down-positive)
		v.y += f.pad_axes[pa[0]]
	}
	a.state.value = v
}

code_down :: proc(f: ^Frame, c: Code) -> bool {
	switch v in c {
	case Key:
		#partial switch v {
		case .Ctrl:  return f.keys[.LCtrl]  || f.keys[.RCtrl]
		case .Shift: return f.keys[.LShift] || f.keys[.RShift]
		case .Alt:   return f.keys[.LAlt]   || f.keys[.RAlt]
		}
		return f.keys[v]
	case Mouse:
		return f.mouse[v]
	case Pad:
		return f.pad[v]
	}
	return false
}

// ---- Queries -------------------------------------------------------------------

// fired reports whether a Button action's trigger fired this frame (a one-frame edge).
fired :: proc(m: ^Manager, id: string) -> bool {
	if idx, has := m.index[id]; has do return m.actions[idx].state.fired
	return false
}

// held reports whether a Button action's code (and chord) is currently down.
held :: proc(m: ^Manager, id: string) -> bool {
	if idx, has := m.index[id]; has do return m.actions[idx].state.down
	return false
}

// axis3 returns an Axis action's composed vector this frame.
axis3 :: proc(m: ^Manager, id: string) -> [3]f32 {
	if idx, has := m.index[id]; has do return m.actions[idx].state.value
	return {}
}

// binding returns an action's current binding text (for the rebind UI / serialization).
binding :: proc(m: ^Manager, id: string) -> string {
	if idx, has := m.index[id]; has do return m.actions[idx].bind_str
	return ""
}

// action_glyph returns the prompt-atlas key for a Button action's CURRENT binding
// ("" for unknown/unbound/Axis actions — pair with action_label for a text fallback).
// This is the one query a prompt widget needs: it tracks rebinds automatically, and
// `style` picks the pad art family when the binding is a pad code.
action_glyph :: proc(m: ^Manager, id: string, style := Pad_Style.Xbox) -> string {
	idx, has := m.index[id]
	if !has do return ""
	a := &m.actions[idx]
	if a.kind != .Button do return ""
	return gesture_glyph(a.gesture, style)
}

// action_label returns the short human name of a Button action's primary code ("f",
// "mouse2", "pada"; "" if unbound) — the text fallback when action_glyph has no art.
action_label :: proc(m: ^Manager, id: string) -> string {
	idx, has := m.index[id]
	if !has do return ""
	a := &m.actions[idx]
	if a.kind != .Button do return ""
	return code_name(a.gesture.code)
}
