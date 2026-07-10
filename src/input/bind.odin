package input

// Binding text <-> parsed gesture, the human-facing grammar that lives in settings.txt
// and that the (later) rebind UI edits as railed text. Grammar for a Button action:
//
//     [<mod>+...]<code> [<trigger>]
//
//   code     a key/mouse/pad name: e   f5   space   lshift   mouse2   pada   grave
//   mod      a chord modifier held with the code: ctrl+e   shift+alt+f
//   trigger  press (default) | release | hold [ms] | [N]tap
//              hold 250   -> fires after 250ms held
//              hold       -> fires after HOLD_MS_DEFAULT
//              2tap       -> double-tap (N is one digit, 1..9; `tap` == 1tap)
//
// Axis actions (movement) bind a space-separated code list in Axis_Slot order
// (fwd back right left up down), or a stick name:  "w s d a e q"   or   "lstick".
//
// Names are case-insensitive. Parsing runs at load / rebind time, never per frame, so
// linear table scans are fine.

import "core:strconv"
import "core:strings"

// ---- Name tables ---------------------------------------------------------------
// `name` is the canonical form written back to settings.txt; `glyph` is the base
// filename under interface/exported/ (empty = no art, caller falls back to text).

Key_Entry :: struct { key: Key, name, glyph: string }
KEY_TABLE := [?]Key_Entry {
	{.A,"a","a"},{.B,"b","b"},{.C,"c","c"},{.D,"d","d"},{.E,"e","e"},{.F,"f","f"},
	{.G,"g","g"},{.H,"h","h"},{.I,"i","i"},{.J,"j","j"},{.K,"k","k"},{.L,"l","l"},
	{.M,"m","m"},{.N,"n","n"},{.O,"o","o"},{.P,"p","p"},{.Q,"q","q"},{.R,"r","r"},
	{.S,"s","s"},{.T,"t","t"},{.U,"u","u"},{.V,"v","v"},{.W,"w","w"},{.X,"x","x"},
	{.Y,"y","y"},{.Z,"z","z"},
	{.N0,"0","0"},{.N1,"1","1"},{.N2,"2","2"},{.N3,"3","3"},{.N4,"4","4"},
	{.N5,"5","5"},{.N6,"6","6"},{.N7,"7","7"},{.N8,"8","8"},{.N9,"9","9"},
	{.F1,"f1","f1"},{.F2,"f2","f2"},{.F3,"f3","f3"},{.F4,"f4","f4"},{.F5,"f5","f5"},
	{.F6,"f6","f6"},{.F7,"f7","f7"},{.F8,"f8","f8"},{.F9,"f9","f9"},{.F10,"f10","f10"},
	{.F11,"f11","f11"},{.F12,"f12","f12"},
	{.Space,"space","space"},{.Enter,"enter","enter"},{.Tab,"tab","tab"},
	{.Esc,"esc","esc"},{.Backspace,"backspace","backspace"},{.CapsLock,"capslock","capslock"},
	{.LShift,"lshift","l-shift"},{.RShift,"rshift","r-shift"},
	{.LCtrl,"lctrl","l-ctrl"},{.RCtrl,"rctrl","r-ctrl"},
	{.LAlt,"lalt","l-alt"},{.RAlt,"ralt","r-alt"},
	{.Ctrl,"ctrl","l-ctrl"},{.Shift,"shift","l-shift"},{.Alt,"alt","l-alt"},
	{.Up,"up","up"},{.Down,"down","down"},{.Left,"left","left"},{.Right,"right","right"},
	{.Grave,"grave","tilde"},
	{.Minus,"minus","hyphen"},{.Equals,"equals","equal"},
	{.LBracket,"lbracket","bracketleft"},{.RBracket,"rbracket","bracketright"},
	{.Backslash,"backslash","backslash"},{.Semicolon,"semicolon","semicolon"},
	{.Apostrophe,"apostrophe","quotesingle"},{.Comma,"comma","comma"},
	{.Period,"period","period"},{.Slash,"slash","slash"},
}
// Extra spellings accepted on parse (never written back).
Key_Alias :: struct { name: string, key: Key }
KEY_ALIASES := [?]Key_Alias {
	{"escape",.Esc},{"return",.Enter},{"control",.Ctrl},{"tilde",.Grave},
	{"`",.Grave},{"spacebar",.Space},{"del",.Backspace},
}

Mouse_Entry :: struct { m: Mouse, name, glyph: string }
MOUSE_TABLE := [?]Mouse_Entry {
	{.Left,"mouse1","mouse1"},{.Right,"mouse2","mouse2"},{.Middle,"mouse3","mouse3"},
	{.X1,"mouse4","mouse4"},{.X2,"mouse5","mouse5"},
	{.WheelUp,"wheelup","mousemove"},{.WheelDown,"wheeldown","mousemove"},
}
Mouse_Alias :: struct { name: string, m: Mouse }
MOUSE_ALIASES := [?]Mouse_Alias {
	{"lmb",.Left},{"rmb",.Right},{"mmb",.Middle},{"m1",.Left},{"m2",.Right},{"m3",.Middle},
}

