package transpile

// One PEX instruction becomes one Lua statement (tier T0), minus the T1 drops and the T2
// definitions folded into their reader.
//
// Every engine-facing operation goes through the `rt` table. The transpiler never decides
// what `rt` does — see the contract table in mydocs/papyrus-transpiler.md.


import "core:strings"
import "../formats/pex"

// emit_stmt writes one statement and reports whether anything was written. A T1 drop writes
// nothing and returns false.
@(private)
emit_stmt :: proc(e: ^Emitter, idx: int, ins: pex.Instruction) -> bool {
	if is_noop(ins) {
		if ins.op == .Cast {
			e.stats.dropped_cast += 1 // compiler padding around a short-circuit
		}
		return false
	}

	sbprint(e, "\t")
	write_stmt(e, idx, ins)
	if e.opt.line_comments && ins.line != 0 {
		sbprintf(e, " -- :%d", ins.line)
	}
	sbprint(e, "\n")
	return true
}

@(private)
write_stmt :: proc(e: ^Emitter, idx: int, ins: pex.Instruction) {
	// Anything T2 could fold renders as `dest = <expression>`, so the expression half is
	// shared with the inliner.
	if inlinable_op(ins.op) {
		write_value(e, arg(ins, 0))
		sbprint(e, " = ")
		write_rhs(e, idx, ins)
		return
	}

	#partial switch ins.op {
	case .Jmp:
		t, _ := jump_target(idx, ins)
		sbprintf(e, "goto L%d", t)
	case .JmpT:
		t, _ := jump_target(idx, ins)
		sbprint(e, "if ")
		write_condition(e, arg(ins, 0), idx)
		sbprintf(e, " then goto L%d end", t)
	case .JmpF:
		t, _ := jump_target(idx, ins)
		sbprint(e, "if not ")
		write_condition(e, arg(ins, 0), idx)
		sbprintf(e, " then goto L%d end", t)

	// callmethod <name> <self> <dest> <args...>
	case .CallMethod:
		write_call_dest(e, arg(ins, 2))
		sbprint(e, "rt.call(")
		write_read(e, arg(ins, 1), idx)
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		write_rest(e, ins, 3, idx)
		sbprint(e, ")")

	// callstatic <class> <name> <dest> <args...>
	case .CallStatic:
		write_call_dest(e, arg(ins, 2))
		sbprint(e, "rt.static(")
		write_lua_string(e, ident_of(arg(ins, 0)))
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 1)))
		write_rest(e, ins, 3, idx)
		sbprint(e, ")")

	// callparent <name> <dest> <args...>. The calling class names where the lookup starts: from
	// the middle of a three-level chain, self's own class would start too low.
	case .CallParent:
		write_call_dest(e, arg(ins, 1))
		sbprint(e, "rt.parent(self, ")
		write_lua_string(e, e.obj.name)
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		write_rest(e, ins, 2, idx)
		sbprint(e, ")")

	// A bare `return` may not sit mid-block in Lua, so every one gets its own block.
	case .Return:
		v := arg(ins, 0)
		if v.kind == .Null {
			sbprint(e, "do return end")
		} else {
			sbprint(e, "do return ")
			write_read(e, v, idx)
			sbprint(e, " end")
		}

	// propget <name> <obj> <dest> / propset <name> <obj> <value>
	case .PropGet:
		write_value(e, arg(ins, 2))
		sbprint(e, " = rt.get(")
		write_read(e, arg(ins, 1), idx)
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		sbprint(e, ")")
	case .PropSet:
		sbprint(e, "rt.set(")
		write_read(e, arg(ins, 1), idx)
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		sbprint(e, ", ")
		write_read(e, arg(ins, 2), idx)
		sbprint(e, ")")

	// Papyrus arrays are zero-based, so every access goes through a helper.
	// The element type fills the new slots: an int[] starts as zeros, not None.
	case .ArrayCreate:
		write_value(e, arg(ins, 0))
		sbprint(e, " = rt.array(")
		write_read(e, arg(ins, 1), idx)
		sbprint(e, ", ")
		write_key(e, strings.trim_suffix(dest_type(e, arg(ins, 0)), "[]"))
		sbprint(e, ")")
	case .ArrayGetElement:
		write_assign_call(e, arg(ins, 0), "rt.aget", {arg(ins, 1), arg(ins, 2)}, idx)
	case .ArraySetElement:
		sbprint(e, "rt.aset(")
		write_read(e, arg(ins, 0), idx)
		sbprint(e, ", ")
		write_read(e, arg(ins, 1), idx)
		sbprint(e, ", ")
		write_read(e, arg(ins, 2), idx)
		sbprint(e, ")")
	// arrayfind <array> <dest> <value> <start>
	case .ArrayFindElement:
		write_assign_call(
			e, arg(ins, 1), "rt.afind", {arg(ins, 0), arg(ins, 2), arg(ins, 3)}, idx,
		)
	case .ArrayRFindElement:
		write_assign_call(
			e, arg(ins, 1), "rt.arfind", {arg(ins, 0), arg(ins, 2), arg(ins, 3)}, idx,
		)
	}
}

