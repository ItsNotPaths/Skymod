package formula

// A formula is a string of arithmetic over named variables, compiled once and evaluated by the engine
// (progression math, zone levels, effects). Numbers, the formula's variables, + - * / ^ (^ binds
// right and above unary -), comparisons < <= > >= == != and `and`, `or` (1 or 0), parentheses, and
// min, max, clamp, floor, ceil, round, abs, sqrt, and select(x, a, b): a when x > 0, else b.
// With a Binder, a name that is not a variable (radius), a dotted name (caster.Health) or a call to
// an unknown function (HasPerk(caster, X)) is a Read: the binder checks it once, and the Reader
// answers it on each eval.

import "core:math"
import "core:strconv"
import "core:strings"

Formula :: struct {
	src:   string, // owned
	code:  []Instr, // owned; postfix
	reads: []Read, // owned
}

Instr :: struct {
	op:    Op,
	value: f64, // .Number
	index: int, // .Var: the variable; .Call: the function; .Read: the read
}

// Read is a value the formula asks its caller for.
Read :: struct {
	object: string, // before the dot: `caster` in caster.Health; "" for a bare name or a call
	name:   string,
	call:   bool,
	args:   []string, // a call's arguments as written; a quoted one without its quotes
	bound:  [4]u64, // the binder's own data
}

// Binder checks a read when the formula compiles; an error fails the compile.
Binder :: struct {
	data: rawptr,
	bind: proc(data: rawptr, r: ^Read) -> (err: string),
}

// Reader answers a read when the formula runs.
Reader :: struct {
	data: rawptr,
	read: proc(data: rawptr, r: Read) -> f64,
}

Op :: enum u8 {
	Number,
	Var,
	Add,
	Sub,
	Mul,
	Div,
	Pow,
	Lt,
	Le,
	Gt,
	Ge,
	Eq,
	Ne,
	And,
	Or,
	Neg,
	Call,
	Read,
}

Function :: struct {
	name:  string,
	arity: int,
}

FUNCTIONS := [?]Function{{"min", 2}, {"max", 2}, {"clamp", 3}, {"floor", 1}, {"ceil", 1}, {"round", 1}, {"abs", 1}, {"sqrt", 1}, {"select", 3}}

MAX_STACK :: 32

// compile turns `src` into a formula over `vars`. On failure `err` says why and nothing is allocated.
// Without a binder, a read is an error.
compile :: proc(src: string, vars: []string, allocator := context.allocator, binder := Binder{}) -> (f: Formula, err: string) {
	p := Parser{src = src, vars = vars, binder = binder}
	p.code = make([dynamic]Instr, context.temp_allocator)
	p.reads = make([dynamic]Read, context.temp_allocator)
	next(&p)
	expr(&p, 0)
	if p.err == "" && p.tok.kind != .End {p.err = "unexpected text"}
	if p.err == "" && depth(p.code[:]) > MAX_STACK {p.err = "too deeply nested"}
	if p.err != "" {return {}, p.err}
	f.src = strings.clone(src, allocator)
	f.code = make([]Instr, len(p.code), allocator)
	copy(f.code, p.code[:])
	f.reads = make([]Read, len(p.reads), allocator)
	for r, i in p.reads {
		f.reads[i] = {object = strings.clone(r.object, allocator), name = strings.clone(r.name, allocator), call = r.call, args = make([]string, len(r.args), allocator), bound = r.bound}
		for a, j in r.args {f.reads[i].args[j] = strings.clone(a, allocator)}
	}
	return f, ""
}

destroy :: proc(f: ^Formula, allocator := context.allocator) {
	delete(f.src, allocator)
	delete(f.code, allocator)
	for r in f.reads {
		delete(r.object, allocator)
		delete(r.name, allocator)
		for a in r.args {delete(a, allocator)}
		delete(r.args, allocator)
	}
	delete(f.reads, allocator)
	f^ = {}
}

