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
	}
	vars := []string{"t", "m", "d"}
	for c in cases {
		got, err := run(c.src, vars, {5, 50, 10})
		testing.expectf(t, err == "" && math.abs(got - c.want) < 1e-9, "%s = %v (%s), want %v", c.src, got, err, c.want)
	}
	lockpick, _ := run("mult * level ^ curve + offset", {"level", "mult", "offset", "curve"}, {15, 0.25, 300, 1.95})
	testing.expect(t, math.abs(lockpick - 349.1267420446517) < 1e-6, "UESP's Lockpicking 15 -> 16")

	for bad in ([]string{"x + 1", "1 +", "(1", "pow(1, 2)", "1 # 2", "min(1)"}) {
		_, err := run(bad, vars, {0, 0, 0})
		testing.expectf(t, err != "", "%q should not compile", bad)
	}
}
