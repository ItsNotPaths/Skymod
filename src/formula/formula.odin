package formula

// A formula is a string of arithmetic over named variables, compiled once and evaluated by the engine
// (progression math, zone levels, effects). Numbers, the formula's variables, + - * / ^ (^ binds
// right and above unary -), parentheses, and min, max, clamp, floor, ceil, round, abs, sqrt, and
// select(x, a, b): a when x > 0, else b.

import "core:math"
import "core:strconv"
import "core:strings"

Formula :: struct {
	src:  string, // owned
	code: []Instr, // owned; postfix
}

Instr :: struct {
	op:    Op,
	value: f64, // .Number
	index: int, // .Var: the variable; .Call: the function
}

Op :: enum u8 {
	Number,
	Var,
	Add,
	Sub,
	Mul,
	Div,
	Pow,
	Neg,
	Call,
}

Function :: struct {
	name:  string,
	arity: int,
}

FUNCTIONS := [?]Function{{"min", 2}, {"max", 2}, {"clamp", 3}, {"floor", 1}, {"ceil", 1}, {"round", 1}, {"abs", 1}, {"sqrt", 1}, {"select", 3}}

MAX_STACK :: 32

// compile turns `src` into a formula over `vars`. On failure `err` says why and nothing is allocated.
compile :: proc(src: string, vars: []string, allocator := context.allocator) -> (f: Formula, err: string) {
	p := Parser{src = src, vars = vars}
	p.code = make([dynamic]Instr, context.temp_allocator)
	next(&p)
	expr(&p, 0)
	if p.err == "" && p.tok.kind != .End {p.err = "unexpected text"}
	if p.err == "" && depth(p.code[:]) > MAX_STACK {p.err = "too deeply nested"}
	if p.err != "" {return {}, p.err}
	f.src = strings.clone(src, allocator)
	f.code = make([]Instr, len(p.code), allocator)
	copy(f.code, p.code[:])
	return f, ""
}

destroy :: proc(f: ^Formula, allocator := context.allocator) {
	delete(f.src, allocator)
	delete(f.code, allocator)
	f^ = {}
}

// eval runs a formula with `values` in the order of the variables it was compiled with.
eval :: proc(f: Formula, values: []f64) -> f64 {
	stack: [MAX_STACK]f64
	n := 0
	for ins in f.code {
		switch ins.op {
		case .Number: stack[n] = ins.value; n += 1
		case .Var:    stack[n] = values[ins.index]; n += 1
		case .Neg:    stack[n - 1] = -stack[n - 1]
		case .Add, .Sub, .Mul, .Div, .Pow:
			n -= 1
			stack[n - 1] = binary_op(ins.op, stack[n - 1], stack[n])
		case .Call:
			fn := FUNCTIONS[ins.index]
			r := call_fn(fn, stack[n - fn.arity:n])
			n -= fn.arity - 1
			stack[n - 1] = r
		}
	}
	return stack[0] if n == 1 else 0
}

// varies reports whether the formula's result can change with variable `v` while the others hold
// `values`. A select whose test does not change follows only the branch it takes, so
// `select(held, 0, t)` with held set does not vary. False means it cannot change.
varies :: proc(f: Formula, v: int, values: []f64) -> bool {
	Slot :: struct {
		value: f64,
		moves: bool,
	}
	stack: [MAX_STACK]Slot
	n := 0
	for ins in f.code {
		switch ins.op {
		case .Number: stack[n] = {ins.value, false}; n += 1
		case .Var:    stack[n] = {values[ins.index], ins.index == v}; n += 1
		case .Neg:    stack[n - 1].value = -stack[n - 1].value
		case .Add, .Sub, .Mul, .Div, .Pow:
			n -= 1
			a, b := stack[n - 1], stack[n]
			stack[n - 1] = {binary_op(ins.op, a.value, b.value), a.moves || b.moves}
		case .Call:
			fn := FUNCTIONS[ins.index]
			args := stack[n - fn.arity:n]
			r: Slot
			if fn.name == "select" && !args[0].moves {
				r = args[1] if args[0].value > 0 else args[2]
			} else {
				values: [3]f64
				for arg, i in args {
					values[i] = arg.value
					r.moves ||= arg.moves
				}
				r.value = call_fn(fn, values[:fn.arity])
			}
			n -= fn.arity - 1
			stack[n - 1] = r
		}
	}
	return n == 1 && stack[0].moves
}

@(private)
binary_op :: proc(op: Op, a, b: f64) -> f64 {
	#partial switch op {
	case .Add: return a + b
	case .Sub: return a - b
	case .Mul: return a * b
	case .Div: return a / b
	case .Pow: return math.pow(a, b)
	}
	return 0
}

