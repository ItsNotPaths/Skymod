package transpile

// One PEX instruction becomes one Lua statement (tier T0), minus the two T1 drops.
//
// Every engine-facing operation goes through the `rt` table. The transpiler never decides
// what `rt` does — see the contract table in docs/papyrus-transpiler.md.

import "../formats/pex"

// emit_stmt writes one statement and reports whether anything was written. A T1 drop writes
// nothing and returns false.
@(private)
emit_stmt :: proc(e: ^Emitter, idx: int, ins: pex.Instruction) -> bool {
	#partial switch ins.op {
	case .Nop:
		return false
	case .Cast:
		// A value cast to its own type is the compiler's short-circuit padding.
		if same_ident(arg(ins, 0), arg(ins, 1)) {
			e.stats.dropped_cast += 1
			return false
		}
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
	switch ins.op {
	case .Nop: // dropped by emit_stmt

	case .IAdd, .FAdd:
		write_binary(e, ins, "+")
	case .ISub, .FSub:
		write_binary(e, ins, "-")
	case .IMul, .FMul:
		write_binary(e, ins, "*")
	case .FDiv:
		write_binary(e, ins, "/")
	// Papyrus integer division truncates toward zero. Lua's // rounds down, so -7/2 would
	// give -4 where Papyrus gives -3.
	case .IDiv:
		write_assign_call(e, arg(ins, 0), "rt.idiv", {arg(ins, 1), arg(ins, 2)})
	case .IMod:
		write_assign_call(e, arg(ins, 0), "rt.imod", {arg(ins, 1), arg(ins, 2)})

	case .Not:
		write_value(e, arg(ins, 0))
		sbprint(e, " = not ")
		write_value(e, arg(ins, 1))
	case .INeg, .FNeg:
		write_value(e, arg(ins, 0))
		sbprint(e, " = -")
		write_value(e, arg(ins, 1))
	case .Assign:
		write_value(e, arg(ins, 0))
		sbprint(e, " = ")
		write_value(e, arg(ins, 1))
	case .Cast:
		write_assign_call(e, arg(ins, 0), "rt.cast", {arg(ins, 1)})

	case .CmpEq:
		write_binary(e, ins, "==")
	case .CmpLt:
		write_binary(e, ins, "<")
	case .CmpLe:
		write_binary(e, ins, "<=")
	case .CmpGt:
		write_binary(e, ins, ">")
	case .CmpGe:
		write_binary(e, ins, ">=")

	case .Jmp:
		t, _ := jump_target(idx, ins)
		sbprintf(e, "goto L%d", t)
	case .JmpT:
		t, _ := jump_target(idx, ins)
		sbprint(e, "if ")
		write_value(e, arg(ins, 0))
		sbprintf(e, " then goto L%d end", t)
	case .JmpF:
		t, _ := jump_target(idx, ins)
		sbprint(e, "if not ")
		write_value(e, arg(ins, 0))
		sbprintf(e, " then goto L%d end", t)

	// callmethod <name> <self> <dest> <args...>
	case .CallMethod:
		write_call_dest(e, arg(ins, 2))
		sbprint(e, "rt.call(")
		write_value(e, arg(ins, 1))
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		write_rest(e, ins, 3)
		sbprint(e, ")")

	// callstatic <class> <name> <dest> <args...>
	case .CallStatic:
		write_call_dest(e, arg(ins, 2))
		sbprint(e, "rt.static(")
		write_lua_string(e, ident_of(arg(ins, 0)))
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 1)))
		write_rest(e, ins, 3)
		sbprint(e, ")")

	// callparent <name> <dest> <args...>
	case .CallParent:
		write_call_dest(e, arg(ins, 1))
		sbprint(e, "rt.parent(self, ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		write_rest(e, ins, 2)
		sbprint(e, ")")

	// A bare `return` may not sit mid-block in Lua, so every one gets its own block.
	case .Return:
		v := arg(ins, 0)
		if v.kind == .Null {
			sbprint(e, "do return end")
		} else {
			sbprint(e, "do return ")
			write_value(e, v)
			sbprint(e, " end")
		}

	case .StrCat:
		write_assign_call(e, arg(ins, 0), "rt.concat", {arg(ins, 1), arg(ins, 2)})

	// propget <name> <obj> <dest> / propset <name> <obj> <value>
	case .PropGet:
		write_value(e, arg(ins, 2))
		sbprint(e, " = rt.get(")
		write_value(e, arg(ins, 1))
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		sbprint(e, ")")
	case .PropSet:
		sbprint(e, "rt.set(")
		write_value(e, arg(ins, 1))
		sbprint(e, ", ")
		write_lua_string(e, ident_of(arg(ins, 0)))
		sbprint(e, ", ")
		write_value(e, arg(ins, 2))
		sbprint(e, ")")

	// Papyrus arrays are zero-based, so every access goes through a helper.
	case .ArrayCreate:
		write_assign_call(e, arg(ins, 0), "rt.array", {arg(ins, 1)})
	case .ArrayLength:
		write_assign_call(e, arg(ins, 0), "rt.alen", {arg(ins, 1)})
	case .ArrayGetElement:
		write_assign_call(e, arg(ins, 0), "rt.aget", {arg(ins, 1), arg(ins, 2)})
	case .ArraySetElement:
		sbprint(e, "rt.aset(")
		write_value(e, arg(ins, 0))
		sbprint(e, ", ")
		write_value(e, arg(ins, 1))
		sbprint(e, ", ")
		write_value(e, arg(ins, 2))
		sbprint(e, ")")
	// arrayfind <array> <dest> <value> <start>
	case .ArrayFindElement:
		write_assign_call(
			e, arg(ins, 1), "rt.afind", {arg(ins, 0), arg(ins, 2), arg(ins, 3)},
		)
	case .ArrayRFindElement:
		write_assign_call(
			e, arg(ins, 1), "rt.arfind", {arg(ins, 0), arg(ins, 2), arg(ins, 3)},
		)
	}
}

@(private)
write_binary :: proc(e: ^Emitter, ins: pex.Instruction, op: string) {
	write_value(e, arg(ins, 0))
	sbprint(e, " = ")
	write_value(e, arg(ins, 1))
	sbprint(e, " ")
	sbprint(e, op)
	sbprint(e, " ")
	write_value(e, arg(ins, 2))
}

@(private)
write_assign_call :: proc(e: ^Emitter, dest: pex.Value, fn: string, args: []pex.Value) {
	write_value(e, dest)
	sbprint(e, " = ")
	sbprint(e, fn)
	sbprint(e, "(")
	for a, i in args {
		if i > 0 {
			sbprint(e, ", ")
		}
		write_value(e, a)
	}
	sbprint(e, ")")
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
write_rest :: proc(e: ^Emitter, ins: pex.Instruction, from: int) {
	for i in from ..< len(ins.args) {
		sbprint(e, ", ")
		write_value(e, ins.args[i])
	}
}
