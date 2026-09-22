package transpile

// T2 — temp inlining. A Papyrus temporary assigned and then read exactly once inside the same
// basic block folds into its reader, so
//
//     __temp1 = aiObjectiveID >= 0
//     if not __temp1 then goto L38 end
//
// becomes `if not (aiObjectiveID >= 0) then goto L38 end`. Temps are 44% of T0's statements.
//
// SOUNDNESS. Four conditions, each load-bearing:
//
//  1. The temp is never live across a block edge. `exposed` holds every name some block READS
//     BEFORE WRITING it — such a name can carry a value produced by another block, so its
//     definition must stay. Papyrus temps are REUSED rather than single-assignment, which is
//     why this counts uses instead of names.
//  2. Exactly one read, inside the defining block, with no rewrite in between.
//  3. Nothing between the definition and the read writes an operand of the definition.
//  4. Every operand is a literal, a local, a parameter, or `self`. A MEMBER variable is
//     excluded: a call can change one with no instruction in this function saying so, and
//     Papyrus reads members as bare identifiers (`::State` in GotoState).
//
// Only side-effect-free definitions move (arithmetic, comparison, cast, concat). A call or a
// property read stays put, because Lua leaves operand evaluation order unspecified and these
// calls mutate world state.

// HOLE(script): T2 treats IDiv/IMod/Cast/StrCat/ArrayLength as movable, but they lower to runtime calls with no totality guarantee — `temp = IDiv(x,0)` can move past a call and fire its error late.

import "core:strings"
import "../formats/pex"

// plan_inline marks each instruction whose value folds into its reader. Also returns, per
// instruction, the index its basic block starts at — the bound for the emitter's search.
@(private)
plan_inline :: proc(
	f: pex.Function,
	labels: []bool,
	disabled := false,
) -> (
	dropped: []bool,
	block_lo: []int,
) {
	n := len(f.instructions)
	dropped = make([]bool, n)
	block_lo = make([]int, n)

	lo := 0
	for i in 0 ..< n {
		if i > 0 && (labels[i] || is_jump(f.instructions[i - 1])) {
			lo = i
		}
		block_lo[i] = lo
	}

	if disabled {
		return dropped, block_lo
	}

	exposed := make(map[string]bool)
	defer delete(exposed)
	compute_exposed(f, block_lo, &exposed)

	for i in 0 ..< n {
		ins := f.instructions[i]
		if !inlinable_op(ins.op) || is_noop(ins) {
			continue
		}
		dest := dest_ident(ins) or_continue
		if !is_temp_local(f, dest) || exposed[dest] {
			continue
		}
		if !operands_are_safe(f, ins) {
			continue
		}
		j := single_use_in_block(f, labels, i, dest) or_continue
		if operand_written_between(f, ins, i, j) {
			continue
		}
		dropped[i] = true
	}
	return dropped, block_lo
}

// compute_exposed collects every name read before it is written within its own block. Those
// names can cross a block edge, so no definition of one may be removed.
@(private)
compute_exposed :: proc(f: pex.Function, block_lo: []int, out: ^map[string]bool) {
	written := make(map[string]bool)
	defer delete(written)

	for ins, i in f.instructions {
		if i > 0 && block_lo[i] != block_lo[i - 1] {
			clear(&written)
		}
		if is_noop(ins) {
			continue
		}
		d := dest_index(ins.op)
		for a, k in ins.args {
			if k == d || is_name_slot(ins.op, k) || a.kind != .Identifier {
				continue
			}
			if !written[a.str] {
				out^[a.str] = true
			}
		}
		if dest, ok := dest_ident(ins); ok {
			written[dest] = true
		}
	}
}

// single_use_in_block finds the one instruction that reads `name` before the block ends or the
// name is rewritten. Fails when there is no read, or more than one.
@(private)
single_use_in_block :: proc(
	f: pex.Function,
	labels: []bool,
	from: int,
	name: string,
) -> (
	use: int,
	ok: bool,
) {
	found := -1
	for j := from + 1; j < len(f.instructions); j += 1 {
		if labels[j] { // a new block: other paths reach it
			break
		}
		ins := f.instructions[j]
		if reads := reads_name(ins, name); reads > 0 {
			if found >= 0 || reads > 1 {
				return 0, false // read more than once
			}
			found = j
		}
		if writes_name(ins, name) {
			break // the window closes on a rewrite
		}
		if is_jump(ins) {
			break // a jump ends the block
		}
	}
	return found, found >= 0
}

