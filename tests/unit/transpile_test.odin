package unit_tests

// PEX → Lua transpiler tests. Hermetic + SYNTHETIC: a hand-built big-endian PEX image
// carrying the cases that break a naive emitter — a relative jump landing one past the last
// instruction, a self-cast, a void call, a parameter named after a Lua keyword. Real
// correctness is proven by running tools/pex2lua over the user's own ~14k .pex and checking
// every emitted file with `luac -p` (docs/papyrus-transpiler.md).
//
// Writers are file-private, matching the convention in pex_test.odin and esm_test.odin.

import "core:strings"
import "core:testing"
import "../../src/formats/pex"
import "../../src/transpile"

@(private = "file")
tw16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v >> 8), u8(v))}

@(private = "file")
tw32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

@(private = "file")
tw64 :: proc(b: ^[dynamic]u8, v: u64) {
	for s := uint(56); ; s -= 8 {
		append(b, u8(v >> s))
		if s == 0 {break}
	}
}

@(private = "file")
tws :: proc(b: ^[dynamic]u8, s: string) {
	tw16(b, u16(len(s)))
	append(b, ..transmute([]u8)s)
}

@(private = "file")
ti :: proc(b: ^[dynamic]u8, idx: u16) {append(b, 1);tw16(b, idx)} // identifier
@(private = "file")
tn :: proc(b: ^[dynamic]u8, v: i32) {append(b, 3);tw32(b, u32(v))} // integer
@(private = "file")
tb :: proc(b: ^[dynamic]u8, x: bool) {append(b, 5);append(b, x ? 1 : 0)} // bool

// String-table layout for the fixture.
@(private = "file")
T_OBJ :: 0 // "Test"
@(private = "file")
T_PARENT :: 1 // "ScriptObject"
@(private = "file")
T_EMPTY :: 2 // "" — doc, auto-state, default state
@(private = "file")
T_FUNC :: 3 // "Doit"
@(private = "file")
T_BOOL :: 4 // "Bool"
@(private = "file")
T_INT :: 5 // "Int"
@(private = "file")
T_PARAM :: 6 // "end" — a Lua reserved word
@(private = "file")
T_TEMP :: 7 // "::temp0"
@(private = "file")
T_NONE :: 8 // "::NoneVar"
@(private = "file")
T_METHOD :: 9 // "Foo"

// build_transpile_pex writes one object with one function:
//
//   0  CmpGe      ::temp0 end 0
//   1  Cast       ::temp0 ::temp0     -- self-cast, T1 drops it
//   2  JmpF       ::temp0 3           -- relative: target is 2+3 = 5, one PAST the end
//   3  CallMethod Foo self ::NoneVar  -- void sink, T1 makes it a bare statement
//   4  Return     true
@(private = "file")
build_transpile_pex :: proc() -> []u8 {
	b := make([dynamic]u8)

	tw32(&b, pex.MAGIC)
	append(&b, 3, 2) // major, minor (Special Edition is 3.2)
	tw16(&b, 1) // game id
	tw64(&b, 0x1122_3344)
	tws(&b, "Test.psc")
	tws(&b, "user")
	tws(&b, "machine")

	tw16(&b, 10)
	tws(&b, "Test")
	tws(&b, "ScriptObject")
	tws(&b, "")
	tws(&b, "Doit")
	tws(&b, "Bool")
	tws(&b, "Int")
	tws(&b, "end")
	tws(&b, "::temp0")
	tws(&b, "::NoneVar")
	tws(&b, "Foo")

	// Debug info: one source line per instruction, so the line-comment option has data.
	append(&b, 1) // has_debug
	tw64(&b, 0) // modification time
	tw16(&b, 1) // function count
	tw16(&b, T_OBJ);tw16(&b, T_EMPTY);tw16(&b, T_FUNC)
	append(&b, 0) // function type
	tw16(&b, 5) // instruction count
	for l in u16(10) ..= u16(14) {
		tw16(&b, l)
	}

	tw16(&b, 0) // user-flag count

	tw16(&b, 1) // objects
	tw16(&b, T_OBJ)
	tw32(&b, 0) // size (parser walks sequentially)
	tw16(&b, T_PARENT)
	tw16(&b, T_EMPTY) // doc
	tw32(&b, 0) // user flags
	tw16(&b, T_EMPTY) // auto state
	tw16(&b, 0) // variables
	tw16(&b, 0) // properties
	tw16(&b, 1) // states
	tw16(&b, T_EMPTY) // default state
	tw16(&b, 1) // function count
	tw16(&b, T_FUNC) // named-function prefix

	tw16(&b, T_BOOL) // return type
	tw16(&b, T_EMPTY) // doc
	tw32(&b, 0) // user flags
	append(&b, 0) // flags: instance, not native
	tw16(&b, 1) // params
	tw16(&b, T_PARAM);tw16(&b, T_INT)
	tw16(&b, 2) // locals
	tw16(&b, T_TEMP);tw16(&b, T_BOOL)
	tw16(&b, T_NONE);tw16(&b, T_EMPTY)
	tw16(&b, 5) // instructions

	append(&b, u8(pex.Opcode.CmpGe));ti(&b, T_TEMP);ti(&b, T_PARAM);tn(&b, 0)
	append(&b, u8(pex.Opcode.Cast));ti(&b, T_TEMP);ti(&b, T_TEMP)
	append(&b, u8(pex.Opcode.JmpF));ti(&b, T_TEMP);tn(&b, 3)
	append(&b, u8(pex.Opcode.CallMethod));ti(&b, T_METHOD);ti(&b, T_OBJ);ti(&b, T_NONE);tn(&b, 0)
	append(&b, u8(pex.Opcode.Return));tb(&b, true)

	return b[:]
}

