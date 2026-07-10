package unit_tests

// Unit tests for src/input: the binding-text grammar (parse/serialize round-trip,
// incl. x-tap and chords) and the per-frame gesture resolver state machine
// (press / release / hold(ms) / N-tap / chord / axis). Hermetic — no SDL, no files.

import "core:testing"
import "../../src/input"

// round-trips a binding string through parse -> serialize -> parse and checks the two
// parses are identical (canonical form need not equal the input spelling).
@(test)
test_input_bind_roundtrip :: proc(t: ^testing.T) {
	cases := []string {
		"e",
		"e release",
		"f hold 250",
		"lshift hold",
		"q 2tap",
		"q tap",
		"ctrl+e",
		"ctrl+shift+e 3tap",
		"mouse2",
		"pada",
		"grave",
	}
	for s in cases {
		g1, ok1 := input.parse_gesture(s)
		testing.expectf(t, ok1, "parse %q", s)
		canon := input.serialize_gesture(g1, context.temp_allocator)
		g2, ok2 := input.parse_gesture(canon)
		testing.expectf(t, ok2, "reparse %q -> %q", s, canon)
		testing.expectf(t, g1 == g2, "round-trip mismatch %q -> %q", s, canon)
	}

	// specific fields
	g, _ := input.parse_gesture("ctrl+shift+e 3tap")
	testing.expect(t, g.code == input.Key.E, "primary code E")
	testing.expect(t, g.n_mods == 2, "two chord mods")
	testing.expect(t, g.trigger == .Tap && g.taps == 3, "3-tap")

	h, _ := input.parse_gesture("f hold 250")
	testing.expect(t, h.trigger == .Hold && h.hold_ms == 250, "hold 250ms")

	// malformed
	_, bad1 := input.parse_gesture("notakey")
	testing.expect(t, !bad1, "unknown code rejected")
	_, bad2 := input.parse_gesture("e 12tap")
	testing.expect(t, !bad2, "multi-digit tap rejected (single digit only)")
}

// helper: a fresh manager with one gameplay Button action bound to `bind`.
setup_button :: proc(bind: string) -> input.Manager {
	m: input.Manager
	input.init(&m)
	input.register(&m, "Test", "gameplay", .Button, bind)
	return m
}

// helper: one frame with the given keys held, at time `now_ms`.
frame :: proc(now_ms: f64, keys: ..input.Key) -> input.Frame {
	f := input.Frame{ now_ms = now_ms, device = .Key_Mouse }
	for k in keys do f.keys[k] = true
	return f
}

@(test)
test_input_press_edge :: proc(t: ^testing.T) {
	m := setup_button("e")
	defer input.destroy(&m)

	f0 := frame(0, .E)
	input.update(&m, &f0)
	testing.expect(t, input.fired(&m, "Test"), "press fires on down edge")

	f1 := frame(16, .E) // still held
	input.update(&m, &f1)
	testing.expect(t, !input.fired(&m, "Test"), "no re-fire while held")
	testing.expect(t, input.held(&m, "Test"), "reports held")

	f2 := frame(32) // released
	input.update(&m, &f2)
	testing.expect(t, !input.fired(&m, "Test"), "no fire on release for press trigger")
}

@(test)
test_input_release_edge :: proc(t: ^testing.T) {
	m := setup_button("e release")
	defer input.destroy(&m)

	f0 := frame(0, .E)
	input.update(&m, &f0)
	testing.expect(t, !input.fired(&m, "Test"), "no fire on down for release trigger")
	f1 := frame(16) // up
	input.update(&m, &f1)
	testing.expect(t, input.fired(&m, "Test"), "fires on up edge")
}

@(test)
test_input_hold :: proc(t: ^testing.T) {
	m := setup_button("f hold 250")
	defer input.destroy(&m)

	f := frame(0, .F);   input.update(&m, &f)
	testing.expect(t, !input.fired(&m, "Test"), "no fire immediately")
	f = frame(100, .F);  input.update(&m, &f)
	testing.expect(t, !input.fired(&m, "Test"), "no fire before threshold")
	f = frame(300, .F);  input.update(&m, &f)
	testing.expect(t, input.fired(&m, "Test"), "fires after threshold")
	f = frame(400, .F);  input.update(&m, &f)
	testing.expect(t, !input.fired(&m, "Test"), "fires only once per hold")
}

@(test)
test_input_xtap :: proc(t: ^testing.T) {
	m := setup_button("q 3tap")
	defer input.destroy(&m)

	// three quick down-edges within the window -> fires on the third
	steps := []struct{ now: f64, down: bool, want: bool } {
		{0,   true,  false},
		{16,  false, false},
		{32,  true,  false},
		{48,  false, false},
		{64,  true,  true},  // third press -> fire
		{80,  false, false},
	}
	for s in steps {
		f: input.Frame
		if s.down {
			f = frame(s.now, .Q)
		} else {
			f = frame(s.now)
		}
		input.update(&m, &f)
		testing.expectf(t, input.fired(&m, "Test") == s.want, "xtap step @%v", s.now)
	}

	// two presses spaced beyond the window must NOT complete a 3-tap
	f := frame(1000, .Q); input.update(&m, &f)
	f = frame(1016);      input.update(&m, &f)
	f = frame(5000, .Q);  input.update(&m, &f)
	testing.expect(t, !input.fired(&m, "Test"), "stale taps expire")
}

@(test)
test_input_chord :: proc(t: ^testing.T) {
	m := setup_button("ctrl+e")
	defer input.destroy(&m)

	f0 := frame(0, .E) // E without ctrl
	input.update(&m, &f0)
	testing.expect(t, !input.fired(&m, "Test"), "no fire without modifier")

	f1 := frame(16, .LCtrl, .E) // ctrl (left) + E
	input.update(&m, &f1)
	testing.expect(t, input.fired(&m, "Test"), "fires with chord satisfied")
}

@(test)
test_input_axis :: proc(t: ^testing.T) {
	m: input.Manager
	input.init(&m)
	defer input.destroy(&m)
	input.register(&m, "Move", "gameplay", .Axis, "w s d a e q")

	f := frame(0, .W, .D)
	input.update(&m, &f)
	v := input.axis3(&m, "Move")
	testing.expect(t, v.x == 1 && v.y == 1, "W+D -> +x +y")

	f = frame(16, .S, .A, .Q)
	input.update(&m, &f)
	v = input.axis3(&m, "Move")
	testing.expect(t, v.x == -1 && v.y == -1 && v.z == -1, "S+A+Q -> -x -y -z")
}

@(test)
test_input_context_gate :: proc(t: ^testing.T) {
	m := setup_button("e")
	defer input.destroy(&m)
	input.set_context(&m, "gameplay", false) // disable

	f := frame(0, .E)
	input.update(&m, &f)
	testing.expect(t, !input.fired(&m, "Test"), "disabled context does not fire")

	input.set_context(&m, "gameplay", true)
	f = frame(16, .E)
	input.update(&m, &f)
	testing.expect(t, input.fired(&m, "Test"), "re-enabled context fires on fresh edge")
}
