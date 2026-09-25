package script_lua

// The CE-syntax console preprocessor (docs/script-runtime-decisions.md, "Console"): a THIN line
// rewrite so muscle-memory Skyrim console input works on top of what is fundamentally a Lua REPL.
// The rewrite only fires on unambiguous CE shapes; anything Lua-shaped (contains '(' or '=') passes
// through untouched, so it never fights valid Lua. It is deliberately small and grows as verbs land.
//
// Recognised shapes (only when the line has no '(' / '='):
//   tcl / tgm / help              → cmd.noclip() / cmd.god() / cmd.help()
//   disable | enable | delete     → cmd.disable() …            (CE "acts on the selection" — sel)
//   setscale 2 | moveto 0x14      → cmd.scale(2) | cmd.moveto(ref(0x14))
//   prid 0x1a26f                  → cmd.prid(ref(0x1a26f))      (select a ref by id)
//   0x0001A26F  (bare hex alone)  → ref(0x0001A26F)            (echoes the ref)
//   player.additem 0xf 100        → player:additem(ref(0xf), 100)   (obj ∈ player|sel|0xHEX)
// Method/command names pass through verbatim where dispatched: the registry folds case, so CE's
// lowercase `additem` resolves to the manifest's `AddItem`. Args are whitespace-split into a comma
// list, and any 0x-prefixed hex arg is wrapped in ref() — in CE a bare hex arg is a form id (an
// item to add, a move target), while counts/scales are decimal and pass through unwrapped.

import "base:runtime"
import "core:strings"
import "core:unicode"

// preprocess rewrites one console line into Lua source (allocated in `alloc`). An unrecognised line
// is returned as-is (a clone), so the REPL always receives Lua.
preprocess :: proc(line: string, alloc := context.allocator) -> string {
	trimmed := strings.trim_space(line)
	if trimmed == "" {
		return strings.clone("", alloc)
	}

	// Lua-shaped input (a call, an assignment, a method `:`) is never rewritten — `cmd.disable(sel)`,
	// `sel:Disable()`, `x = 5`, `print(1)` all reach the REPL verbatim.
	if strings.contains_rune(trimmed, '(') || strings.contains_rune(trimmed, '=') {
		return strings.clone(trimmed, alloc)
	}

	parts := strings.fields(trimmed, context.temp_allocator)
	head := parts[0]
	args := parts[1:]

	// 1. A CE command alias → cmd.<fn>(args) (selection-defaulted verbs live in the REPL prelude).
	if target, ok := ce_alias(strings.to_lower(head, context.temp_allocator)); ok {
		return strings.concatenate({target, "(", csv_tokens(args, context.temp_allocator), ")"}, alloc)
	}

	// 2. A bare form id (0xHEX) alone → wrap as a ref so it echoes its identity.
	if is_bare_hex(trimmed) {
		return strings.concatenate({"ref(", trimmed, ")"}, alloc)
	}

	// 3. `OBJ.method args…` where OBJ is player | sel | 0xHEX → an obj:method() call.
	if rewritten, ok := rewrite_dotted(head, args, alloc); ok {
		return rewritten
	}

	// 4. Not a CE shape — hand the raw Lua straight to the REPL.
	return strings.clone(trimmed, alloc)
}

// ce_alias maps a bare CE command word to the `cmd` verb it invokes. Only commands with a real
// handler are listed (an unmapped word falls through to plain Lua); the table grows as verbs land.
@(private)
ce_alias :: proc(word: string) -> (target: string, ok: bool) {
	switch word {
	case "tcl":
		return "cmd.noclip", true
	case "tgm":
		return "cmd.god", true
	case "help":
		return "cmd.help", true
	case "disable":
		return "cmd.disable", true
	case "enable":
		return "cmd.enable", true
	case "delete", "markfordelete":
		return "cmd.delete", true
	case "setscale":
		return "cmd.scale", true
	case "getscale":
		return "cmd.getscale", true
	case "moveto":
		return "cmd.moveto", true
	case "prid", "pickrefbyid":
		return "cmd.prid", true
	case "wait":
		return "cmd.wait", true
	case "time":
		return "cmd.time", true
	case "levelup":
		return "cmd.levelup", true
	}
	return "", false
}

// rewrite_dotted turns `obj.method` + args into `obj:method(args)` when `obj` is a known ref handle
// (player/sel) or a 0xHEX form (→ ref(0xHEX)). ok=false leaves the line for the plain-Lua path.
@(private)
rewrite_dotted :: proc(head: string, args: []string, alloc: runtime.Allocator) -> (out: string, ok: bool) {
	dot := strings.index_byte(head, '.')
	if dot <= 0 {
		return "", false
	}
	obj := head[:dot]
	method := head[dot + 1:]
	if !is_ident(method) {
		return "", false
	}

	obj_expr: string
	switch strings.to_lower(obj, context.temp_allocator) {
	case "player":
		obj_expr = "player"
	case "sel":
		obj_expr = "sel"
	case:
		if is_bare_hex(obj) {
			obj_expr = strings.concatenate({"ref(", obj, ")"}, context.temp_allocator)
		} else {
			return "", false
		}
	}

	csv := csv_tokens(args, context.temp_allocator)
	return strings.concatenate({obj_expr, ":", method, "(", csv, ")"}, alloc), true
}

// csv_tokens joins console args with commas, wrapping any bare 0xHEX token in ref() (a hex arg in a
// CE command is a form id; decimals/other literals pass through). Empty slice → "".
@(private)
csv_tokens :: proc(tokens: []string, alloc := context.allocator) -> string {
	if len(tokens) == 0 {
		return ""
	}
	out := make([]string, len(tokens), context.temp_allocator)
	for t, i in tokens {
		out[i] = strings.concatenate({"ref(", t, ")"}, context.temp_allocator) if is_bare_hex(t) else t
	}
	return strings.join(out, ", ", alloc)
}

// is_bare_hex reports whether `s` is exactly a 0x-prefixed hex literal. Requiring the 0x prefix keeps
// it from swallowing plain Lua identifiers / decimals.
@(private)
is_bare_hex :: proc(s: string) -> bool {
	if len(s) < 3 || (s[0] != '0') || (s[1] != 'x' && s[1] != 'X') {
		return false
	}
	for r in s[2:] {
		if !is_hex_digit(r) {
			return false
		}
	}
	return true
}

@(private)
is_ident :: proc(s: string) -> bool {
	if s == "" {
		return false
	}
	for r, i in s {
		if r == '_' || unicode.is_letter(r) || (i > 0 && unicode.is_digit(r)) {
			continue
		}
		return false
	}
	return true
}

@(private)
is_hex_digit :: proc(r: rune) -> bool {
	return (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
}
