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
			a, b := stack[n - 2], stack[n - 1]
			n -= 1
			#partial switch ins.op {
			case .Add: stack[n - 1] = a + b
			case .Sub: stack[n - 1] = a - b
			case .Mul: stack[n - 1] = a * b
			case .Div: stack[n - 1] = a / b
			case .Pow: stack[n - 1] = math.pow(a, b)
			}
		case .Call:
			fn := FUNCTIONS[ins.index]
			args := stack[n - fn.arity:n]
			r: f64
			switch fn.name {
			case "min":   r = min(args[0], args[1])
			case "max":   r = max(args[0], args[1])
			case "clamp": r = clamp(args[0], args[1], args[2])
			case "floor": r = math.floor(args[0])
			case "ceil":  r = math.ceil(args[0])
			case "round": r = math.round(args[0])
			case "abs":   r = abs(args[0])
			case "sqrt":  r = math.sqrt(args[0])
			case "select": r = args[1] if args[0] > 0 else args[2]
			}
			n -= fn.arity - 1
			stack[n - 1] = r
		}
	}
	return stack[0] if n == 1 else 0
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
