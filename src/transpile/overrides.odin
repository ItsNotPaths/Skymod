package transpile

// The override registry — the seam between transpiled output and hand-written Lua.
//
// An entry carries no meaning beyond "this one is written by hand". It is keyed by NAME, never
// by an emitted line number: line numbers move whenever the transpiler changes (T2 moved every
// line in the corpus), and a stale entry that split at the wrong place would still produce
// valid Lua. See docs/papyrus-transpiler.md.
//
// Parsing takes a string, not a path — the library does no file IO. The caller reads the file.

import "base:runtime"
import "core:strings"

// Key identifies one overridden function. Every field folds case, because Papyrus identifiers
// do. `state` is empty for the default state — a script may define OnActivate in BOTH the
// default state and a named one, and they are different functions (269 latent functions in the
// base game sit in a named state; 53 of those collide by name with a default-state sibling).
Key :: struct {
	script: string, // source file stem, e.g. "trapfireplate" from TrapFirePlate.psc
	object: string,
	state:  string, // "" = default state
	fn:     string,
}

// Overrides is the parsed registry. Owns its strings; free it with overrides_destroy.
Overrides :: struct {
	scripts:   map[string]bool, // whole-script overrides, by stem
	functions: map[Key]bool,
	allocator: runtime.Allocator,
}

// overrides_parse reads the registry text. One entry per line, '#' starts a comment:
//
//	trapfireplate.TrapFirePlate.removeMyHazard   # one function, default state
//	dunactivator.DunActivator.OnActivate@Busy    # the same name inside a named state
//	audiorepeateractivator01script               # the whole script
//
// A malformed line is reported rather than ignored — a silently dropped entry means a function
// gets transpiled that a human meant to write.
overrides_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	o: Overrides,
	bad_line: int,
	ok: bool,
) {
	context.allocator = allocator
	o.allocator = allocator
	o.scripts = make(map[string]bool)
	o.functions = make(map[Key]bool)

	it := text
	line_no := 0
	for line in strings.split_lines_iterator(&it) {
		line_no += 1
		entry := line
		if i := strings.index_byte(entry, '#'); i >= 0 {
			entry = entry[:i]
		}
		entry = strings.trim_space(entry)
		if entry == "" {
			continue
		}

		// An optional "@state" suffix selects a named state. Absent means the default one.
		state := ""
		if at := strings.index_byte(entry, '@'); at >= 0 {
			state = strings.trim_space(entry[at + 1:])
			entry = strings.trim_space(entry[:at])
			if state == "" {
				overrides_destroy(&o)
				return {}, line_no, false
			}
		}

		n := strings.count(entry, ".")
		switch n {
		case 0:
			if state != "" { // a state qualifier is meaningless on a whole-script entry
				overrides_destroy(&o)
				return {}, line_no, false
			}
			o.scripts[strings.to_lower(entry)] = true
		case 2:
			first := strings.index_byte(entry, '.')
			last := strings.last_index_byte(entry, '.')
			k := Key {
				script = strings.to_lower(entry[:first]),
				object = strings.to_lower(entry[first + 1:last]),
				state  = strings.to_lower(state),
				fn     = strings.to_lower(entry[last + 1:]),
			}
			if k.script == "" || k.object == "" || k.fn == "" {
				// never reached the map
				delete(k.script);delete(k.object);delete(k.state);delete(k.fn)
				overrides_destroy(&o)
				return {}, line_no, false
			}
			o.functions[k] = true
		case:
			overrides_destroy(&o)
			return {}, line_no, false
		}
	}
	return o, 0, true
}

overrides_destroy :: proc(o: ^Overrides) {
	a := o.allocator if o.allocator.procedure != nil else context.allocator
	for k in o.scripts {
		delete(k, a)
	}
	for k in o.functions {
		delete(k.script, a)
		delete(k.object, a)
		delete(k.state, a)
		delete(k.fn, a)
	}
	delete(o.scripts)
	delete(o.functions)
	o^ = {}
}

// overrides_has_script reports whether the whole script is hand-written. `script` is the source
// file stem; case is folded here so callers can pass it raw.
overrides_has_script :: proc(o: ^Overrides, script: string) -> bool {
	if o == nil {
		return false
	}
	buf: [128]u8
	return o.scripts[fold(buf[:], script)]
}

@(private)
overrides_has_fn :: proc(o: ^Overrides, script, object, state, fn: string) -> bool {
	if o == nil {
		return false
	}
	s, ob, st, f: [128]u8
	k := Key{fold(s[:], script), fold(ob[:], object), fold(st[:], state), fold(f[:], fn)}
	return o.functions[k]
}

// fold lowercases into a caller-supplied buffer, so a lookup allocates nothing. A name longer
// than the buffer is truncated, which can only turn a hit into a miss — and no Papyrus
// identifier comes close.
@(private)
fold :: proc(buf: []u8, s: string) -> string {
	n := min(len(s), len(buf))
	for i in 0 ..< n {
		c := s[i]
		buf[i] = c + 32 if c >= 'A' && c <= 'Z' else c
	}
	return string(buf[:n])
}

// script_stem strips a PEX header's source file name down to its key: "TrapFirePlate.psc" becomes
// "TrapFirePlate" without the extension. The lookup folds case.
@(private)
script_stem :: proc(source_file: string) -> string {
	s := source_file
	if i := strings.last_index_any(s, "\\/"); i >= 0 {
		s = s[i + 1:]
	}
	if i := strings.last_index_byte(s, '.'); i > 0 {
		s = s[:i]
	}
	return s
}