@(private)
operand_written_between :: proc(f: pex.Function, ins: pex.Instruction, from, to: int) -> bool {
	d := dest_index(ins.op)
	for k := from + 1; k < to; k += 1 {
		for a, m in ins.args {
			if m == d || is_name_slot(ins.op, m) || a.kind != .Identifier {
				continue
			}
			if writes_name(f.instructions[k], a.str) {
				return true
			}
		}
	}
	return false
}

// operands_are_safe rejects a definition that reads anything a call could change underneath it.
@(private)
operands_are_safe :: proc(f: pex.Function, ins: pex.Instruction) -> bool {
	d := dest_index(ins.op)
	for a, m in ins.args {
		if m == d || is_name_slot(ins.op, m) || a.kind != .Identifier {
			continue
		}
		if a.str == "self" {
			continue // never reassigned
		}
		if !is_declared(f, a.str) {
			return false // a member variable
		}
	}
	return true
}

// ── instruction queries ─────────────────────────────────────────────────────

// dest_index is the argument slot an opcode assigns to, or -1 when it assigns nothing.
@(private)
dest_index :: proc(op: pex.Opcode) -> int {
	#partial switch op {
	case .Nop, .Jmp, .JmpT, .JmpF, .Return, .PropSet, .ArraySetElement:
		return -1
	case .CallMethod, .CallStatic, .PropGet:
		return 2
	case .CallParent, .ArrayFindElement, .ArrayRFindElement:
		return 1
	}
	return 0
}

// is_name_slot marks an argument that holds a NAME rather than a value to read — a method,
// a class, or a property.
@(private)
is_name_slot :: proc(op: pex.Opcode, i: int) -> bool {
	#partial switch op {
	case .CallMethod, .CallParent, .PropGet, .PropSet:
		return i == 0
	case .CallStatic:
		return i == 0 || i == 1
	}
	return false
}

@(private)
dest_ident :: proc(ins: pex.Instruction) -> (name: string, ok: bool) {
	d := dest_index(ins.op)
	if d < 0 || d >= len(ins.args) || ins.args[d].kind != .Identifier {
		return "", false
	}
	return ins.args[d].str, true
}

// is_noop reports an instruction the emitter drops in T1. The analysis must agree with what is
// actually written, so a self-cast counts as neither a read nor a write.
@(private)
is_noop :: proc(ins: pex.Instruction) -> bool {
	return ins.op == .Nop || (ins.op == .Cast && same_ident(arg(ins, 0), arg(ins, 1)))
}

@(private)
reads_name :: proc(ins: pex.Instruction, name: string) -> int {
	if is_noop(ins) {
		return 0
	}
	d := dest_index(ins.op)
	n := 0
	for a, i in ins.args {
		if i == d || is_name_slot(ins.op, i) {
			continue
		}
		if a.kind == .Identifier && a.str == name {
			n += 1
		}
	}
	return n
}

@(private)
writes_name :: proc(ins: pex.Instruction, name: string) -> bool {
	if is_noop(ins) {
		return false
	}
	d, ok := dest_ident(ins)
	return ok && d == name
}

@(private)
is_jump :: proc(ins: pex.Instruction) -> bool {
	return ins.op == .Jmp || ins.op == .JmpT || ins.op == .JmpF
}

// inlinable_op lists the side-effect-free definitions. Calls, property reads, and array
// element access stay put.
@(private)
inlinable_op :: proc(op: pex.Opcode) -> bool {
	#partial switch op {
	case .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul, .FDiv, .IDiv, .IMod,
	     .Not, .INeg, .FNeg, .Assign, .Cast, .StrCat, .ArrayLength,
	     .CmpEq, .CmpLt, .CmpLe, .CmpGt, .CmpGe:
		return true
	}
	return false
}

// needs_parens marks the definitions that render as an infix expression, where folding into a
// larger expression would otherwise change precedence. A call form already binds tightly.
@(private)
needs_parens :: proc(op: pex.Opcode) -> bool {
	#partial switch op {
	case .Assign, .Cast, .StrCat, .ArrayLength, .IDiv, .IMod:
		return false
	}
	return true
}

@(private)
is_temp_local :: proc(f: pex.Function, name: string) -> bool {
	if !strings.has_prefix(name, "::") {
		return false
	}
	for l in f.locals {
		if l.name == name {
			return true
		}
	}
	return false
}

@(private)
is_declared :: proc(f: pex.Function, name: string) -> bool {
	for l in f.locals {
		if l.name == name {
			return true
		}
	}
	for p in f.params {
		if p.name == name {
			return true
		}
	}
	return false
}
