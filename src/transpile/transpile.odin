package transpile

// PEX → Lua. The detachable half of the install-time script converter.
//
// DETACHABLE BY RULE: this package imports core:* and formats/pex, nothing else. It does no
// file IO, holds no globals, and never imports the script registry — emitted code targets the
// `rt` contract written down in docs/papyrus-transpiler.md, not any Odin symbol.
//
// Tiers built here: T0 (one instruction, one statement; jumps become Lua `goto`) and T1 (the
// local cleanups that need no control-flow analysis). T2 (temp inlining) and T3 (if/while
// recovery) are not built — see the doc for the measurements that rank them.

import "core:strings"
import "../formats/pex"

DEFAULT_RUNTIME :: "skymod.rt"

Options :: struct {
	runtime:       string, // module the chunk requires; "" means DEFAULT_RUNTIME
	line_comments: bool,   // annotate each statement with its source line
	// no_inline stops at T1: one statement per instruction, temps left standing. A debugging
	// aid — diff it against the inlined form when T2 is the suspect.
	no_inline:     bool,
	// split lists the bodies the splitter converts (split.odin): "script\tstate\tfunction",
	// lowercase, to the code hash the list was made from (`pexlatent --emit-split`).
	split:         map[string]u32,
}

Stats :: struct {
	objects:      int,
	functions:    int,
	natives:      int, // declared-only; no body to emit
	bodied:       int, // functions carrying at least one instruction
	with_lines:   int, // ...of those, how many carry debug line numbers
	instructions: int,
	statements:   int,
	labels:       int,
	max_locals:   int, // Lua 5.4 caps a function at 200
	dropped_cast: int, // T1: self-casts removed
	bare_calls:   int, // T1: calls whose result went to ::NoneVar
	inlined:      int, // T2: definitions folded into their reader
	split:        int, // S6: bodies split at their waits
}

// transpile renders one parsed script as a Lua chunk. The returned string is owned by the
// caller. Pure: same input, same output, no side effects.
transpile :: proc(
	p: ^pex.Pex,
	opt := Options{},
	allocator := context.allocator,
) -> (
	source: string,
	stats: Stats,
) {
	context.allocator = allocator
	e := Emitter{opt = opt}
	if e.opt.runtime == "" {
		e.opt.runtime = DEFAULT_RUNTIME
	}
	strings.builder_init(&e.sb, allocator)
	emit_file(&e, p)
	return strings.to_string(e.sb), e.stats
}

@(private)
Emitter :: struct {
	sb:       strings.Builder,
	opt:      Options,
	stats:    Stats,
	obj:      ^pex.Object, // the object being written
	// T2 expansion state, live only while a function body is being written.
	fn:       ^pex.Function,
	dropped:  []bool, // instruction folded into its reader
	block_lo: []int,  // per instruction, the index its basic block starts at
	split:    ^Split, // the body being written is split at these waits
}

@(private)
emit_file :: proc(e: ^Emitter, p: ^pex.Pex) {
	// The header is untrusted: a newline in it would end the comment and inject Lua.
	sbprint(e, "-- transpiled from ")
	for i in 0 ..< len(p.source_file) {
		c := p.source_file[i]
		strings.write_byte(&e.sb, c < 0x20 || c == 0x7f ? '?' : c)
	}
	sbprint(e, "\n")
	sbprintf(e, "-- pex %d.%d game %d debug %v\n", p.major, p.minor, p.game_id, p.has_debug)
	sbprintf(e, "local rt = require('%s')\n\n", e.opt.runtime)
	for &o in p.objects {
		emit_object(e, &o)
	}
}