@(private)
call_fn :: proc(fn: Function, args: []f64) -> f64 {
	switch fn.name {
	case "min":    return min(args[0], args[1])
	case "max":    return max(args[0], args[1])
	case "clamp":  return clamp(args[0], args[1], args[2])
	case "floor":  return math.floor(args[0])
	case "ceil":   return math.ceil(args[0])
	case "round":  return math.round(args[0])
	case "abs":    return abs(args[0])
	case "sqrt":   return math.sqrt(args[0])
	case "select": return args[1] if args[0] > 0 else args[2]
	}
	return 0
}

@(private)
depth :: proc(code: []Instr) -> int {
	n, top := 0, 0
	for ins in code {
		switch ins.op {
		case .Number, .Var:                n += 1
		case .Add, .Sub, .Mul, .Div, .Pow: n -= 1
		case .Neg:
		case .Call:                        n -= FUNCTIONS[ins.index].arity - 1
		}
		top = max(top, n)
	}
	return top
}

// ── parser: precedence climbing straight to postfix ──

@(private)
Token_Kind :: enum u8 {
	End,
	Number,
	Name,
	Op, // one of + - * / ^ ( ) ,
}

@(private)
Token :: struct {
	kind: Token_Kind,
	text: string,
}

@(private)
Parser :: struct {
	src:  string,
	pos:  int,
	tok:  Token,
	vars: []string,
	code: [dynamic]Instr,
	err:  string,
}

@(private)
next :: proc(p: ^Parser) {
	for p.pos < len(p.src) && (p.src[p.pos] == ' ' || p.src[p.pos] == '\t') {p.pos += 1}
	if p.pos >= len(p.src) {p.tok = {.End, ""}; return}
	start := p.pos
	c := p.src[p.pos]
	switch {
	case c >= '0' && c <= '9', c == '.':
		for p.pos < len(p.src) && (p.src[p.pos] >= '0' && p.src[p.pos] <= '9' || p.src[p.pos] == '.') {p.pos += 1}
		p.tok = {.Number, p.src[start:p.pos]}
	case c == '_', c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		for p.pos < len(p.src) && is_name_char(p.src[p.pos]) {p.pos += 1}
		p.tok = {.Name, p.src[start:p.pos]}
	case strings.index_byte("+-*/^(),", c) >= 0:
		p.pos += 1
		p.tok = {.Op, p.src[start:p.pos]}
	case:
		if p.err == "" {p.err = "unexpected character"}
		p.tok = {.End, ""}
	}
}

@(private)
is_name_char :: proc(c: u8) -> bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// binary operators: precedence, right-associative, op
@(private)
binary :: proc(t: Token) -> (prec: int, right: bool, op: Op, ok: bool) {
	if t.kind != .Op {return}
	switch t.text {
	case "+": return 1, false, .Add, true
	case "-": return 1, false, .Sub, true
	case "*": return 2, false, .Mul, true
	case "/": return 2, false, .Div, true
	case "^": return 4, true, .Pow, true
	}
	return
}

UNARY_PREC :: 3

@(private)
expr :: proc(p: ^Parser, min_prec: int) {
	unary(p)
	for p.err == "" {
		prec, right, op, ok := binary(p.tok)
		if !ok || prec < min_prec {return}
		next(p)
		expr(p, prec if right else prec + 1)
		append(&p.code, Instr{op = op})
	}
}

@(private)
unary :: proc(p: ^Parser) {
	if p.tok.kind == .Op && p.tok.text == "-" {
		next(p)
		expr(p, UNARY_PREC)
		append(&p.code, Instr{op = .Neg})
		return
	}
	primary(p)
}

@(private)
primary :: proc(p: ^Parser) {
	t := p.tok
	switch t.kind {
	case .Number:
		v, ok := strconv.parse_f64(t.text)
		if !ok {p.err = "bad number"; return}
		append(&p.code, Instr{op = .Number, value = v})
		next(p)
	case .Name:
		next(p)
		if p.tok.kind == .Op && p.tok.text == "(" {
			call(p, t.text)
			return
		}
		for v, i in p.vars {
			if v == t.text {append(&p.code, Instr{op = .Var, index = i}); return}
		}
		p.err = "unknown variable"
	case .Op:
		if t.text != "(" {p.err = "expected a value"; return}
		next(p)
		expr(p, 0)
		expect(p, ")")
	case .End:
		p.err = "expected a value"
	}
}

@(private)
call :: proc(p: ^Parser, name: string) {
	fi := -1
	for fn, i in FUNCTIONS {
		if fn.name == name {fi = i}
	}
	if fi < 0 {p.err = "unknown function"; return}
	next(p) // (
	for arg in 0 ..< FUNCTIONS[fi].arity {
		if arg > 0 {expect(p, ",")}
		expr(p, 0)
	}
	expect(p, ")")
	append(&p.code, Instr{op = .Call, index = fi})
}

@(private)
expect :: proc(p: ^Parser, text: string) {
	if p.err != "" {return}
	if p.tok.kind != .Op || p.tok.text != text {p.err = "expected a bracket or comma"; return}
	next(p)
}
