package pex

// PEX (compiled Papyrus) reader — Phase 4 scripting, the script registry's first
// deliverable (see the phase4-scripting-plan memory + docs/saves.md lineage).
// Target: Skyrim Legendary Edition `.pex` — BIG-ENDIAN, magic 0xFA57C0DE,
// major 3 / minor 1 / game 1. (Fallout 4 `.pex` are little-endian minor 2 with
// extra debug tables — out of scope.)
//
// This is a pure structural reader, no engine deps: header → string table →
// (optional) debug info → user flags → objects {variables, properties, states →
// functions → {params, locals, instructions}}. It feeds two consumers that share
// this one parse: (1) the native SIGNATURE MANIFEST + call histogram that prime
// the registry's hot set (see manifest.odin), and (2) the eventual PEX→Lua front
// end (the instruction stream is decoded, not skipped). Champollion's `Pex/` source
// is the authoritative layout SPEC — we lift the knowledge, not the binary.
//
// String ownership: `Pex.string_table` is the SOLE owner of all parsed string
// memory; every `string` field on the nested structs is an ALIAS into a table
// entry (the table outlives them), so destroy() frees the table once plus the
// slice spines. The three header strings (source/user/machine) are stored inline
// in the file (not the table) and are cloned/owned separately.

import "core:encoding/endian"
import "core:strings"

MAGIC :: 0xFA57C0DE

// Value (PEX "VariableData") — a typed immediate: variable defaults and every
// instruction argument are encoded this way.
Value_Kind :: enum u8 {
	Null       = 0,
	Identifier = 1, // u16 string-table index (a name reference, e.g. a local var)
	String     = 2, // u16 string-table index (a string literal)
	Integer    = 3, // i32
	Float      = 4, // f32
	Bool       = 5, // u8
}

Value :: struct {
	kind: Value_Kind,
	str:  string, // Identifier/String: alias into the string table
	i:    i32,    // Integer
	f:    f32,    // Float
	b:    bool,   // Bool
}

Variable :: struct {
	name:       string,
	type_name:  string,
	user_flags: u32,
	value:      Value, // compile-time default
}

// Var is one (name, type) pair — a function parameter or local.
Var :: struct {
	name:      string,
	type_name: string,
}

Instruction :: struct {
	op:   Opcode,
	args: []Value, // fixed args followed by resolved var-args (call* opcodes)
	line: u16,     // source line from the debug table; 0 when absent
}

Function :: struct {
	name:         string, // named-function name in a state; "" for property handlers
	return_type:  string, // "None" for void
	doc:          string,
	user_flags:   u32,
	is_global:    bool, // flags bit 0 — a static (global) function
	is_native:    bool, // flags bit 1 — engine native (no body); the API surface
	params:       []Var,
	locals:       []Var,
	instructions: []Instruction,
}

Property :: struct {
	name:       string,
	type_name:  string,
	doc:        string,
	user_flags: u32,
	flags:      u8,     // bit0 read, bit1 write, bit2 auto-var
	auto_var:   string, // set when flags&4 (auto property backed by a member var)
	has_reader: bool,
	has_writer: bool,
	reader:     Function, // valid when has_reader
	writer:     Function, // valid when has_writer
}

State :: struct {
	name:      string, // "" = the empty/default state
	functions: []Function,
}

Object :: struct {
	name:       string,
	parent:     string, // parent script class ("" if none)
	doc:        string,
	user_flags: u32,
	auto_state: string,
	variables:  []Variable,
	properties: []Property,
	states:     []State,
}

User_Flag :: struct {
	name:  string,
	index: u8, // bit position this flag occupies in the user_flags bitfields
}

Pex :: struct {
	major:        u8,
	minor:        u8,
	game_id:      u16,
	compile_time: i64,    // time_t of compilation
	source_file:  string, // owned (inline header string)
	username:     string, // owned (inline header string)
	machine:      string, // owned (inline header string)
	string_table: []string, // OWNER of all table string memory
	has_debug:    bool,
	user_flags:   []User_Flag,
	objects:      []Object,
}