// eval runs a formula with `values` in the order of the variables it was compiled with.
eval :: proc(f: Formula, values: []f64, reader := Reader{}) -> f64 {
	stack: [MAX_STACK]f64
	n := 0
	for ins in f.code {
		switch ins.op {
		case .Number: stack[n] = ins.value; n += 1
		case .Var:    stack[n] = values[ins.index]; n += 1
		case .Read:   stack[n] = reader.read(reader.data, f.reads[ins.index]) if reader.read != nil else 0; n += 1
		case .Neg:    stack[n - 1] = -stack[n - 1]
		case .Add, .Sub, .Mul, .Div, .Pow, .Lt, .Le, .Gt, .Ge, .Eq, .Ne, .And, .Or:
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
// `select(held, 0, t)` with held set does not vary. A read may change at any time. False means it
// cannot change.
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
		case .Read:   stack[n] = {0, true}; n += 1
		case .Neg:    stack[n - 1].value = -stack[n - 1].value
		case .Add, .Sub, .Mul, .Div, .Pow, .Lt, .Le, .Gt, .Ge, .Eq, .Ne, .And, .Or:
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
	case .Lt:  return f64(int(a < b))
	case .Le:  return f64(int(a <= b))
	case .Gt:  return f64(int(a > b))
	case .Ge:  return f64(int(a >= b))
	case .Eq:  return f64(int(a == b))
	case .Ne:  return f64(int(a != b))
	case .And: return f64(int(a != 0 && b != 0))
	case .Or:  return f64(int(a != 0 || b != 0))
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
		case .Number, .Var, .Read: n += 1
		case .Add, .Sub, .Mul, .Div, .Pow, .Lt, .Le, .Gt, .Ge, .Eq, .Ne, .And, .Or: n -= 1
		case .Neg:
		case .Call:                n -= FUNCTIONS[ins.index].arity - 1
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
	Name, // may be dotted: caster.Health
	String, // text is without the quotes
	Op, // one of + - * / ^ ( ) , < <= > >= == !=
}

@(private)
Token :: struct {
	kind: Token_Kind,
	text: string,
}

@(private)
Parser :: struct {
	src:    string,
	pos:    int,
	tok:    Token,
	vars:   []string,
	binder: Binder,
	code:   [dynamic]Instr,
	reads:  [dynamic]Read,
	err:    string,
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
		for p.pos < len(p.src) && (is_name_char(p.src[p.pos]) || p.src[p.pos] == '.' && p.pos + 1 < len(p.src) && is_name_char(p.src[p.pos + 1])) {p.pos += 1}
		p.tok = {.Name, p.src[start:p.pos]}
	case c == '"':
		end := strings.index_byte(p.src[start + 1:], '"')
		if end < 0 {
			if p.err == "" {p.err = "unclosed quote"}
			p.tok = {.End, ""}
			return
		}
		p.pos = start + end + 2
		p.tok = {.String, p.src[start + 1:p.pos - 1]}
	case strings.index_byte("<>=!", c) >= 0 && p.pos + 1 < len(p.src) && p.src[p.pos + 1] == '=':
		p.pos += 2
		p.tok = {.Op, p.src[start:p.pos]}
	case strings.index_byte("+-*/^(),<>", c) >= 0:
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
	if t.kind == .Name {
		switch t.text {
		case "or":  return 1, false, .Or, true
		case "and": return 2, false, .And, true
		}
	}
	if t.kind != .Op {return}
	switch t.text {
	case "<":  return 3, false, .Lt, true
	case "<=": return 3, false, .Le, true
	case ">":  return 3, false, .Gt, true
	case ">=": return 3, false, .Ge, true
	case "==": return 3, false, .Eq, true
	case "!=": return 3, false, .Ne, true
	case "+":  return 4, false, .Add, true
	case "-":  return 4, false, .Sub, true
	case "*":  return 5, false, .Mul, true
	case "/":  return 5, false, .Div, true
	case "^":  return 7, true, .Pow, true
	}
	return
}

UNARY_PREC :: 6

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
		if p.binder.bind == nil {p.err = "unknown variable"; return}
		object, _, name := strings.partition(t.text, ".")
		if name == "" {object, name = "", object}
		read(p, Read{object = object, name = name})
	case .String:
		p.err = "a quoted name goes only in a call"
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
	if fi < 0 {
		outside_call(p, name)
		return
	}
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

// outside_call parses a call to a function the binder knows. Its arguments are single names,
// numbers or quoted strings, not expressions.
@(private)
outside_call :: proc(p: ^Parser, name: string) {
	if p.binder.bind == nil {p.err = "unknown function"; return}
	args := make([dynamic]string, context.temp_allocator)
	next(p) // (
	for p.err == "" && !(p.tok.kind == .Op && p.tok.text == ")") {
		if len(args) > 0 {expect(p, ",")}
		if p.tok.kind == .Op || p.tok.kind == .End {p.err = "expected a name, number or quoted string"; return}
		append(&args, p.tok.text)
		next(p)
	}
	expect(p, ")")
	read(p, Read{name = name, call = true, args = args[:]})
}

@(private)
read :: proc(p: ^Parser, r: Read) {
	if p.err != "" {return}
	r := r
	if err := p.binder.bind(p.binder.data, &r); err != "" {p.err = err; return}
	append(&p.code, Instr{op = .Read, index = len(p.reads)})
	append(&p.reads, r)
}
