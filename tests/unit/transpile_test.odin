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
//   3  CallMethod Foo Test ::NoneVar  -- void sink, T1 makes it a bare statement
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

	// no_inline pins the T0 shape: one statement per instruction, temps left standing.
	src, st := transpile.transpile(&p, transpile.Options{no_inline = true})
	defer delete(src)

	has :: proc(t: ^testing.T, src, want: string) {
		testing.expectf(t, strings.contains(src, want), "missing %q in:\n%s", want, src)
	}

	has(t, src, `local Test = rt.class("Test", "ScriptObject")`)
	has(t, src, `Test.__fn["doit"] = function(self, _kend)`) // reserved word mangled, key folded
	has(t, src, "local __temp0, __NoneVar = false") // locals start at their type's zero
	has(t, src, "__temp0 = _kend >= 0")
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

	src, st := transpile.transpile(&p, transpile.Options{no_inline = true})
	defer delete(src)

	// A void call loses its assignment and becomes a statement.
	// `Test` is no local or parameter, so it resolves as a member of the instance.
	testing.expect(t, strings.contains(src, `rt.call(self.vars["test"], "Foo")`), "bare call")
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

	// no_inline keeps one statement per instruction, so each line lands where it was read.
	// With T2 on, instruction 0 folds into instruction 2 and its line goes with it.
	opt := transpile.Options{line_comments = true, no_inline = true}
	src, st := transpile.transpile(&p, opt)
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

@(test)
test_transpile_t2_inlines_temp :: proc(t: ^testing.T) {
	data := build_transpile_pex()
	defer delete(data)
	p, _ := pex.parse(data)
	defer pex.destroy(&p)

	src, st := transpile.transpile(&p)
	defer delete(src)

	// The comparison folds into the jump that reads it, and its temp disappears.
	testing.expectf(
		t,
		strings.contains(src, "if not (_kend >= 0) then goto L5 end"),
		"temp not folded into its reader:\n%s",
		src,
	)
	testing.expect(t, !strings.contains(src, "__temp0 = _kend"), "definition removed")
	testing.expect_value(t, st.inlined, 1)
	testing.expect_value(t, st.statements, 3) // one fewer than the T0 shape
}

// A temp read by a LATER block must keep its definition. Folding it would leave the second
// reader with no value — the condition `exposed` exists to catch.
@(private = "file")
build_escaping_temp_pex :: proc() -> []u8 {
	b := make([dynamic]u8)

	tw32(&b, pex.MAGIC)
	append(&b, 3, 2)
	tw16(&b, 1)
	tw64(&b, 0)
	tws(&b, "Esc.psc");tws(&b, "u");tws(&b, "m")

	tw16(&b, 9)
	tws(&b, "Esc")        // 0
	tws(&b, "ScriptObject") // 1
	tws(&b, "")           // 2
	tws(&b, "Run")        // 3
	tws(&b, "Bool")       // 4
	tws(&b, "Int")        // 5
	tws(&b, "n")          // 6
	tws(&b, "::temp0")    // 7
	tws(&b, "::temp1")    // 8

	append(&b, 0) // no debug
	tw16(&b, 0) // user flags

	tw16(&b, 1)
	tw16(&b, 0);tw32(&b, 0);tw16(&b, 1);tw16(&b, 2);tw32(&b, 0);tw16(&b, 2)
	tw16(&b, 0);tw16(&b, 0) // vars, props
	tw16(&b, 1);tw16(&b, 2);tw16(&b, 1);tw16(&b, 3) // one state, one function "Run"

	tw16(&b, 4);tw16(&b, 2);tw32(&b, 0);append(&b, 0) // -> Bool, doc, flags
	tw16(&b, 1);tw16(&b, 6);tw16(&b, 5) // param n: Int
	tw16(&b, 2);tw16(&b, 7);tw16(&b, 4);tw16(&b, 8);tw16(&b, 4) // locals ::temp0, ::temp1
	tw16(&b, 4) // instructions

	//  0  CmpGe ::temp0 n 0
	//  1  JmpF  ::temp0 2      -- block ends; target is 1+2 = 3
	//  2  Assign ::temp1 true
	//  3  Assign ::temp1 ::temp0   -- LABEL: reads ::temp0 from another block
	append(&b, u8(pex.Opcode.CmpGe));ti(&b, 7);ti(&b, 6);tn(&b, 0)
	append(&b, u8(pex.Opcode.JmpF));ti(&b, 7);tn(&b, 2)
	append(&b, u8(pex.Opcode.Assign));ti(&b, 8);tb(&b, true)
	append(&b, u8(pex.Opcode.Assign));ti(&b, 8);ti(&b, 7)

	return b[:]
}

