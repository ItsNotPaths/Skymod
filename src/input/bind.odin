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
// `name` is the canonical form written back to settings.txt; `glyph` is the baked
// prompt-atlas key (src/prompts, "<set-slug>/<kenney basename>"; empty = no art,
// caller falls back to text). Keyboard/mouse art lives in the "kbm" set; pad art is
// style-dependent (PAD_GLYPHS below), so PAD_TABLE carries names only.
// The engine maps to the "_outline" (dark-mode line-art) variants — the solid-fill art
// reads as white slabs over the 3D scene. Both variants are in the atlas; the only keys
// without an outline version are the stick-press glyphs, which stay solid.

Key_Entry :: struct { key: Key, name, glyph: string }
KEY_TABLE := [?]Key_Entry {
	{.A,"a","kbm/keyboard_a_outline"},{.B,"b","kbm/keyboard_b_outline"},{.C,"c","kbm/keyboard_c_outline"},
	{.D,"d","kbm/keyboard_d_outline"},{.E,"e","kbm/keyboard_e_outline"},{.F,"f","kbm/keyboard_f_outline"},
	{.G,"g","kbm/keyboard_g_outline"},{.H,"h","kbm/keyboard_h_outline"},{.I,"i","kbm/keyboard_i_outline"},
	{.J,"j","kbm/keyboard_j_outline"},{.K,"k","kbm/keyboard_k_outline"},{.L,"l","kbm/keyboard_l_outline"},
	{.M,"m","kbm/keyboard_m_outline"},{.N,"n","kbm/keyboard_n_outline"},{.O,"o","kbm/keyboard_o_outline"},
	{.P,"p","kbm/keyboard_p_outline"},{.Q,"q","kbm/keyboard_q_outline"},{.R,"r","kbm/keyboard_r_outline"},
	{.S,"s","kbm/keyboard_s_outline"},{.T,"t","kbm/keyboard_t_outline"},{.U,"u","kbm/keyboard_u_outline"},
	{.V,"v","kbm/keyboard_v_outline"},{.W,"w","kbm/keyboard_w_outline"},{.X,"x","kbm/keyboard_x_outline"},
	{.Y,"y","kbm/keyboard_y_outline"},{.Z,"z","kbm/keyboard_z_outline"},
	{.N0,"0","kbm/keyboard_0_outline"},{.N1,"1","kbm/keyboard_1_outline"},{.N2,"2","kbm/keyboard_2_outline"},
	{.N3,"3","kbm/keyboard_3_outline"},{.N4,"4","kbm/keyboard_4_outline"},{.N5,"5","kbm/keyboard_5_outline"},
	{.N6,"6","kbm/keyboard_6_outline"},{.N7,"7","kbm/keyboard_7_outline"},{.N8,"8","kbm/keyboard_8_outline"},
	{.N9,"9","kbm/keyboard_9_outline"},
	{.F1,"f1","kbm/keyboard_f1_outline"},{.F2,"f2","kbm/keyboard_f2_outline"},{.F3,"f3","kbm/keyboard_f3_outline"},
	{.F4,"f4","kbm/keyboard_f4_outline"},{.F5,"f5","kbm/keyboard_f5_outline"},{.F6,"f6","kbm/keyboard_f6_outline"},
	{.F7,"f7","kbm/keyboard_f7_outline"},{.F8,"f8","kbm/keyboard_f8_outline"},{.F9,"f9","kbm/keyboard_f9_outline"},
	{.F10,"f10","kbm/keyboard_f10_outline"},{.F11,"f11","kbm/keyboard_f11_outline"},{.F12,"f12","kbm/keyboard_f12_outline"},
	{.Space,"space","kbm/keyboard_space_outline"},{.Enter,"enter","kbm/keyboard_enter_outline"},
	{.Tab,"tab","kbm/keyboard_tab_outline"},
	{.Esc,"esc","kbm/keyboard_escape_outline"},{.Backspace,"backspace","kbm/keyboard_backspace_outline"},
	{.CapsLock,"capslock","kbm/keyboard_capslock_outline"},
	{.LShift,"lshift","kbm/keyboard_shift_outline"},{.RShift,"rshift","kbm/keyboard_shift_outline"},
	{.LCtrl,"lctrl","kbm/keyboard_ctrl_outline"},{.RCtrl,"rctrl","kbm/keyboard_ctrl_outline"},
	{.LAlt,"lalt","kbm/keyboard_alt_outline"},{.RAlt,"ralt","kbm/keyboard_alt_outline"},
	{.Ctrl,"ctrl","kbm/keyboard_ctrl_outline"},{.Shift,"shift","kbm/keyboard_shift_outline"},{.Alt,"alt","kbm/keyboard_alt_outline"},
	{.Up,"up","kbm/keyboard_arrow_up_outline"},{.Down,"down","kbm/keyboard_arrow_down_outline"},
	{.Left,"left","kbm/keyboard_arrow_left_outline"},{.Right,"right","kbm/keyboard_arrow_right_outline"},
	{.Grave,"grave","kbm/keyboard_tilde_outline"},
	{.Minus,"minus","kbm/keyboard_minus_outline"},{.Equals,"equals","kbm/keyboard_equals_outline"},
	{.LBracket,"lbracket","kbm/keyboard_bracket_open_outline"},{.RBracket,"rbracket","kbm/keyboard_bracket_close_outline"},
	{.Backslash,"backslash","kbm/keyboard_slash_back_outline"},{.Semicolon,"semicolon","kbm/keyboard_semicolon_outline"},
	{.Apostrophe,"apostrophe","kbm/keyboard_apostrophe_outline"},{.Comma,"comma","kbm/keyboard_comma_outline"},
	{.Period,"period","kbm/keyboard_period_outline"},{.Slash,"slash","kbm/keyboard_slash_forward_outline"},
}
// Extra spellings accepted on parse (never written back).
Key_Alias :: struct { name: string, key: Key }
KEY_ALIASES := [?]Key_Alias {
	{"escape",.Esc},{"return",.Enter},{"control",.Ctrl},{"tilde",.Grave},
	{"`",.Grave},{"spacebar",.Space},{"del",.Backspace},
}

