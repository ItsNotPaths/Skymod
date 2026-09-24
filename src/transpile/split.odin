package transpile

// S6, the splitter (docs/short-term-plan.md). A listed function's waits (Utility.Wait,
// WaitMenuMode, WaitGameTime) become a timer field. The function stores the locals it still needs,
// sets the timer and returns; the class's OnTick holds a guard on that timer and the code after
// the wait. Two or more waits add a stage, saying which wait's code comes next.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../formats/pex"

@(private)
Split :: struct {
	f:       ^pex.Function,
	state:   string,
	key:     string,       // "fn" or "state.fn", lowercase: prefixes the function's fields
	n:       int,          // names its Lua locals: __tick<n>, __seq<n>
	sites:   [dynamic]int, // the waits, in order
	carried: [dynamic]pex.Var,
	before:  []bool,       // per instruction, whether the entry reaches it before a wait
	reached: []bool,       // per instruction, whether some path after a wait reaches it
	from:    int,          // the first of those
	hash:    u32,
	game:    bool,         // the waits are WaitGameTime: the timer counts game hours
	in_tick: bool,         // writing the tick: a wait carries the last one's overshoot
}

@(private)
split_key :: proc(script, state, fn: string, allocator := context.temp_allocator) -> string {
	return strings.to_lower(fmt.tprintf("%s\t%s\t%s", script, state, fn), allocator)
}

// plan_splits finds this object's bodies to split: listed, the same code as when they were
// listed, and holding waits of one clock kind.
@(private)
plan_splits :: proc(e: ^Emitter, o: ^pex.Object) -> [dynamic]Split {
	out := make([dynamic]Split, context.temp_allocator)
	for &st in o.states {
		for &f in st.functions {
			want, listed := e.opt.split[split_key(o.name, st.name, f.name)]
			if !listed || f.is_native {continue}
			s := Split{f = &f, state = st.name, hash = pex.function_hash(&f), n = len(out) + 1}
			if !slice.contains(want[:], s.hash) {continue}
			s.key = strings.to_lower(st.name == "" ? f.name : fmt.tprintf("%s.%s", st.name, f.name), context.temp_allocator)
			s.sites = make([dynamic]int, context.temp_allocator)
			real := false
			for ins, i in f.instructions {
				if !is_wait(ins) {continue}
				append(&s.sites, i)
				if strings.equal_fold(ident_of(arg(ins, 1)), "waitgametime") {s.game = true} else {real = true}
			}
			if len(s.sites) == 0 || (s.game && real) {continue}
			s.carried = make([dynamic]pex.Var, context.temp_allocator)
			for vars in ([][]pex.Var{f.params, f.locals}) {
				for v in vars {
					if strings.equal_fold(v.name, NONE_VAR) {continue}
					for site in s.sites {
						if live_after(f, site, v.name) {
							append(&s.carried, v)
							break
						}
					}
				}
			}
			s.before = before_waits(f, s.sites[:])
			s.reached, s.from = after_waits(f, s.sites[:])
			append(&out, s)
		}
	}
	return out
}

@(private)
find_split :: proc(splits: []Split, state: string, f: ^pex.Function) -> ^Split {
	for &s in splits {
		if s.f == f && s.state == state {return &s}
	}
	return nil
}

@(private)
is_wait :: proc(ins: pex.Instruction) -> bool {
	if ins.op != .CallStatic || !strings.equal_fold(ident_of(arg(ins, 0)), "utility") {return false}
	name := ident_of(arg(ins, 1))
	return strings.equal_fold(name, "wait") || strings.equal_fold(name, "waitmenumode") || strings.equal_fold(name, "waitgametime")
}

@(private)
successors :: proc(stack: ^[dynamic]int, f: pex.Function, i: int) {
	ins := f.instructions[i]
	if ins.op == .Return {return}
	if ins.op != .Jmp {append(stack, i + 1)}
	if t, ok := jump_target(i, ins); ok {append(stack, t)}
}

