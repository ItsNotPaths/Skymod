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
	sb:    strings.Builder,
	opt:   Options,
	stats: Stats,
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
			write_lua_string(e, v.name)
			sbprint(e, "] = { type = ")
			write_lua_string(e, v.type_name)
			sbprint(e, ", default = ")
			write_value(e, v.value)
			sbprint(e, " },\n")
		}
		sbprint(e, "}\n")
	}

	for pr in o.properties {
		emit_property(e, o.name, pr)
	}
	for st in o.states {
		for f in st.functions {
			emit_function(e, o.name, st.name, f.name, f)
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
emit_property :: proc(e: ^Emitter, obj: string, pr: pex.Property) {
	if pr.flags & PROP_AUTO != 0 {
		write_mangled(e, obj)
		sbprint(e, ".__autoprop[")
		write_lua_string(e, pr.name)
		sbprint(e, "] = ")
		write_lua_string(e, pr.auto_var)
		sbprint(e, "\n")
		return
	}
	// A full property's bodies are unnamed in the file; key them off the property.
	if pr.has_reader {
		name := strings.concatenate({"__propget_", pr.name})
		defer delete(name)
		emit_function(e, obj, "", name, pr.reader)
	}
	if pr.has_writer {
		name := strings.concatenate({"__propset_", pr.name})
		defer delete(name)
		emit_function(e, obj, "", name, pr.writer)
	}
}

@(private)
emit_function :: proc(e: ^Emitter, obj, state, name: string, f: pex.Function) {
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
emit_body :: proc(e: ^Emitter, f: pex.Function) {
	n := len(f.instructions)
	// One slot past the end: a jump may fall off the bottom of the function.
	labels := make([]bool, n + 1)
	defer delete(labels)
	for ins, i in f.instructions {
		if t, ok := jump_target(i, ins); ok && t <= n {
			labels[t] = true
		}
	}

	for ins, i in f.instructions {
		if labels[i] {
			sbprintf(e, "\t::L%d::\n", i)
			e.stats.labels += 1
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
		write_lua_string(e, state)
		sbprint(e, "][")
	}
	write_lua_string(e, fn)
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