Mouse_Entry :: struct { m: Mouse, name, glyph: string }
MOUSE_TABLE := [?]Mouse_Entry {
	{.Left,"mouse1","kbm/mouse_left_outline"},{.Right,"mouse2","kbm/mouse_right_outline"},
	{.Middle,"mouse3","kbm/mouse_scroll_outline"},
	{.X1,"mouse4","kbm/mouse_side_back_outline"},{.X2,"mouse5","kbm/mouse_side_forward_outline"},
	{.WheelUp,"wheelup","kbm/mouse_scroll_up_outline"},{.WheelDown,"wheeldown","kbm/mouse_scroll_down_outline"},
}
Mouse_Alias :: struct { name: string, m: Mouse }
MOUSE_ALIASES := [?]Mouse_Alias {
	{"lmb",.Left},{"rmb",.Right},{"mmb",.Middle},{"m1",.Left},{"m2",.Right},{"m3",.Middle},
}

Pad_Entry :: struct { p: Pad, name: string }
PAD_TABLE := [?]Pad_Entry {
	{.A,"pada"},{.B,"padb"},{.X,"padx"},{.Y,"pady"},
	{.LB,"padlb"},{.RB,"padrb"},{.LT,"padlt"},{.RT,"padrt"},
	{.Back,"padback"},{.Start,"padstart"},
	{.LS,"padls"},{.RS,"padrs"},
	{.DpadUp,"dpadup"},{.DpadDown,"dpaddown"},{.DpadLeft,"dpadleft"},{.DpadRight,"dpadright"},
}

// Pad_Style picks which device family's art a Pad code resolves to — hot-switched from
// the connected pad's reported type when gamepad polling lands (SDL_GetGamepadType), and
// eventually a settings override. The WHOLE Kenney set is baked (Wii, GameCube, Steam
// Controller, Playdate, …) and reachable by key from Lua; these are the styles the engine
// auto-maps our Pad vocabulary onto. Unknown/odd devices (steering wheels, wiimotes-as-
// joysticks) read best with the familiar Xbox layout, so that's the default.
Pad_Style :: enum u8 {
	Xbox,
	PlayStation,
	Switch,
	Steam_Deck,
}