// write_rhs renders the value half of an assignment — the piece T2 folds into a reader.
@(private)
write_rhs :: proc(e: ^Emitter, idx: int, ins: pex.Instruction) {
	#partial switch ins.op {
	case .IAdd, .FAdd:
		write_binary(e, ins, "+", idx)
	case .ISub, .FSub:
		write_binary(e, ins, "-", idx)
	case .IMul, .FMul:
		write_binary(e, ins, "*", idx)
	case .FDiv:
		write_binary(e, ins, "/", idx)
	// The engine's Lua gives `==` Papyrus semantics (build/lua-02-papyrus-eq.patch).
	case .CmpEq:
		write_binary(e, ins, "==", idx)
	case .CmpLt:
		write_binary(e, ins, "<", idx)
	case .CmpLe:
		write_binary(e, ins, "<=", idx)
	case .CmpGt:
		write_binary(e, ins, ">", idx)
	case .CmpGe:
		write_binary(e, ins, ">=", idx)

	// Papyrus integer division truncates toward zero. Lua's // rounds down, so -7/2 would
	// give -4 where Papyrus gives -3.
	case .IDiv:
		write_call(e, "rt.idiv", {arg(ins, 1), arg(ins, 2)}, idx)
	case .IMod:
		write_call(e, "rt.imod", {arg(ins, 1), arg(ins, 2)}, idx)
	case .StrCat:
		write_call(e, "rt.concat", {arg(ins, 1), arg(ins, 2)}, idx)
	// The target type is the destination's declared type; Papyrus conditions are
	// cast-then-JmpF, so without it the runtime cannot tell a Bool test from an Int one.
	case .Cast:
		sbprint(e, "rt.cast(")
		write_read(e, arg(ins, 1), idx)
		sbprint(e, ", ")
		write_key(e, dest_type(e, arg(ins, 0)))
		sbprint(e, ")")
	case .ArrayLength:
		write_call(e, "rt.alen", {arg(ins, 1)}, idx)

	case .Not:
		sbprint(e, "not ")
		write_read(e, arg(ins, 1), idx)
	case .INeg, .FNeg:
		sbprint(e, "-")
		write_read(e, arg(ins, 1), idx)
	case .Assign:
		write_read(e, arg(ins, 1), idx)
	}
}

// dest_type is the declared type of a cast's destination: a local or parameter, else a member
// of this object. "" for a member only an ancestor declares, whose type this file cannot see.
@(private)
dest_type :: proc(e: ^Emitter, v: pex.Value) -> string {
	if e.fn != nil {
		for l in e.fn.locals {if l.name == v.str {return l.type_name}}
		for p in e.fn.params {if p.name == v.str {return p.type_name}}
	}
	for m in e.obj.variables {
		if strings.equal_fold(m.name, v.str) {return m.type_name}
	}
	return ""
}

// write_condition renders a jump's condition. The compiler usually casts to Bool first, but a
// jump can test an Int, Float or String directly (4 sites in SE), and Lua counts 0 and "" true.
@(private)
write_condition :: proc(e: ^Emitter, v: pex.Value, at: int) {
	switch strings.to_lower(dest_type(e, v), context.temp_allocator) {
	case "int", "float", "string":
		sbprint(e, "rt.cast(")
		write_read(e, v, at)
		sbprint(e, ", \"bool\")")
	case:
		write_read(e, v, at)
	}
}

// write_read renders one value in a READ position. When T2 folded the instruction that
// defined it, the definition's expression goes here instead.
@(private)
write_read :: proc(e: ^Emitter, v: pex.Value, at: int) {
	if v.kind == .Identifier {
		if def, ok := find_def(e, v.str, at); ok {
			ins := e.fn.instructions[def]
			paren := needs_parens(ins.op)
			if paren {
				sbprint(e, "(")
			}
			write_rhs(e, def, ins)
			if paren {
				sbprint(e, ")")
			}
			e.stats.inlined += 1
			return
		}
	}
	write_value(e, v)
}

// find_def looks back through the current block for the folded definition of `name`. A live
// write to the name ends the search — that value was not folded.
@(private)
find_def :: proc(e: ^Emitter, name: string, at: int) -> (def: int, ok: bool) {
	if e.fn == nil || e.dropped == nil || at <= 0 || at >= len(e.fn.instructions) {
		return 0, false
	}
	for k := at - 1; k >= e.block_lo[at]; k -= 1 {
		ins := e.fn.instructions[k]
		if e.dropped[k] {
			if d, dok := dest_ident(ins); dok && d == name {
				return k, true
			}
			continue
		}
		if writes_name(ins, name) {
			return 0, false
		}
	}
	return 0, false
}

@(private)
write_binary :: proc(e: ^Emitter, ins: pex.Instruction, op: string, idx: int) {
	write_read(e, arg(ins, 1), idx)
	sbprint(e, " ")
	sbprint(e, op)
	sbprint(e, " ")
	write_read(e, arg(ins, 2), idx)
}

@(private)
write_call :: proc(e: ^Emitter, fn: string, args: []pex.Value, idx: int) {
	sbprint(e, fn)
	sbprint(e, "(")
	for a, i in args {
		if i > 0 {
			sbprint(e, ", ")
		}
		write_read(e, a, idx)
	}
	sbprint(e, ")")
}

@(private)
write_assign_call :: proc(
	e: ^Emitter,
	dest: pex.Value,
	fn: string,
	args: []pex.Value,
	idx: int,
) {
	write_value(e, dest)
	sbprint(e, " = ")
	write_call(e, fn, args, idx)
}

// write_call_dest writes the `dest = ` prefix, or nothing when the call's result goes to the
// void sink — which makes it a bare statement (T1).
@(private)
write_call_dest :: proc(e: ^Emitter, dest: pex.Value) {
	if is_nonevar(dest) {
		e.stats.bare_calls += 1
		return
	}
	write_value(e, dest)
	sbprint(e, " = ")
}

// write_rest writes the variadic call arguments that follow the fixed prefix.
@(private)
write_rest :: proc(e: ^Emitter, ins: pex.Instruction, from: int, idx: int) {
	for i in from ..< len(ins.args) {
		sbprint(e, ", ")
		write_read(e, ins.args[i], idx)
	}
}
