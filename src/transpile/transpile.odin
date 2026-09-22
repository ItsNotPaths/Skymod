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

// HOLE(script): the __overridden marker omits the state qualifier its lookup key carries, so OnActivate@Busy is indistinguishable from the default-state one.
// HOLE(script): a whole-script override emits no marker, so a missing hand-written file has nothing to fail on.
// HOLE(script): source_file is written raw into a comment — a newline in an untrusted PEX header injects Lua.

import "core:strings"
import "../formats/pex"

DEFAULT_RUNTIME :: "skymod.rt"

Options :: struct {
	runtime:       string, // module the chunk requires; "" means DEFAULT_RUNTIME
	line_comments: bool,   // annotate each statement with its source line
	// no_inline stops at T1: one statement per instruction, temps left standing. A debugging
	// aid — diff it against the inlined form when T2 is the suspect.
	no_inline:     bool,
	// overrides names the functions written by hand. An overridden function gets a mark
	// instead of a body; an overridden script produces nothing at all.
	overrides:     ^Overrides,
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
	overridden:   int, // functions left to a hand-written override
	// script_overridden means the whole script is hand-written and `source` is empty. The
	// caller must not write a file for it.
	script_overridden: bool,
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
	e.script = script_stem(p.source_file)
	if overrides_has_script(e.opt.overrides, e.script) {
		e.stats.script_overridden = true
		return "", e.stats
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
	script:   string, // source-file stem, the override key's first field
	obj:      ^pex.Object, // the object being written
	// T2 expansion state, live only while a function body is being written.
	fn:       ^pex.Function,
	dropped:  []bool, // instruction folded into its reader
	block_lo: []int,  // per instruction, the index its basic block starts at
}

@(private)
emit_file :: proc(e: ^Emitter, p: ^pex.Pex) {
	sbprint(e, "-- transpiled from ")
	sbprint(e, p.source_file)
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
			sbprint(e, ", default = ")
			write_value(e, v.value)
			sbprint(e, " },\n")
		}
		sbprint(e, "}\n")
	}

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
			emit_function(e, o.name, st.name, f.name, &f)
		}
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

	// A hand-written function gets a mark, not a body. The runtime fails at load when an
	// override is marked but never supplied — otherwise a missing one is a silent hole.
	if overrides_has_fn(e.opt.overrides, e.script, obj, state, name) {
		e.stats.overridden += 1
		write_mangled(e, obj)
		sbprint(e, ".__overridden[")
		write_key(e, name)
		sbprint(e, "] = true\n")
		return
	}

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

	// Every local is declared up front. That is what keeps a `goto` from ever jumping into
	// the scope of a local, which Lua rejects.
	if len(f.locals) > 0 {
		sbprint(e, "\tlocal ")
		for l, i in f.locals {
			if i > 0 {
				sbprint(e, ", ")
			}
			write_mangled(e, l.name)
		}
		sbprint(e, "\n")
	}

	emit_body(e, f)
	sbprint(e, "end\n")
}

@(private)
emit_body :: proc(e: ^Emitter, f: ^pex.Function) {
	n := len(f.instructions)
	// One slot past the end: a jump may fall off the bottom of the function.
	labels := make([]bool, n + 1)
	defer delete(labels)
	for ins, i in f.instructions {
		if t, ok := jump_target(i, ins); ok && t <= n {
			labels[t] = true
		}
	}

	dropped, block_lo := plan_inline(f^, labels, e.opt.no_inline)
	defer delete(dropped)
	defer delete(block_lo)
	e.fn, e.dropped, e.block_lo = f, dropped, block_lo
	defer {e.fn, e.dropped, e.block_lo = nil, nil, nil}

	for ins, i in f.instructions {
		if labels[i] {
			sbprintf(e, "\t::L%d::\n", i)
			e.stats.labels += 1
		}
		if dropped[i] {
			continue // folded into its reader
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