// PAD_GLYPHS: prompt-atlas key per (style, pad button). Xbox A/B/X/Y use the coloured-
// letter variants (closest to how players know them); PlayStation face buttons map by
// POSITION (A=cross, B=circle, X=square, Y=triangle — the SDL/Xbox convention).
PAD_GLYPHS := [Pad_Style][Pad]string {
	.Xbox = {
		.Invalid = "",
		.A = "xbox/xbox_button_color_a_outline", .B = "xbox/xbox_button_color_b_outline",
		.X = "xbox/xbox_button_color_x_outline", .Y = "xbox/xbox_button_color_y_outline",
		.LB = "xbox/xbox_lb_outline", .RB = "xbox/xbox_rb_outline",
		.LT = "xbox/xbox_lt_outline", .RT = "xbox/xbox_rt_outline",
		.Back = "xbox/xbox_button_view_outline", .Start = "xbox/xbox_button_menu_outline",
		.LS = "xbox/xbox_stick_l_press", .RS = "xbox/xbox_stick_r_press",
		.DpadUp = "xbox/xbox_dpad_up_outline", .DpadDown = "xbox/xbox_dpad_down_outline",
		.DpadLeft = "xbox/xbox_dpad_left_outline", .DpadRight = "xbox/xbox_dpad_right_outline",
	},
	.PlayStation = {
		.Invalid = "",
		.A = "ps/playstation_button_color_cross_outline", .B = "ps/playstation_button_color_circle_outline",
		.X = "ps/playstation_button_color_square_outline", .Y = "ps/playstation_button_color_triangle_outline",
		.LB = "ps/playstation_trigger_l1_outline", .RB = "ps/playstation_trigger_r1_outline",
		.LT = "ps/playstation_trigger_l2_outline", .RT = "ps/playstation_trigger_r2_outline",
		.Back = "ps/playstation5_button_create_outline", .Start = "ps/playstation5_button_options_outline",
		.LS = "ps/playstation_button_l3_outline", .RS = "ps/playstation_button_r3_outline",
		.DpadUp = "ps/playstation_dpad_up_outline", .DpadDown = "ps/playstation_dpad_down_outline",
		.DpadLeft = "ps/playstation_dpad_left_outline", .DpadRight = "ps/playstation_dpad_right_outline",
	},
	.Switch = {
		.Invalid = "",
		.A = "switch/switch_button_a_outline", .B = "switch/switch_button_b_outline",
		.X = "switch/switch_button_x_outline", .Y = "switch/switch_button_y_outline",
		.LB = "switch/switch_button_l_outline", .RB = "switch/switch_button_r_outline",
		.LT = "switch/switch_button_zl_outline", .RT = "switch/switch_button_zr_outline",
		.Back = "switch/switch_button_minus_outline", .Start = "switch/switch_button_plus_outline",
		.LS = "switch/switch_stick_l_press", .RS = "switch/switch_stick_r_press",
		.DpadUp = "switch/switch_dpad_up_outline", .DpadDown = "switch/switch_dpad_down_outline",
		.DpadLeft = "switch/switch_dpad_left_outline", .DpadRight = "switch/switch_dpad_right_outline",
	},
	.Steam_Deck = {
		.Invalid = "",
		.A = "steamdeck/steamdeck_button_a_outline", .B = "steamdeck/steamdeck_button_b_outline",
		.X = "steamdeck/steamdeck_button_x_outline", .Y = "steamdeck/steamdeck_button_y_outline",
		.LB = "steamdeck/steamdeck_button_l1_outline", .RB = "steamdeck/steamdeck_button_r1_outline",
		.LT = "steamdeck/steamdeck_button_l2_outline", .RT = "steamdeck/steamdeck_button_r2_outline",
		.Back = "steamdeck/steamdeck_button_view_outline", .Start = "steamdeck/steamdeck_button_options_outline",
		.LS = "steamdeck/steamdeck_stick_l_press", .RS = "steamdeck/steamdeck_stick_r_press",
		.DpadUp = "steamdeck/steamdeck_dpad_up_outline", .DpadDown = "steamdeck/steamdeck_dpad_down_outline",
		.DpadLeft = "steamdeck/steamdeck_dpad_left_outline", .DpadRight = "steamdeck/steamdeck_dpad_right_outline",
	},
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

// glyph_name returns the prompt-atlas key for a code ("" if none — caller shows text).
// Keyboard/mouse codes are style-independent; a Pad code resolves through `style`.
glyph_name :: proc(c: Code, style := Pad_Style.Xbox) -> string {
	switch v in c {
	case Key:   for e in KEY_TABLE   do if e.key == v do return e.glyph
	case Mouse: for e in MOUSE_TABLE do if e.m == v do return e.glyph
	case Pad:   return PAD_GLYPHS[style][v]
	}
	return ""
}

// gesture_glyph returns the prompt-atlas key for a Button action's primary code (chord
// modifiers are not rendered — the primary code is the recognisable part of the hint).
gesture_glyph :: proc(g: Gesture, style := Pad_Style.Xbox) -> string {
	return glyph_name(g.code, style)
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