// live_after reports whether some path from `at` reads `name` before writing it. Back edges
// count: a loop carries its variables round.
@(private)
live_after :: proc(f: pex.Function, at: int, name: string) -> bool {
	n := len(f.instructions)
	seen := make([]bool, n, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	successors(&stack, f, at)
	for len(stack) > 0 {
		i := pop(&stack)
		if i >= n || seen[i] {continue}
		seen[i] = true
		ins := f.instructions[i]
		if reads_name(ins, name) > 0 {return true}
		if writes_name(ins, name) {continue}
		successors(&stack, f, i)
	}
	return false
}

// before_waits marks the instructions the entry reaches without passing a wait: the handler.
@(private)
before_waits :: proc(f: pex.Function, sites: []int) -> []bool {
	n := len(f.instructions)
	seen := make([]bool, n, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, 0)
	for len(stack) > 0 {
		i := pop(&stack)
		if i >= n || seen[i] {continue}
		seen[i] = true
		if !is_wait(f.instructions[i]) {successors(&stack, f, i)}
	}
	return seen
}

// after_waits marks the instructions some path after a wait reaches, and the lowest of them: a
// poll loop's head, or the line after the first wait.
@(private)
after_waits :: proc(f: pex.Function, sites: []int) -> (seen: []bool, lo: int) {
	n := len(f.instructions)
	seen = make([]bool, n, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	lo = n
	for site in sites {append(&stack, site + 1)}
	for len(stack) > 0 {
		i := pop(&stack)
		if i >= n || seen[i] {continue}
		seen[i] = true
		lo = min(lo, i)
		successors(&stack, f, i)
	}
	return
}

// emit_split_fields declares each split function's timer, stage and carried locals.
@(private)
emit_split_fields :: proc(e: ^Emitter, o: ^pex.Object, splits: []Split) {
	for &s in splits {
		write_field(e, o.name, &s, "t")
		sbprintf(e, " = rt.%s(rt.None)\n", s.game ? "gametimer" : "timer")
		if len(s.sites) > 1 {
			sbprintf(e, "local __seq%d = rt.sequence(", s.n)
			for _, k in s.sites {
				if k > 0 {sbprint(e, ", ")}
				sbprint(e, "\"")
				write_stage_name(e, &s, k)
				sbprint(e, "\"")
			}
			sbprint(e, ")\n")
			write_field(e, o.name, &s, "at")
			sbprintf(e, " = __seq%d.", s.n)
			write_stage_name(e, &s, 0)
			sbprint(e, "\n")
		}
		for v in s.carried {
			write_field(e, o.name, &s, v.name)
			sbprint(e, " = { type = ")
			write_lua_string(e, v.type_name)
			sbprint(e, " }\n")
		}
	}
}

// emit_split_ticks writes each split function's tick: the guard on its timer, then its code from
// the first wait on, entered after the wait that ran last. OnTick calls them all.
@(private)
emit_split_ticks :: proc(e: ^Emitter, o: ^pex.Object, splits: []Split) {
	for &s in splits {
		sbprintf(e, "local function __tick%d(self)\n\tif ", s.n)
		write_var(e, &s, "t")
		sbprint(e, " == rt.None or ")
		write_var(e, &s, "t")
		sbprint(e, " > 0 then return end\n")
		// The timer ran out this far back; the next wait counts from then, so a chain keeps time.
		sbprint(e, "\tlocal __late = ")
		write_var(e, &s, "t")
		sbprint(e, "\n\t")
		write_var(e, &s, "t")
		sbprint(e, " = rt.None\n")
		if len(s.f.params) > 0 {
			sbprint(e, "\tlocal ")
			for pm, i in s.f.params {
				if i > 0 {sbprint(e, ", ")}
				write_mangled(e, pm.name)
			}
			sbprint(e, "\n")
		}
		write_locals(e, s.f)
		if len(s.carried) > 0 {
			sbprint(e, "\t")
			for v, i in s.carried {
				if i > 0 {sbprint(e, ", ")}
				write_mangled(e, v.name)
			}
			sbprint(e, " = ")
			for v, i in s.carried {
				if i > 0 {sbprint(e, ", ")}
				write_var(e, &s, v.name)
			}
			sbprint(e, "\n")
		}
		for site, k in s.sites[1:] {
			sbprint(e, "\tif ")
			write_var(e, &s, "at")
			sbprintf(e, " == __seq%d.", s.n)
			write_stage_name(e, &s, k + 1)
			sbprintf(e, " then goto L%d end\n", site + 1)
		}
		sbprintf(e, "\tgoto L%d\n", s.sites[0] + 1)
		e.split, s.in_tick = &s, true
		emit_body(e, s.f, s.from, s.reached)
		e.split, s.in_tick = nil, false
		sbprint(e, "end\n")
	}

	write_mangled(e, o.name)
	sbprint(e, ".__fn[\"ontick\"] = function(self)\n")
	for s in splits {sbprintf(e, "\t__tick%d(self)\n", s.n)}
	// A subclass's OnTick hides its parent's, so it runs the parent's split functions too.
	if o.parent != "" && parent_splits(e, o.parent) {
		sbprint(e, "\trt.parent(self, ")
		write_lua_string(e, o.name)
		sbprint(e, ", \"OnTick\")\n")
	}
	sbprint(e, "end\n")
}

@(private)
parent_splits :: proc(e: ^Emitter, parent: string) -> bool {
	prefix := strings.to_lower(fmt.tprintf("%s\t", parent), context.temp_allocator)
	for k in e.opt.split {
		if strings.has_prefix(k, prefix) {return true}
	}
	return false
}

// emit_wait replaces a wait: store the carried locals, name the next stage, set the timer, return.
@(private)
emit_wait :: proc(e: ^Emitter, idx: int, ins: pex.Instruction) {
	s := e.split
	k := 0
	for site, i in s.sites {
		if site == idx {k = i}
	}
	for v in s.carried {
		sbprint(e, "\t")
		write_var(e, s, v.name)
		sbprint(e, " = ")
		write_mangled(e, v.name)
		sbprint(e, "\n")
	}
	if len(s.sites) > 1 {
		sbprint(e, "\t")
		write_var(e, s, "at")
		sbprintf(e, " = __seq%d.", s.n)
		write_stage_name(e, s, k)
		sbprint(e, "\n")
	}
	sbprint(e, "\t")
	write_var(e, s, "t")
	sbprint(e, " = ")
	write_read(e, arg(ins, 3), idx)
	if s.in_tick {sbprint(e, " + __late")}
	sbprint(e, "\n\tdo return end\n")
}

// emit_split_drop is the handler's first line: a call while the function waits is dropped.
@(private)
emit_split_drop :: proc(e: ^Emitter, s: ^Split) {
	sbprint(e, "\tif ")
	write_var(e, s, "t")
	sbprint(e, " ~= rt.None then return end -- a call while it waits is dropped\n")
}

@(private)
write_var :: proc(e: ^Emitter, s: ^Split, name: string) {
	sbprint(e, "self.vars[")
	write_key(e, fmt.tprintf("%s.%s", s.key, name))
	sbprint(e, "]")
}

@(private)
write_field :: proc(e: ^Emitter, obj: string, s: ^Split, name: string) {
	write_mangled(e, obj)
	sbprint(e, ".__vars[")
	write_key(e, fmt.tprintf("%s.%s", s.key, name))
	sbprint(e, "]")
}

// A stage is named by its wait's position and the body's hash, so a saved stage from other code
// matches none and falls back to the first.
@(private)
write_stage_name :: proc(e: ^Emitter, s: ^Split, k: int) {
	sbprintf(e, "W%d_%04x", k + 1, s.hash & 0xffff)
}

// parse_split_list reads `pexlatent --emit-split` output into Options.split. '#' lines are
// comments; a malformed row is skipped.
parse_split_list :: proc(text: string, allocator := context.allocator) -> map[string][dynamic]u32 {
	out := make(map[string][dynamic]u32, allocator = allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "" || line[0] == '#' {continue}
		cols := strings.split(line, "\t", context.temp_allocator)
		if len(cols) != 4 {continue}
		h, ok := strconv.parse_u64_of_base(cols[3], 16)
		if !ok {continue}
		key := split_key(cols[0], cols[1], cols[2], allocator)
		if hashes, had := &out[key]; had {
			delete(key, allocator)
			append(hashes, u32(h))
		} else {
			out[key] = make([dynamic]u32, 0, 1, allocator)
			append(&out[key], u32(h))
		}
	}
	return out
}