@(private)
emit_object :: proc(e: ^Emitter, o: ^pex.Object) {
	e.stats.objects += 1
	e.obj = o

	sbprint(e, "local ")
	write_mangled(e, o.name)
	sbprint(e, " = rt.class(")
	write_lua_string(e, o.name)
	sbprint(e, ", ")
	if o.parent == "" {
		sbprint(e, "nil")
	} else {
		write_lua_string(e, o.parent)
	}
	sbprint(e, ")\n")

	if o.auto_state != "" {
		write_mangled(e, o.name)
		sbprint(e, ".__autostate = ")
		write_lua_string(e, o.auto_state)
		sbprint(e, "\n")
	}

	// Member variables carry their compile-time default. 94.5% of them back an auto-property
	// and refill from the plugin, so the runtime decides what to persist — not this table.
	if len(o.variables) > 0 {
		write_mangled(e, o.name)
		sbprint(e, ".__vars = {\n")
		for v in o.variables {
			sbprint(e, "\t[")
			write_key(e, v.name)
			sbprint(e, "] = { type = ")
			write_lua_string(e, v.type_name)
			// Null here means "no initializer"; rt gives the member its type's zero.
			sbprint(e, ", default = ")
			if v.value.kind == .Null {
				sbprint(e, "nil")
			} else {
				write_value(e, v.value)
			}
			sbprint(e, " },\n")
		}
		sbprint(e, "}\n")
	}
	splits := plan_splits(e, o)
	emit_split_fields(e, o, splits[:])

	for &pr in o.properties {
		emit_property(e, o.name, &pr)
	}
	// rt.class creates the default tables; a named state's table exists only if declared here.
	for st in o.states {
		if st.name == "" {continue}
		write_mangled(e, o.name)
		sbprint(e, ".__states[")
		write_key(e, st.name)
		sbprint(e, "] = {}\n")
	}
	for &st in o.states {
		for &f in st.functions {
			e.split = find_split(splits[:], st.name, &f)
			emit_function(e, o.name, st.name, f.name, &f)
			e.split = nil
		}
	}
	if len(splits) > 0 {
		e.stats.split += len(splits)
		emit_split_ticks(e, o, splits[:])
	}

	sbprint(e, "\nreturn ")
	write_mangled(e, o.name)
	sbprint(e, "\n\n")
}

// PROP_AUTO is the property flag bit marking an auto-property (backed by a member variable
// rather than by reader/writer bodies).
@(private)
PROP_AUTO :: 0x4

@(private)
emit_property :: proc(e: ^Emitter, obj: string, pr: ^pex.Property) {
	if pr.flags & PROP_AUTO != 0 {
		write_mangled(e, obj)
		sbprint(e, ".__autoprop[")
		write_key(e, pr.name)
		sbprint(e, "] = ")
		write_key(e, pr.auto_var)
		sbprint(e, "\n")
		return
	}
	// A full property's bodies are unnamed in the file; key them off the property.
	if pr.has_reader {
		name := strings.concatenate({"__propget_", pr.name})
		defer delete(name)
		emit_function(e, obj, "", name, &pr.reader)
	}
	if pr.has_writer {
		name := strings.concatenate({"__propset_", pr.name})
		defer delete(name)
		emit_function(e, obj, "", name, &pr.writer)
	}
}

@(private)
emit_function :: proc(e: ^Emitter, obj, state, name: string, f: ^pex.Function) {
	e.stats.functions += 1

	if f.is_native {
		e.stats.natives += 1
		write_slot(e, obj, state, name)
		sbprint(e, " = rt.native(")
		write_lua_string(e, obj)
		sbprint(e, ", ")
		write_lua_string(e, name)
		sbprintf(e, ", %v)\n", f.is_global)
		return
	}

	e.stats.instructions += len(f.instructions)
	e.stats.max_locals = max(e.stats.max_locals, len(f.locals))
	if len(f.instructions) > 0 {
		e.stats.bodied += 1
		for ins in f.instructions {
			if ins.line != 0 {
				e.stats.with_lines += 1
				break
			}
		}
	}

	write_slot(e, obj, state, name)
	sbprint(e, " = function(")
	// An instance function takes its receiver explicitly, so a state table can hold plain
	// functions rather than methods.
	first := true
	if !f.is_global {
		sbprint(e, "self")
		first = false
	}
	for pm in f.params {
		if !first {
			sbprint(e, ", ")
		}
		write_mangled(e, pm.name)
		first = false
	}
	sbprint(e, ")\n")
	write_locals(e, f)
	if e.split != nil {
		emit_split_drop(e, e.split)
		emit_body(e, f, 0, e.split.before)
	} else {
		emit_body(e, f)
	}
	sbprint(e, "end\n")
}

