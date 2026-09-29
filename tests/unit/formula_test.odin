package unit_tests

import "core:math"
import "core:testing"
import "../../src/formula"

@(private = "file")
run :: proc(src: string, vars: []string, values: []f64) -> (f64, string) {
	f, err := formula.compile(src, vars, context.temp_allocator)
	if err != "" {return 0, err}
	return formula.eval(f, values), ""
}

// Precedence, right-binding ^ above unary minus, variables and functions; errors name the problem.
@(test)
test_formula :: proc(t: ^testing.T) {
	cases := []struct {
		src:  string,
		want: f64,
	} {
		{"1 + 2 * 3", 7},
		{"(1 + 2) * 3", 9},
		{"2 ^ 3 ^ 2", 512},
		{"-2 ^ 2", -4},
		{"2 ^ -1", 0.5},
		{"10 - 4 - 3", 3},
		{"m * (1 - t / d)", 25},
		{"clamp(m * 3, 0, 100)", 100},
		{"min(t, d) + max(1, floor(2.7))", 7},
		{"select(t - 6, 1, 2) + select(d, 10, 20)", 12},
		{"320 + (m >= 50) * 880", 1200},
		{"t < 5 or t == 5 and d != 10", 0},
		{"1 + 1 == 2 and 3 > 2", 1},
		{"t <= 5 and -1", 1},
	}
	vars := []string{"t", "m", "d"}
	for c in cases {
		got, err := run(c.src, vars, {5, 50, 10})
		testing.expectf(t, err == "" && math.abs(got - c.want) < 1e-9, "%s = %v (%s), want %v", c.src, got, err, c.want)
	}
	lockpick, _ := run("mult * level ^ curve + offset", {"level", "mult", "offset", "curve"}, {15, 0.25, 300, 1.95})
	testing.expect(t, math.abs(lockpick - 349.1267420446517) < 1e-6, "UESP's Lockpicking 15 -> 16")

	for bad in ([]string{"x + 1", "1 +", "(1", "pow(1, 2)", "1 # 2", "min(1)", "a.b", "f(1)", "radius", "1 = 2", "\"x\""}) {
		_, err := run(bad, vars, {0, 0, 0})
		testing.expectf(t, err != "", "%q should not compile", bad)
	}
}

// varies follows only the taken branch of a select whose test is fixed; anything that reads t varies.
@(test)
test_formula_varies :: proc(t: ^testing.T) {
	vars := []string{"t", "held", "m"}
	cases := []struct {
		src:   string,
		held:  f64,
		moves: bool,
	} {
		{"m * 2", 1, false},
		{"m * t", 1, true},
		{"select(held, 0, m * t)", 1, false},
		{"select(held, 0, m * t)", 0, true},
		{"select(t, m, m)", 1, true}, // a test that moves: both branches count
		{"-(m) + min(t, 3)", 1, true},
	}
	for c in cases {
		f, err := formula.compile(c.src, vars, context.temp_allocator)
		testing.expectf(t, err == "" && formula.varies(f, 0, {0, c.held, 5}) == c.moves, "%s with held %v: varies should be %v", c.src, c.held, c.moves)
	}
}

// A bare name that is not a variable, a dotted name or an outside call is a read: the binder sees it once, the reader on each eval.
@(test)
test_formula_reads :: proc(t: ^testing.T) {
	bind :: proc(data: rawptr, r: ^formula.Read) -> string {
		if r.object == "nobody" {return "unknown subject"}
		r.bound[0] = u64(len(r.args))
		return ""
	}
	read :: proc(data: rawptr, r: formula.Read) -> f64 {
		if r.object == "caster" && r.name == "SuperFear" {return 1}
		if r.object == "" && !r.call && r.name == "radius" {return 1000}
		if r.name == "HasPerk" && r.args[0] == "caster" && r.args[1] == "Skyrim.esm:0153CF" {return f64(r.bound[0])}
		return 0
	}
	f, err := formula.compile(`320 + (caster.SuperFear >= 1) * 880 + HasPerk(caster, "Skyrim.esm:0153CF") + radius`, {"m"}, context.temp_allocator, {bind = bind})
	testing.expect_value(t, err, "")
	testing.expect_value(t, formula.eval(f, {0}, {read = read}), 2202)
	testing.expect_value(t, formula.eval(f, {0}), 320) // no reader: a read is 0
	testing.expect(t, formula.varies(f, 0, {0}), "a read may change")

	_, err = formula.compile("nobody.Health", {}, context.temp_allocator, {bind = bind})
	testing.expect_value(t, err, "unknown subject")
	_, err = formula.compile("f(1 + 2)", {}, context.temp_allocator, {bind = bind})
	testing.expect(t, err != "", "an outside call takes no expressions")
}
