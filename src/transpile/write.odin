package transpile

// Output primitives: everything that turns a PEX value or name into Lua text. All of these
// write straight into the builder, so no intermediate string is ever allocated.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import "../formats/pex"

// Lua keywords. Lua is case-sensitive, so only an exact lowercase match collides.
@(private)
RESERVED := [?]string {
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function",
	"goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
	"true", "until", "while",
}

@(private)
sbprint :: proc(e: ^Emitter, s: string) {
	strings.write_string(&e.sb, s)
}

@(private)
sbprintf :: proc(e: ^Emitter, format: string, args: ..any) {
	fmt.sbprintf(&e.sb, format, ..args)
}

// write_mangled renders a Papyrus identifier as a legal Lua one. Papyrus emits names Lua
// rejects outright — `::temp8`, `::NoneVar`. Each prefix marks one class of name, so no two
// names meet: compiler `::x` -> `__x`, authored `_x` -> `_u_x`, keyword `end` -> `_kend`.
@(private)
write_mangled :: proc(e: ^Emitter, name: string) {
	if is_self(name) || len(name) == 0 {
		sbprint(e, len(name) == 0 ? "_" : "self")
		return
	}
	body := name
	switch {
	case strings.has_prefix(name, "::"):
		sbprint(e, "__")
		body = name[2:]
	case name[0] == '_':
		sbprint(e, "_u")
	case name[0] >= '0' && name[0] <= '9':
		sbprint(e, "_d")
	case slice.contains(RESERVED[:], name):
		sbprint(e, "_k")
	}
	for i in 0 ..< len(body) {
		c := body[i]
		ok :=
			(c >= 'a' && c <= 'z') ||
			(c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') ||
			c == '_'
		strings.write_byte(&e.sb, ok ? c : '_')
	}
}

@(private)
write_lua_string :: proc(e: ^Emitter, s: string) {
	strings.write_byte(&e.sb, '"')
	for i in 0 ..< len(s) {
		switch c := s[i]; c {
		case '"':
			sbprint(e, "\\\"")
		case '\\':
			sbprint(e, "\\\\")
		case '\n':
			sbprint(e, "\\n")
		case '\r':
			sbprint(e, "\\r")
		case '\t':
			sbprint(e, "\\t")
		case:
			if c < 0x20 {
				sbprintf(e, "\\%d", int(c))
			} else {
				strings.write_byte(&e.sb, c)
			}
		}
	}
	strings.write_byte(&e.sb, '"')
}

// write_lua_float keeps a Papyrus Float a float. Lua reads a bare `1` as an integer, so an
// integral value needs the trailing `.0`.
@(private)
write_lua_float :: proc(e: ^Emitter, f: f32) {
	if math.is_nan(f) {
		sbprint(e, "(0/0)")
		return
	}
	if math.is_inf(f) {
		sbprint(e, f > 0 ? "math.huge" : "-math.huge")
		return
	}
	buf: [32]u8
	s := fmt.bprintf(buf[:], "%v", f)
	sbprint(e, s)
	if strings.index_any(s, ".eE") < 0 {
		sbprint(e, ".0")
	}
}

// write_key writes a table key that Papyrus looks up case-insensitively (a function, state,
// member or property name), lowercased so the runtime can fold the incoming name once.
@(private)
write_key :: proc(e: ^Emitter, s: string) {
	lower := strings.to_lower(s)
	defer delete(lower)
	write_lua_string(e, lower)
}

// write_ident renders a name in a value position. A local or parameter stays a Lua local.
// Anything else is a member of the instance, including one an ancestor script declares
// (`::pGhostFXShader_var` on dunForelhostGhostAmbushScript) and the compiler's `::State`.
@(private)
write_ident :: proc(e: ^Emitter, name: string) {
	if is_self(name) || e.fn == nil || is_declared(e.fn^, name) {
		write_mangled(e, name)
		return
	}
	sbprint(e, "self.vars[")
	write_key(e, name)
	sbprint(e, "]")
}

@(private)
write_value :: proc(e: ^Emitter, v: pex.Value) {
	switch v.kind {
	case .Null:
		sbprint(e, NONE)
	case .Identifier:
		write_ident(e, v.str)
	case .String:
		write_lua_string(e, v.str)
	case .Integer:
		sbprintf(e, "%d", v.i)
	case .Float:
		write_lua_float(e, v.f)
	case .Bool:
		sbprint(e, v.b ? "true" : "false")
	}
}

// arg reads an instruction argument, or None when the stream carried fewer than expected.
@(private)
arg :: proc(ins: pex.Instruction, i: int) -> pex.Value {
	return i < len(ins.args) ? ins.args[i] : pex.Value{}
}

// ident_of reads a name argument. Call opcodes carry their class/method as an Identifier in
// the base game, but the tag is not load-bearing — a String holds the same name.
@(private)
ident_of :: proc(v: pex.Value) -> string {
	return v.kind == .Identifier || v.kind == .String ? v.str : ""
}

// is_self folds case: LE scripts spell the receiver `Self` 960 times.
@(private)
is_self :: proc(name: string) -> bool {
	return strings.equal_fold(name, "self")
}

@(private)
same_ident :: proc(a, b: pex.Value) -> bool {
	return a.kind == .Identifier && b.kind == .Identifier && a.str == b.str
}

// NONE is Papyrus None. Never Lua nil: a nil member vanishes from `pairs`, so a save would
// miss it (rt.save_vars).
@(private)
NONE :: "rt.None"

// NONE_VAR is the sink a void call assigns to. A call that writes it is a bare statement.
@(private)
NONE_VAR :: "::NoneVar"

@(private)
is_nonevar :: proc(v: pex.Value) -> bool {
	return v.kind == .Identifier && strings.equal_fold(v.str, NONE_VAR)
}