// parse decodes a whole `.pex` image. Returns ok=false (and a partially-built Pex
// that destroy() still cleans up) on any malformed/truncated input.
parse :: proc(data: []u8, allocator := context.allocator) -> (p: Pex, ok: bool) {
	context.allocator = allocator
	r := Reader{data = data, ok = true}

	if read_u32(&r) != MAGIC {
		return p, false
	}
	p.major = read_u8(&r)
	p.minor = read_u8(&r)
	p.game_id = read_u16(&r)
	p.compile_time = i64(read_u64(&r))
	p.source_file = read_wstring(&r)
	p.username = read_wstring(&r)
	p.machine = read_wstring(&r)

	// String table — owns every name/literal the rest of the file references.
	n_strings := int(read_u16(&r))
	if !have(&r, 0) {return p, false}
	p.string_table = make([]string, n_strings)
	for i in 0 ..< n_strings {
		p.string_table[i] = read_wstring(&r)
	}

	// Debug info — optional. We KEEP the per-instruction line table: it marks the original
	// statement boundaries, which is the transpiler's best structuring hint (docs/papyrus-
	// transpiler.md). Every authored function carries one; GotoState/GetState don't, because
	// the compiler generates them.
	lines: map[Debug_Key][]u16
	defer delete(lines)
	p.has_debug = read_u8(&r) != 0
	if p.has_debug {
		_ = read_u64(&r) // modification time
		n_fn := int(read_u16(&r))
		lines = make(map[Debug_Key][]u16, n_fn, context.temp_allocator)
		for _ in 0 ..< n_fn {
			key := Debug_Key {
				object = tbl(&p, read_u16(&r)),
				state  = tbl(&p, read_u16(&r)),
				fn     = tbl(&p, read_u16(&r)),
			}
			_ = read_u8(&r) // function type
			n_instr := int(read_u16(&r))
			v := make([]u16, n_instr, context.temp_allocator)
			for i in 0 ..< n_instr {
				v[i] = read_u16(&r)
			}
			if !r.ok {return p, false}
			lines[key] = v
		}
	}

	// User-flag definitions (name index -> bit position).
	n_uf := int(read_u16(&r))
	p.user_flags = make([]User_Flag, n_uf)
	for i in 0 ..< n_uf {
		name := tbl(&p, read_u16(&r))
		p.user_flags[i] = {name = name, index = read_u8(&r)}
	}

	// Objects.
	n_obj := int(read_u16(&r))
	p.objects = make([]Object, n_obj)
	for i in 0 ..< n_obj {
		p.objects[i] = read_object(&r, &p)
		if !r.ok {return p, false}
	}

	attach_lines(&p, lines)
	return p, r.ok
}

// Debug_Key identifies one function in the debug line table. The names alias the string table,
// so the same spelling the object carries.
Debug_Key :: struct {
	object: string,
	state:  string,
	fn:     string,
}

// attach_lines folds the debug line table back onto each instruction.
@(private)
attach_lines :: proc(p: ^Pex, lines: map[Debug_Key][]u16) {
	if len(lines) == 0 {
		return
	}
	for &o in p.objects {
		for &st in o.states {
			for &f in st.functions {
				v := lines[Debug_Key{o.name, st.name, f.name}] or_continue
				for &ins, i in f.instructions {
					if i < len(v) {
						ins.line = v[i]
					}
				}
			}
		}
	}
}

@(private)
read_object :: proc(r: ^Reader, p: ^Pex) -> (o: Object) {
	o.name = tbl(p, read_u16(r))
	_ = read_u32(r) // size in bytes of the rest of this object (we parse sequentially)
	o.parent = tbl(p, read_u16(r))
	o.doc = tbl(p, read_u16(r))
	o.user_flags = read_u32(r)
	o.auto_state = tbl(p, read_u16(r))

	n_var := int(read_u16(r))
	o.variables = make([]Variable, n_var)
	for i in 0 ..< n_var {
		v: Variable
		v.name = tbl(p, read_u16(r))
		v.type_name = tbl(p, read_u16(r))
		v.user_flags = read_u32(r)
		v.value = read_value(r, p)
		o.variables[i] = v
		if !r.ok {return o}
	}

	n_prop := int(read_u16(r))
	o.properties = make([]Property, n_prop)
	for i in 0 ..< n_prop {
		pr: Property
		pr.name = tbl(p, read_u16(r))
		pr.type_name = tbl(p, read_u16(r))
		pr.doc = tbl(p, read_u16(r))
		pr.user_flags = read_u32(r)
		pr.flags = read_u8(r)
		if pr.flags & 0x4 != 0 {
			pr.auto_var = tbl(p, read_u16(r)) // auto property -> backing member
		} else {
			if pr.flags & 0x1 != 0 {
				pr.has_reader = true
				pr.reader = read_function(r, p)
			}
			if pr.flags & 0x2 != 0 {
				pr.has_writer = true
				pr.writer = read_function(r, p)
			}
		}
		o.properties[i] = pr
		if !r.ok {return o}
	}

	n_state := int(read_u16(r))
	o.states = make([]State, n_state)
	for i in 0 ..< n_state {
		st: State
		st.name = tbl(p, read_u16(r))
		n_sfn := int(read_u16(r))
		st.functions = make([]Function, n_sfn)
		for j in 0 ..< n_sfn {
			fn_name := tbl(p, read_u16(r)) // the named-function table prefixes the name
			f := read_function(r, p)
			f.name = fn_name
			st.functions[j] = f
			if !r.ok {return o}
		}
		o.states[i] = st
	}
	return o
}