Pad_Entry :: struct { p: Pad, name, glyph: string }
PAD_TABLE := [?]Pad_Entry {
	{.A,"pada","360_a"},{.B,"padb","360_b"},{.X,"padx","360_x"},{.Y,"pady","360_y"},
	{.LB,"padlb","360_lb"},{.RB,"padrb","360_rb"},{.LT,"padlt","360_lt"},{.RT,"padrt","360_rt"},
	{.Back,"padback","360_back"},{.Start,"padstart","360_start"},
	{.LS,"padls","360_ls"},{.RS,"padrs","360_rs"},
	{.DpadUp,"dpadup",""},{.DpadDown,"dpaddown",""},{.DpadLeft,"dpadleft",""},{.DpadRight,"dpadright",""},
}

// ---- Name <-> Code -------------------------------------------------------------

parse_code :: proc(token: string) -> (Code, bool) {
	t := strings.to_lower(token, context.temp_allocator)
	for e in KEY_TABLE   do if e.name == t do return e.key, true
	for a in KEY_ALIASES do if a.name == t do return a.key, true
	for e in MOUSE_TABLE   do if e.name == t do return e.m, true
	for a in MOUSE_ALIASES do if a.name == t do return a.m, true
	for e in PAD_TABLE do if e.name == t do return e.p, true
	return nil, false
}

// code_name returns the canonical serialize name for a code ("" if unknown/nil).
code_name :: proc(c: Code) -> string {
	switch v in c {
	case Key:   for e in KEY_TABLE   do if e.key == v do return e.name
	case Mouse: for e in MOUSE_TABLE do if e.m == v do return e.name
	case Pad:   for e in PAD_TABLE   do if e.p == v do return e.name
	}
	return ""
}

// glyph_name returns the interface/exported base filename for a code ("" if none).
glyph_name :: proc(c: Code) -> string {
	switch v in c {
	case Key:   for e in KEY_TABLE   do if e.key == v do return e.glyph
	case Mouse: for e in MOUSE_TABLE do if e.m == v do return e.glyph
	case Pad:   for e in PAD_TABLE   do if e.p == v do return e.glyph
	}
	return ""
}

// gesture_glyph returns the base glyph filename for a Button action's primary code.
gesture_glyph :: proc(g: Gesture) -> string {
	return glyph_name(g.code)
}

// ---- Parse ---------------------------------------------------------------------

parse_gesture :: proc(s: string) -> (Gesture, bool) {
	g: Gesture
	g.trigger = .Press
	fields := strings.fields(s, context.temp_allocator)
	if len(fields) == 0 do return g, false

	// fields[0] = [mod+...]code
	parts := strings.split(fields[0], "+", context.temp_allocator)
	// last part is the primary code; the rest are modifiers
	code, ok := parse_code(parts[len(parts) - 1])
	if !ok do return g, false
	g.code = code
	for i in 0 ..< len(parts) - 1 {
		if int(g.n_mods) >= MAX_MODS do return g, false
		mc, mok := parse_code(parts[i])
		if !mok do return g, false
		g.mods[g.n_mods] = mc
		g.n_mods += 1
	}

	// trigger tokens (fields[1..])
	if len(fields) >= 2 {
		tok := strings.to_lower(fields[1], context.temp_allocator)
		switch {
		case tok == "press":
			g.trigger = .Press
		case tok == "release":
			g.trigger = .Release
		case tok == "hold":
			g.trigger = .Hold
			g.hold_ms = HOLD_MS_DEFAULT
			if len(fields) >= 3 {
				if ms, mok := strconv.parse_int(fields[2], 10); mok && ms > 0 {
					g.hold_ms = u16(ms)
				} else {
					return g, false
				}
			}
		case strings.has_suffix(tok, "tap"):
			g.trigger = .Tap
			prefix := tok[:len(tok) - 3]
			if prefix == "" {
				g.taps = 1
			} else if len(prefix) == 1 && prefix[0] >= '1' && prefix[0] <= '9' {
				g.taps = u8(prefix[0] - '0')
			} else {
				return g, false // x-tap is a single digit 1..9
			}
		case:
			return g, false
		}
	}
	return g, true
}

parse_axis :: proc(s: string, codes: ^[6]Code, pad_axis: ^Maybe([2]Pad_Axis)) -> bool {
	fields := strings.fields(s, context.temp_allocator)
	slot := 0
	for tok in fields {
		lt := strings.to_lower(tok, context.temp_allocator)
		switch lt {
		case "lstick":
			pad_axis^ = [2]Pad_Axis{.LeftX, .LeftY}
			continue
		case "rstick":
			pad_axis^ = [2]Pad_Axis{.RightX, .RightY}
			continue
		}
		if slot >= 6 do return false
		c, ok := parse_code(tok)
		if !ok do return false
		codes[slot] = c
		slot += 1
	}
	return true
}

// ---- Serialize -----------------------------------------------------------------

// serialize_gesture renders a Gesture back to canonical binding text (allocated by the
// caller's allocator). parse(serialize(g)) reproduces g.
serialize_gesture :: proc(g: Gesture, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< int(g.n_mods) {
		strings.write_string(&b, code_name(g.mods[i]))
		strings.write_byte(&b, '+')
	}
	strings.write_string(&b, code_name(g.code))
	switch g.trigger {
	case .Press:
	case .Release:
		strings.write_string(&b, " release")
	case .Hold:
		strings.write_string(&b, " hold ")
		strings.write_int(&b, int(g.hold_ms))
	case .Tap:
		strings.write_byte(&b, ' ')
		n := u8(1) if g.taps == 0 else g.taps
		strings.write_int(&b, int(n))
		strings.write_string(&b, "tap")
	}
	return strings.to_string(b)
}
