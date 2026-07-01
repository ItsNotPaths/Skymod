package pex

// Papyrus bytecode opcodes (0x00..0x23) and the per-instruction decoder.
// Each instruction is `u8 op` followed by its arguments, every argument a
// VariableData (see Value). Most opcodes take a FIXED number of args; the three
// call opcodes take a fixed prefix then a var-arg run: a trailing Integer Value
// giving the count, then that many Values.
//
// Argument shapes for the variable opcodes (matching the CK's Papyrus-assembly
// disassembly form):
//   callmethod  <name> <self>  <dest> <argc> <args...>   (3 fixed)
//   callstatic  <class> <name> <dest> <argc> <args...>   (3 fixed)
//   callparent  <name> <dest>        <argc> <args...>    (2 fixed)
// These three are what the native-call histogram walks (see manifest.odin).

Opcode :: enum u8 {
	Nop              = 0x00,
	IAdd             = 0x01,
	FAdd             = 0x02,
	ISub             = 0x03,
	FSub             = 0x04,
	IMul             = 0x05,
	FMul             = 0x06,
	IDiv             = 0x07,
	FDiv             = 0x08,
	IMod             = 0x09,
	Not              = 0x0A,
	INeg             = 0x0B,
	FNeg             = 0x0C,
	Assign           = 0x0D,
	Cast             = 0x0E,
	CmpEq            = 0x0F,
	CmpLt            = 0x10,
	CmpLe            = 0x11,
	CmpGt            = 0x12,
	CmpGe            = 0x13,
	Jmp              = 0x14,
	JmpT             = 0x15,
	JmpF             = 0x16,
	CallMethod       = 0x17,
	CallParent       = 0x18,
	CallStatic       = 0x19,
	Return           = 0x1A,
	StrCat           = 0x1B,
	PropGet          = 0x1C,
	PropSet          = 0x1D,
	ArrayCreate      = 0x1E,
	ArrayLength      = 0x1F,
	ArrayGetElement  = 0x20,
	ArraySetElement  = 0x21,
	ArrayFindElement = 0x22,
	ArrayRFindElement = 0x23,
}

OPCODE_MAX :: 0x23

// Number of FIXED args per opcode (the var-arg run follows the fixed prefix for
// the call opcodes). Indexed by Opcode.
@(rodata)
fixed_args := [Opcode]int {
	.Nop              = 0,
	.IAdd             = 3,
	.FAdd             = 3,
	.ISub             = 3,
	.FSub             = 3,
	.IMul             = 3,
	.FMul             = 3,
	.IDiv             = 3,
	.FDiv             = 3,
	.IMod             = 3,
	.Not              = 2,
	.INeg             = 2,
	.FNeg             = 2,
	.Assign           = 2,
	.Cast             = 2,
	.CmpEq            = 3,
	.CmpLt            = 3,
	.CmpLe            = 3,
	.CmpGt            = 3,
	.CmpGe            = 3,
	.Jmp              = 1,
	.JmpT             = 2,
	.JmpF             = 2,
	.CallMethod       = 3,
	.CallParent       = 2,
	.CallStatic       = 3,
	.Return           = 1,
	.StrCat           = 3,
	.PropGet          = 3,
	.PropSet          = 3,
	.ArrayCreate      = 2,
	.ArrayLength      = 2,
	.ArrayGetElement  = 3,
	.ArraySetElement  = 3,
	.ArrayFindElement = 4,
	.ArrayRFindElement = 4,
}

@(private)
is_call :: proc(op: Opcode) -> bool {
	return op == .CallMethod || op == .CallParent || op == .CallStatic
}

@(private)
read_instruction :: proc(r: ^Reader, p: ^Pex) -> (ins: Instruction) {
	raw := read_u8(r)
	if int(raw) > OPCODE_MAX {
		r.ok = false // unknown opcode — the stream is misaligned
		return ins
	}
	ins.op = Opcode(raw)
	n_fixed := fixed_args[ins.op]

	args := make([dynamic]Value, 0, n_fixed)
	for _ in 0 ..< n_fixed {
		append(&args, read_value(r, p))
	}
	if is_call(ins.op) {
		count := read_value(r, p)
		n_var := int(count.i) if count.kind == .Integer else 0
		for _ in 0 ..< n_var {
			if !r.ok {break}
			append(&args, read_value(r, p))
		}
	}
	ins.args = args[:]
	return ins
}