@(test)
test_transpile_t2_keeps_escaping_temp :: proc(t: ^testing.T) {
	data := build_escaping_temp_pex()
	defer delete(data)
	p, pok := pex.parse(data)
	defer pex.destroy(&p)
	testing.expect(t, pok, "fixture parses")

	src, st := transpile.transpile(&p)
	defer delete(src)

	testing.expectf(
		t,
		strings.contains(src, "__temp0 = n >= 0"),
		"a temp read by a later block must keep its definition:\n%s",
		src,
	)
	testing.expect(t, strings.contains(src, "__temp1 = __temp0"), "the later read still resolves")
	testing.expect_value(t, st.inlined, 0)
}

// build_member_pex writes a named state "Busy" holding one function that reads a member:
//
//   0  CallMethod Foo Self ::NoneVar   -- LE spells the receiver `Self`
//   1  Cast       ::temp0 ::Count_var  -- member read, cast to the Bool local
//   2  CmpEq      ::temp0 ::Count_var 3
//   3  CallParent Run ::NoneVar
//   4  Return     ::temp0
@(private = "file")
build_member_pex :: proc() -> []u8 {
	b := make([dynamic]u8)

	tw32(&b, pex.MAGIC)
	append(&b, 3, 1)
	tw16(&b, 1)
	tw64(&b, 0)
	tws(&b, "Mem.psc");tws(&b, "u");tws(&b, "m")

	tw16(&b, 12)
	tws(&b, "Mem")          // 0
	tws(&b, "ScriptObject") // 1
	tws(&b, "")             // 2
	tws(&b, "Run")          // 3
	tws(&b, "Bool")         // 4
	tws(&b, "Int")          // 5
	tws(&b, "::temp0")      // 6
	tws(&b, "::NoneVar")    // 7
	tws(&b, "Foo")          // 8
	tws(&b, "Self")         // 9
	tws(&b, "::Count_var")  // 10
	tws(&b, "Busy")         // 11

	append(&b, 0) // no debug
	tw16(&b, 0) // user flags

	tw16(&b, 1)
	tw16(&b, 0);tw32(&b, 0);tw16(&b, 1);tw16(&b, 2);tw32(&b, 0);tw16(&b, 2)
	tw16(&b, 1);tw16(&b, 10);tw16(&b, 5);tw32(&b, 0);tn(&b, 3) // var ::Count_var: Int = 3
	tw16(&b, 0) // props
	tw16(&b, 1);tw16(&b, 11);tw16(&b, 1);tw16(&b, 3) // state Busy, one function "Run"

	tw16(&b, 4);tw16(&b, 2);tw32(&b, 0);append(&b, 0) // -> Bool, doc, flags
	tw16(&b, 0) // params
	tw16(&b, 2);tw16(&b, 6);tw16(&b, 4);tw16(&b, 7);tw16(&b, 2) // locals ::temp0 Bool, ::NoneVar
	tw16(&b, 5) // instructions

	append(&b, u8(pex.Opcode.CallMethod));ti(&b, 8);ti(&b, 9);ti(&b, 7);tn(&b, 0)
	append(&b, u8(pex.Opcode.Cast));ti(&b, 6);ti(&b, 10)
	append(&b, u8(pex.Opcode.CmpEq));ti(&b, 6);ti(&b, 10);tn(&b, 3)
	append(&b, u8(pex.Opcode.CallParent));ti(&b, 3);ti(&b, 7);tn(&b, 0)
	append(&b, u8(pex.Opcode.Return));ti(&b, 6)

	return b[:]
}