// write_locals declares every local up front. That is what keeps a `goto` from ever jumping
// into the scope of a local, which Lua rejects. Each starts at its type's zero, as in Papyrus: a
// local can be read before its first write (DLC2ManyToManyFactionRelationScript does).
@(private)
write_locals :: proc(e: ^Emitter, f: ^pex.Function) {
	if len(f.locals) > 0 {
		sbprint(e, "\tlocal ")
		for l, i in f.locals {
			if i > 0 {
				sbprint(e, ", ")
			}
			write_mangled(e, l.name)
		}
		sbprint(e, " = ")
		for l, i in f.locals {
			if i > 0 {
				sbprint(e, ", ")
			}
			sbprint(e, type_zero(l.type_name))
		}
		sbprint(e, "\n")
	}
}

// emit_body writes the statements from `from` on; with `only`, just the instructions it marks.
@(private)
emit_body :: proc(e: ^Emitter, f: ^pex.Function, from := 0, only: []bool = nil) {
	n := len(f.instructions)
	// One slot past the end: a jump may fall off the bottom of the function.
	labels := make([]bool, n + 1)
	defer delete(labels)
	for ins, i in f.instructions {
		if t, ok := jump_target(i, ins); ok && t <= n {
			labels[t] = true
		}
	}
	// A resume lands after each wait, which also keeps T2 from folding a value across it.
	if e.split != nil {
		for site in e.split.sites {labels[site + 1] = true}
	}

	dropped, block_lo := plan_inline(f^, labels, e.opt.no_inline)
	defer delete(dropped)
	defer delete(block_lo)
	e.fn, e.dropped, e.block_lo = f, dropped, block_lo
	defer {e.fn, e.dropped, e.block_lo = nil, nil, nil}

	for ins, i in f.instructions[from:] {
		i := i + from
		if only != nil && !only[i] {continue}
		if labels[i] {
			sbprintf(e, "\t::L%d::\n", i)
			e.stats.labels += 1
		}
		if dropped[i] {
			continue // folded into its reader
		}
		if e.split != nil && is_wait(ins) {
			emit_wait(e, i, ins)
			continue
		}
		if emit_stmt(e, i, ins) {
			e.stats.statements += 1
		}
	}
	if labels[n] {
		sbprintf(e, "\t::L%d::\n", n)
		e.stats.labels += 1
	}
}

// type_zero is the Lua literal a Papyrus variable of this type starts as. Objects and arrays start
// as None.
@(private)
type_zero :: proc(type_name: string) -> string {
	switch strings.to_lower(type_name, context.temp_allocator) {
	case "int":    return "0"
	case "float":  return "0.0"
	case "bool":   return "false"
	case "string": return `""`
	}
	return NONE
}

// write_slot names where a function lands: the default-state table, or a named state's.
@(private)
write_slot :: proc(e: ^Emitter, obj, state, fn: string) {
	write_mangled(e, obj)
	if state == "" {
		sbprint(e, ".__fn[")
	} else {
		sbprint(e, ".__states[")
		write_key(e, state)
		sbprint(e, "][")
	}
	write_key(e, fn)
	sbprint(e, "]")
}

// jump_target resolves a jump's ABSOLUTE destination. Offsets are relative to the jumping
// instruction's own index — verified on Quest.ModObjectiveGlobal, where JmpF at 008 with
// offset 4 lands on 012.
@(private)
jump_target :: proc(idx: int, ins: pex.Instruction) -> (target: int, ok: bool) {
	off: i32
	#partial switch ins.op {
	case .Jmp:
		if len(ins.args) < 1 || ins.args[0].kind != .Integer {
			return 0, false
		}
		off = ins.args[0].i
	case .JmpT, .JmpF:
		if len(ins.args) < 2 || ins.args[1].kind != .Integer {
			return 0, false
		}
		off = ins.args[1].i
	case:
		return 0, false
	}
	return max(0, idx + int(off)), true
}