@(private)
read_function :: proc(r: ^Reader, p: ^Pex) -> (f: Function) {
	f.return_type = tbl(p, read_u16(r))
	f.doc = tbl(p, read_u16(r))
	f.user_flags = read_u32(r)
	flags := read_u8(r)
	f.is_global = flags & 0x1 != 0
	f.is_native = flags & 0x2 != 0

	n_param := int(read_u16(r))
	f.params = make([]Var, n_param)
	for i in 0 ..< n_param {
		f.params[i] = {tbl(p, read_u16(r)), tbl(p, read_u16(r))}
	}
	n_local := int(read_u16(r))
	f.locals = make([]Var, n_local)
	for i in 0 ..< n_local {
		f.locals[i] = {tbl(p, read_u16(r)), tbl(p, read_u16(r))}
	}
	n_instr := int(read_u16(r))
	f.instructions = make([]Instruction, n_instr)
	for i in 0 ..< n_instr {
		f.instructions[i] = read_instruction(r, p)
		if !r.ok {return f}
	}
	return f
}

// read_value decodes one VariableData (a typed immediate / instruction arg).
@(private)
read_value :: proc(r: ^Reader, p: ^Pex) -> (v: Value) {
	v.kind = Value_Kind(read_u8(r))
	switch v.kind {
	case .Null:
	case .Identifier, .String:
		v.str = tbl(p, read_u16(r))
	case .Integer:
		v.i = read_i32(r)
	case .Float:
		v.f = read_f32(r)
	case .Bool:
		v.b = read_u8(r) != 0
	case:
		r.ok = false // unknown value tag — the stream is misaligned
	}
	return v
}

// tbl resolves a string-table index to its (table-owned) string, "" if OOB.
@(private)
tbl :: proc(p: ^Pex, idx: u16) -> string {
	if int(idx) >= len(p.string_table) {
		return ""
	}
	return p.string_table[idx]
}

destroy :: proc(p: ^Pex, allocator := context.allocator) {
	context.allocator = allocator
	delete(p.source_file)
	delete(p.username)
	delete(p.machine)
	for s in p.string_table {
		delete(s)
	}
	delete(p.string_table)
	delete(p.user_flags)
	for &o in p.objects {
		delete(o.variables)
		for &pr in o.properties {
			if pr.has_reader {free_function(&pr.reader)}
			if pr.has_writer {free_function(&pr.writer)}
		}
		delete(o.properties)
		for &st in o.states {
			for &f in st.functions {
				free_function(&f)
			}
			delete(st.functions)
		}
		delete(o.states)
	}
	delete(p.objects)
}

@(private)
free_function :: proc(f: ^Function) {
	delete(f.params)
	delete(f.locals)
	for instr in f.instructions {
		delete(instr.args)
	}
	delete(f.instructions)
}

// ── Reader (big-endian) ──────────────────────────────────────────────────────
// Mirrors formats/nif's Reader idiom; flips endianness to .Big (Skyrim LE PEX).

Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool,
}

@(private)
have :: proc(r: ^Reader, n: int) -> bool {
	if !r.ok || r.pos + n > len(r.data) {
		r.ok = false
		return false
	}
	return true
}

@(private)
read_u8 :: proc(r: ^Reader) -> u8 {
	if !have(r, 1) {return 0}
	v := r.data[r.pos]
	r.pos += 1
	return v
}

@(private)
read_u16 :: proc(r: ^Reader) -> u16 {
	if !have(r, 2) {return 0}
	v, _ := endian.get_u16(r.data[r.pos:r.pos + 2], .Big)
	r.pos += 2
	return v
}

@(private)
read_u32 :: proc(r: ^Reader) -> u32 {
	if !have(r, 4) {return 0}
	v, _ := endian.get_u32(r.data[r.pos:r.pos + 4], .Big)
	r.pos += 4
	return v
}

@(private)
read_u64 :: proc(r: ^Reader) -> u64 {
	if !have(r, 8) {return 0}
	v, _ := endian.get_u64(r.data[r.pos:r.pos + 8], .Big)
	r.pos += 8
	return v
}

@(private)
read_i32 :: proc(r: ^Reader) -> i32 {
	return i32(read_u32(r))
}

@(private)
read_f32 :: proc(r: ^Reader) -> f32 {
	return transmute(f32)read_u32(r)
}

// read_wstring reads a u16-length-prefixed string (no null terminator) and clones
// it into the ambient allocator. Used for the inline header strings and every
// string-table entry.
@(private)
read_wstring :: proc(r: ^Reader) -> string {
	n := int(read_u16(r))
	if n == 0 || !have(r, n) {return ""}
	s := strings.clone(string(r.data[r.pos:r.pos + n]))
	r.pos += n
	return s
}