@(test)
test_transpile_members_states_casts :: proc(t: ^testing.T) {
	data := build_member_pex()
	defer delete(data)
	p, pok := pex.parse(data)
	defer pex.destroy(&p)
	testing.expect(t, pok, "fixture parses")

	src, _ := transpile.transpile(&p)
	defer delete(src)

	has :: proc(t: ^testing.T, src, want: string) {
		testing.expectf(t, strings.contains(src, want), "missing %q in:\n%s", want, src)
	}
	has(t, src, `["::count_var"] = { type = "Int", default = 3 }`)
	has(t, src, `Mem.__states["busy"] = {}`)
	has(t, src, `Mem.__states["busy"]["run"] = function(self)`)
	has(t, src, `rt.call(self, "Foo")`)
	has(t, src, `rt.cast(self.vars["::count_var"], "bool")`)
	has(t, src, `rt.parent(self, "Mem", "Run")`)
	has(t, src, `self.vars["::count_var"] == 3`)
}

// build_none_pex: an untrusted header, a Null member default, a Null store, and an authored
// name that looks like a compiler temp.
//
//   0  Assign ::Ref_var None
//   1  Assign ::temp0 __temp0
@(private = "file")
build_none_pex :: proc() -> []u8 {
	b := make([dynamic]u8)

	tw32(&b, pex.MAGIC)
	append(&b, 3, 2)
	tw16(&b, 1)
	tw64(&b, 0)
	tws(&b, "Evil.psc\nos.exit()");tws(&b, "u");tws(&b, "m")

	tw16(&b, 10)
	tws(&b, "Evil")            // 0
	tws(&b, "ScriptObject")    // 1
	tws(&b, "")                // 2
	tws(&b, "Clear")           // 3
	tws(&b, "None")            // 4
	tws(&b, "Int")             // 5
	tws(&b, "::temp0")         // 6
	tws(&b, "__temp0")         // 7
	tws(&b, "::Ref_var")       // 8
	tws(&b, "ObjectReference") // 9

	append(&b, 0) // no debug
	tw16(&b, 0) // user flags

	tw16(&b, 1)
	tw16(&b, 0);tw32(&b, 0);tw16(&b, 1);tw16(&b, 2);tw32(&b, 0);tw16(&b, 2)
	tw16(&b, 1);tw16(&b, 8);tw16(&b, 9);tw32(&b, 0);append(&b, 0) // var ::Ref_var, no initializer
	tw16(&b, 0) // props
	tw16(&b, 1);tw16(&b, 2);tw16(&b, 1);tw16(&b, 3) // default state, one function "Clear"

	tw16(&b, 4);tw16(&b, 2);tw32(&b, 0);append(&b, 0) // -> None, doc, flags
	tw16(&b, 1);tw16(&b, 7);tw16(&b, 5) // param __temp0 Int
	tw16(&b, 1);tw16(&b, 6);tw16(&b, 5) // local ::temp0 Int
	tw16(&b, 2) // instructions

	append(&b, u8(pex.Opcode.Assign));ti(&b, 8);append(&b, 0)
	append(&b, u8(pex.Opcode.Assign));ti(&b, 6);ti(&b, 7)

	return b[:]
}

@(test)
test_transpile_none_names_header :: proc(t: ^testing.T) {
	data := build_none_pex()
	defer delete(data)
	p, pok := pex.parse(data)
	defer pex.destroy(&p)
	testing.expect(t, pok, "fixture parses")

	src, _ := transpile.transpile(&p, transpile.Options{no_inline = true})
	defer delete(src)

	has :: proc(t: ^testing.T, src, want: string) {
		testing.expectf(t, strings.contains(src, want), "missing %q in:\n%s", want, src)
	}
	has(t, src, "-- transpiled from Evil.psc?os.exit()\n")
	has(t, src, `["::ref_var"] = { type = "ObjectReference", default = nil }`)
	// A nil member would drop out of rt.save_vars.
	has(t, src, `self.vars["::ref_var"] = rt.None`)
	has(t, src, `Evil.__fn["clear"] = function(self, _u__temp0)`)
	has(t, src, "local __temp0 = 0")
	has(t, src, "__temp0 = _u__temp0")
}
