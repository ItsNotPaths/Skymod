package script

// Math.* — the pure, stateless callstatic natives (Wave 2 in docs/scripting-natives.md).
// No worldstate, no gamedb: each is a one-liner over core:math on the single float arg
// (Papyrus Math takes/returns float, except Ceiling/Floor which return int). These are the
// leaf primitives every transpiled utility script bottoms out on, so they're free to do now.

import "core:math"
import "core:math/rand"

register_math :: proc(reg: ^Registry) {
	register(reg, "Math", "abs", n_math_abs)
	register(reg, "Math", "acos", n_math_acos)
	register(reg, "Math", "asin", n_math_asin)
	register(reg, "Math", "atan", n_math_atan)
	register(reg, "Math", "Ceiling", n_math_ceiling)
	register(reg, "Math", "cos", n_math_cos)
	register(reg, "Math", "DegreesToRadians", n_math_deg2rad)
	register(reg, "Math", "Floor", n_math_floor)
	register(reg, "Math", "pow", n_math_pow)
	register(reg, "Math", "RadiansToDegrees", n_math_rad2deg)
	register(reg, "Math", "sin", n_math_sin)
	register(reg, "Math", "sqrt", n_math_sqrt)
	register(reg, "Math", "tan", n_math_tan)
	register(reg, "Utility", "RandomInt", n_random_int)
	register(reg, "Utility", "RandomFloat", n_random_float)
}

// Utility.RandomInt(aiMin = 0, aiMax = 100) and RandomFloat(afMin = 0.0, afMax = 1.0): both ends
// inclusive, and a reversed range swaps.
n_random_int :: proc(c: ^Call, args: []Value) -> Value {
	lo, hi := arg_i32(args, 0, 0), arg_i32(args, 1, 100)
	if lo > hi {lo, hi = hi, lo}
	return lo + i32(rand.int63_max(i64(hi) - i64(lo) + 1))
}

n_random_float :: proc(c: ^Call, args: []Value) -> Value {
	lo, hi := arg_f32(args, 0, 0), arg_f32(args, 1, 1)
	if lo > hi {lo, hi = hi, lo}
	return lo + rand.float32() * (hi - lo)
}

// Papyrus trig is in DEGREES (sin(90)=1) — the CK/game convention — so sin/cos/tan convert
// the arg to radians and the inverse trig converts the result back to degrees. Ceiling/Floor
// return int; the rest return float.

n_math_abs :: proc(c: ^Call, args: []Value) -> Value {
	return math.abs(arg_f32(args, 0, 0))
}

n_math_acos :: proc(c: ^Call, args: []Value) -> Value {
	return math.to_degrees(math.acos(arg_f32(args, 0, 0)))
}

n_math_asin :: proc(c: ^Call, args: []Value) -> Value {
	return math.to_degrees(math.asin(arg_f32(args, 0, 0)))
}

n_math_atan :: proc(c: ^Call, args: []Value) -> Value {
	return math.to_degrees(math.atan(arg_f32(args, 0, 0)))
}

n_math_ceiling :: proc(c: ^Call, args: []Value) -> Value {
	return i32(math.ceil(arg_f32(args, 0, 0)))
}

n_math_cos :: proc(c: ^Call, args: []Value) -> Value {
	return math.cos(math.to_radians(arg_f32(args, 0, 0)))
}

n_math_deg2rad :: proc(c: ^Call, args: []Value) -> Value {
	return math.to_radians(arg_f32(args, 0, 0))
}

n_math_floor :: proc(c: ^Call, args: []Value) -> Value {
	return i32(math.floor(arg_f32(args, 0, 0)))
}

n_math_pow :: proc(c: ^Call, args: []Value) -> Value {
	return math.pow(arg_f32(args, 0, 0), arg_f32(args, 1, 0))
}

n_math_rad2deg :: proc(c: ^Call, args: []Value) -> Value {
	return math.to_degrees(arg_f32(args, 0, 0))
}

n_math_sin :: proc(c: ^Call, args: []Value) -> Value {
	return math.sin(math.to_radians(arg_f32(args, 0, 0)))
}

n_math_sqrt :: proc(c: ^Call, args: []Value) -> Value {
	return math.sqrt(arg_f32(args, 0, 0))
}

n_math_tan :: proc(c: ^Call, args: []Value) -> Value {
	return math.tan(math.to_radians(arg_f32(args, 0, 0)))
}
