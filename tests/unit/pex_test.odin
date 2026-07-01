package unit_tests

// PEX (compiled Papyrus) reader tests (Phase 4 scripting). Hermetic + SYNTHETIC:
// a hand-built minimal big-endian PEX image (header → string table → 1 object →
// 1 state → 1 function with a callstatic + return), no game bytes. Regression
// guard on the structural decode + the call-histogram derivation — REAL
// correctness is proven by parsing the user's own ~13.5k .pex (tools/pexdump),
// where every script must decode with zero failures.

import "core:testing"
import "../../src/formats/pex"

// ── big-endian writers (PEX is big-endian on Skyrim LE) ──────────────────────

@(private = "file")
w16 :: proc(b: ^[dynamic]u8, v: u16) {append(b, u8(v >> 8), u8(v))}

@(private = "file")
w32 :: proc(b: ^[dynamic]u8, v: u32) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}

@(private = "file")
w64 :: proc(b: ^[dynamic]u8, v: u64) {
	append(b, u8(v >> 56), u8(v >> 48), u8(v >> 40), u8(v >> 32), u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

@(private = "file")
ws :: proc(b: ^[dynamic]u8, s: string) {
	w16(b, u16(len(s)))
	append(b, ..transmute([]u8)s)
}

@(private = "file")
v_ident :: proc(b: ^[dynamic]u8, idx: u16) {append(b, 1);w16(b, idx)}
@(private = "file")
v_str :: proc(b: ^[dynamic]u8, idx: u16) {append(b, 2);w16(b, idx)}
@(private = "file")
v_int :: proc(b: ^[dynamic]u8, v: i32) {append(b, 3);w32(b, u32(v))}
@(private = "file")
v_bool :: proc(b: ^[dynamic]u8, x: bool) {append(b, 5);append(b, x ? 1 : 0)}

// String-table layout used by the fixture.
S_OBJ :: 0 // "Test"
S_PARENT :: 1 // "ScriptObject"
S_EMPTY :: 2 // "" (doc/autostate/default-state)
S_FUNC :: 3 // "MyFunc"
S_BOOL :: 4 // "Bool"
S_INT :: 5 // "Int"
S_PARAM :: 6 // "param1"
S_GAME :: 7 // "Game"
S_GETPLAYER :: 8 // "GetPlayer"
S_TEMP :: 9 // "::temp0"

build_pex :: proc() -> []u8 {
	b := make([dynamic]u8)

	w32(&b, pex.MAGIC)
	append(&b, 3, 1) // major, minor
	w16(&b, 1) // game id (Skyrim)
	w64(&b, 0x1122_3344) // compile time
	ws(&b, "Test.psc")
	ws(&b, "user")
	ws(&b, "machine")

	// string table
	w16(&b, 10)
	ws(&b, "Test")
	ws(&b, "ScriptObject")
	ws(&b, "")
	ws(&b, "MyFunc")
	ws(&b, "Bool")
	ws(&b, "Int")
	ws(&b, "param1")
	ws(&b, "Game")
	ws(&b, "GetPlayer")
	ws(&b, "::temp0")

	append(&b, 0) // has_debug = false
	w16(&b, 0) // user-flag count

	// objects
	w16(&b, 1)
	w16(&b, S_OBJ) // name
	w32(&b, 0) // size (parser ignores; we walk sequentially)
	w16(&b, S_PARENT) // parent
	w16(&b, S_EMPTY) // doc
	w32(&b, 0) // user flags
	w16(&b, S_EMPTY) // auto state
	w16(&b, 0) // variables
	w16(&b, 0) // properties
	w16(&b, 1) // states
	// state[0]
	w16(&b, S_EMPTY) // state name (default)
	w16(&b, 1) // function count
	w16(&b, S_FUNC) // named-function name prefix
	// function body
	w16(&b, S_BOOL) // return type
	w16(&b, S_EMPTY) // doc
	w32(&b, 0) // user flags
	append(&b, 0) // flags (not global, not native)
	w16(&b, 1) // params
	w16(&b, S_PARAM);w16(&b, S_INT)
	w16(&b, 1) // locals
	w16(&b, S_TEMP);w16(&b, S_BOOL)
	w16(&b, 2) // instructions
	// instr 0: callstatic Game GetPlayer ::temp0 (0 args)
	append(&b, u8(pex.Opcode.CallStatic))
	v_ident(&b, S_GAME)
	v_str(&b, S_GETPLAYER)
	v_ident(&b, S_TEMP)
	v_int(&b, 0) // var-arg count
	// instr 1: return true
	append(&b, u8(pex.Opcode.Return))
	v_bool(&b, true)

	return b[:]
}

@(test)
test_pex_parse :: proc(t: ^testing.T) {
	data := build_pex()
	defer delete(data)

	p, ok := pex.parse(data)
	defer pex.destroy(&p)
	testing.expect(t, ok, "parse minimal PEX")
	testing.expect_value(t, p.major, u8(3))
	testing.expect_value(t, p.minor, u8(1))
	testing.expect_value(t, p.game_id, u16(1))
	testing.expect_value(t, p.source_file, "Test.psc")
	testing.expect_value(t, p.has_debug, false)
	testing.expect_value(t, len(p.string_table), 10)
	testing.expect_value(t, len(p.objects), 1)

	o := p.objects[0]
	testing.expect_value(t, o.name, "Test")
	testing.expect_value(t, o.parent, "ScriptObject")
	testing.expect_value(t, len(o.states), 1)
	testing.expect_value(t, len(o.states[0].functions), 1)

	f := o.states[0].functions[0]
	testing.expect_value(t, f.name, "MyFunc")
	testing.expect_value(t, f.return_type, "Bool")
	testing.expect_value(t, f.is_native, false)
	testing.expect_value(t, len(f.params), 1)
	testing.expect_value(t, f.params[0].name, "param1")
	testing.expect_value(t, f.params[0].type_name, "Int")
	testing.expect_value(t, len(f.instructions), 2)

	i0 := f.instructions[0]
	testing.expect_value(t, i0.op, pex.Opcode.CallStatic)
	testing.expect_value(t, len(i0.args), 3) // 3 fixed, 0 var-args
	testing.expect_value(t, i0.args[0].str, "Game")
	testing.expect_value(t, i0.args[1].str, "GetPlayer")

	i1 := f.instructions[1]
	testing.expect_value(t, i1.op, pex.Opcode.Return)
	testing.expect_value(t, i1.args[0].kind, pex.Value_Kind.Bool)
	testing.expect_value(t, i1.args[0].b, true)
}

@(test)
test_pex_call_histogram :: proc(t: ^testing.T) {
	data := build_pex()
	defer delete(data)
	p, ok := pex.parse(data)
	defer pex.destroy(&p)
	testing.expect(t, ok, "parse for histogram")

	counts := make(map[string]int)
	defer {
		for k in counts {delete(k)}
		delete(counts)
	}
	pex.tally_calls(&p, &counts)

	// case-folded "Game.GetPlayer" -> "game.getplayer", counted once.
	testing.expect_value(t, counts["game.getplayer"], 1)
}

@(test)
test_pex_rejects_bad_magic :: proc(t: ^testing.T) {
	bad := []u8{0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0}
	p, ok := pex.parse(bad)
	defer pex.destroy(&p)
	testing.expect(t, !ok, "reject non-PEX magic")
}