@(test)
test_transpile_emits_t0 :: proc(t: ^testing.T) {
	data := build_transpile_pex()
	defer delete(data)
	p, pok := pex.parse(data)
	defer pex.destroy(&p)
	testing.expect(t, pok, "fixture parses")

	src, st := transpile.transpile(&p)
	defer delete(src)

	has :: proc(t: ^testing.T, src, want: string) {
		testing.expectf(t, strings.contains(src, want), "missing %q in:\n%s", want, src)
	}

	has(t, src, `local Test = rt.class("Test", "ScriptObject")`)
	has(t, src, `Test.__fn["Doit"] = function(self, end_)`) // reserved word mangled
	has(t, src, "local __temp0, __NoneVar")
	has(t, src, "__temp0 = end_ >= 0")
	// A jump offset is relative to its own index: 2 + 3 = 5, one past the last instruction.
	has(t, src, "if not __temp0 then goto L5 end")
	has(t, src, "::L5::")
	// `return` may not sit mid-block in Lua.
	has(t, src, "do return true end")

	testing.expect_value(t, st.objects, 1)
	testing.expect_value(t, st.bodied, 1)
	testing.expect_value(t, st.labels, 1)
	testing.expect_value(t, st.instructions, 5)
}

@(test)
test_transpile_t1_cleanups :: proc(t: ^testing.T) {
	data := build_transpile_pex()
	defer delete(data)
	p, _ := pex.parse(data)
	defer pex.destroy(&p)

	src, st := transpile.transpile(&p)
	defer delete(src)

	// A void call loses its assignment and becomes a statement.
	testing.expect(t, strings.contains(src, `rt.call(Test, "Foo")`), "bare call")
	testing.expect(t, !strings.contains(src, "__NoneVar = rt.call"), "no sink assignment")
	testing.expect_value(t, st.bare_calls, 1)

	// The self-cast is gone entirely.
	testing.expect(t, !strings.contains(src, "rt.cast"), "self-cast dropped")
	testing.expect_value(t, st.dropped_cast, 1)

	// Five instructions in, one dropped, four statements out.
	testing.expect_value(t, st.statements, 4)
}

@(test)
test_transpile_keeps_debug_lines :: proc(t: ^testing.T) {
	data := build_transpile_pex()
	defer delete(data)
	p, _ := pex.parse(data)
	defer pex.destroy(&p)

	testing.expect(t, p.has_debug, "fixture carries debug info")
	f := p.objects[0].states[0].functions[0]
	testing.expect_value(t, f.instructions[0].line, u16(10))
	testing.expect_value(t, f.instructions[4].line, u16(14))

	src, st := transpile.transpile(&p, transpile.Options{line_comments = true})
	defer delete(src)
	testing.expect(t, strings.contains(src, "-- :10"), "first statement carries its line")
	testing.expect_value(t, st.with_lines, 1)
}

// The reader fixture from pex_test.odin doubles as a second input: a global-free instance
// function whose only call is a callstatic.
@(test)
test_transpile_callstatic :: proc(t: ^testing.T) {
	data := build_pex()
	defer delete(data)
	p, _ := pex.parse(data)
	defer pex.destroy(&p)

	src, st := transpile.transpile(&p)
	defer delete(src)

	testing.expect(
		t,
		strings.contains(src, `__temp0 = rt.static("Game", "GetPlayer")`),
		"callstatic shape",
	)
	testing.expect_value(t, st.labels, 0) // nothing jumps
	testing.expect_value(t, st.statements, 2)
}
