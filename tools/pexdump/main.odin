package main

// Dev harness (not shipped): exercise the PEX reader against the REAL compiled
// Papyrus corpus — the only meaningful validation (synthetic fixtures only prove
// self-consistency). Prints structural METADATA only (counts, object/function
// signatures, opcode histograms) — never copyrighted source text; PEX carries no
// source anyway (Skyrim ships .pex, not .psc).
//
//   odin run tools/pexdump -- <script.pex>            # one script: header + signatures
//   odin run tools/pexdump -- <archive.bsa>           # whole corpus: parse-rate + call histogram
//   odin run tools/pexdump -- <archive.bsa> --sigs    # + dump every native signature
//   odin run tools/pexdump -- <archive.bsa> --top N   # top-N call targets (default 40)
//   odin run tools/pexdump -- <archive.bsa> --dis <script>  # disassemble one script's bytecode, with each body's pin hash
//   odin run tools/pexdump -- --emit-manifest <LE root> <SE root>  # regenerate the native manifest
//   odin run tools/pexdump -- --emit-params <psc dir>              # regenerate argument defaults (params.lua)
//
// No SDL — pure formats code, runs headless.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../../src/formats/bsa"
import "../../src/formats/pex"
import "../../src/installer"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: pexdump <script.pex | archive.bsa> [--sigs] [--top N]")
		os.exit(2)
	}
	path := os.args[1]
	dis_name := ""
	for a, i in os.args {
		if a == "--dis" && i + 1 < len(os.args) {dis_name = os.args[i + 1]}
	}
	if path == "--emit-manifest" {
		emit_manifest(os.args[2:]) // generates src/script/natives_manifest.odin on stdout
	} else if path == "--emit-params" && len(os.args) >= 3 {
		emit_params(os.args[2]) // generates src/script/lua/params.lua on stdout
	} else if dis_name != "" {
		dis_mode(path, dis_name)
	} else if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".bsa") {
		corpus_mode(path)
	} else {
		single_mode(path)
	}
}

// ── manifest generator ───────────────────────────────────────────────────────
// Emits the native API-surface manifest as a package-script Odin source file
// (stdout; redirect to src/script/natives_manifest.odin). Identifier + type names
// only — facts, not copyrightable expression; bodies are reimplemented in
// natives.odin. Dedups by lower-cased class.fn, keeps the declaration casing.

Mentry :: struct {
	class:     string,
	fn:        string,
	ret:       string,
	nparams:   int,
	is_global: bool,
	latent:    bool,
	editions:  bit_set[installer.Edition],
}

emit_manifest :: proc(roots: []string) {
	seen := make(map[string]Mentry) // lower "class.fn" -> first declaration seen (heap-owned strings)
	have: bit_set[installer.Edition]
	mismatches := 0
	for root in roots {
		ed, _ := installer.detect_edition(root)
		if ed == .Unknown {
			fmt.eprintfln("not a Skyrim install (no TESV.exe or SkyrimSE.exe): %s", root)
			os.exit(1)
		}
		have += {ed}
		// Heap, not temp: scan_natives frees temp per file.
		pattern, _ := filepath.join({root, "Data", "*.bsa"})
		bsas, _ := filepath.glob(pattern)
		for path in bsas {
			mismatches += scan_natives(path, ed, &seen)
		}
	}
	if have != {.LE, .SE} {
		fmt.eprintln("emit-manifest needs one LE root and one SE root, or the edition tags are wrong")
		os.exit(1)
	}
	if mismatches > 0 {
		fmt.eprintfln("emit-manifest: %d natives are declared differently by LE and SE", mismatches)
		os.exit(1)
	}

	list := make([dynamic]Mentry, 0, len(seen))
	for _, v in seen {append(&list, v)}
	slice.sort_by(list[:], proc(a, b: Mentry) -> bool {
		al := strings.to_lower(a.class, context.temp_allocator)
		bl := strings.to_lower(b.class, context.temp_allocator)
		if al != bl {return al < bl}
		return strings.to_lower(a.fn, context.temp_allocator) < strings.to_lower(b.fn, context.temp_allocator)
	})

	fmt.eprintfln("emit-manifest: %d distinct natives", len(list))
	fmt.println("package script")
	fmt.println()
	fmt.println("// GENERATED — DO NOT EDIT BY HAND. The native API surface declared by the base-game")
	fmt.println("// scripts of LE and SE together: identifier + type names only (facts — proc names")
	fmt.println("// aren't copyrightable), bodies reimplemented in natives.odin. A trailing comment")
	fmt.println("// marks a native only one edition declares. Regenerate with:")
	fmt.println("//   odin run tools/pexdump -- --emit-manifest <LE root> <SE root> > src/script/natives_manifest.odin")
	fmt.println()
	fmt.println("@(rodata)")
	fmt.println("native_manifest := []Manifest_Entry{")
	for e in list {
		// Braces are emitted via plain print (fmt's format strings treat '{' as a
		// directive opener); identifiers carry no quotes, so manual quoting is safe.
		fmt.print("\t{")
		fmt.printf("\"%s\", \"%s\", \"%s\", %d, %v, %v", e.class, e.fn, e.ret, e.nparams, e.is_global, e.latent)
		fmt.print("},")
		if e.editions != {.LE, .SE} {
			fmt.printf(" // %v only", e.editions == {.LE} ? "LE" : "SE")
		}
		fmt.println()
	}
	fmt.println("}")
}

// scan_natives adds every native one archive declares to `seen`, tagged with its edition.
// Returns how many disagree in signature with an earlier declaration.
scan_natives :: proc(path: string, ed: installer.Edition, seen: ^map[string]Mentry) -> (mismatches: int) {
	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA: %s", path)
		os.exit(1)
	}
	defer bsa.close(&arc)

	for e in arc.entries {
		defer free_all(context.temp_allocator)
		lower := strings.to_lower(e.path, context.temp_allocator)
		if !strings.has_prefix(lower, "scripts\\") || !strings.has_suffix(lower, ".pex") {continue}
		data, xok := bsa.extract(&arc, e, context.temp_allocator)
		if !xok {continue}
		p, pok := pex.parse(data, context.temp_allocator)
		if !pok {continue}

		for s in pex.collect_signatures(&p, context.temp_allocator) {
			if !s.is_native {continue}
			k := strings.to_lower(fmt.tprintf("%s.%s", s.class, s.fn), context.temp_allocator)
			if prev, found := &seen[k]; found {
				prev.editions += {ed}
				if !strings.equal_fold(prev.ret, s.ret) || prev.nparams != s.nparams || prev.is_global != s.is_global {
					fmt.eprintfln("signature mismatch: %s.%s (%s)", s.class, s.fn, path)
					mismatches += 1
				}
				continue
			}
			seen[strings.clone(k)] = Mentry {
				class     = strings.clone(s.class),
				fn        = strings.clone(s.fn),
				ret       = strings.clone(s.ret),
				nparams   = s.nparams,
				is_global = s.is_global,
				latent    = pex.is_latent(s.class, s.fn),
				editions  = {ed},
			}
		}
	}
	return
}

// ── single .pex ──────────────────────────────────────────────────────────────

single_mode :: proc(path: string) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("failed to read: %s", path)
		os.exit(1)
	}
	defer delete(data)

	p, ok := pex.parse(data)
	defer pex.destroy(&p)
	if !ok {
		fmt.eprintfln("PARSE FAILED (got %d objects before the stream went bad)", len(p.objects))
		os.exit(1)
	}

	fmt.printfln("source: %s", p.source_file)
	fmt.printfln("version: %d.%d  game: %d  debug: %v  strings: %d  objects: %d",
		p.major, p.minor, p.game_id, p.has_debug, len(p.string_table), len(p.objects))
	for &o in p.objects {
		fmt.printfln("\nobject %s%s", o.name, o.parent != "" ? fmt.tprintf(" extends %s", o.parent) : "")
		fmt.printfln("  %d vars, %d props, %d states", len(o.variables), len(o.properties), len(o.states))
		for &st in o.states {
			name := st.name == "" ? "(default)" : st.name
			for &f in st.functions {
				kind := f.is_native ? (f.is_global ? "native global" : "native") : (f.is_global ? "global" : "")
				fmt.printfln("    [%s] %s %s(%d) -> %s %s", name, o.name, f.name, len(f.params), f.return_type, kind)
			}
		}
	}
}

// ── disassembly (one script out of a BSA) ────────────────────────────────────
// Instruction-level listing (CK Papyrus-assembly style) — the transpiler dev view.

dis_mode :: proc(path, name: string) {
	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA: %s", path)
		os.exit(1)
	}
	defer bsa.close(&arc)

	want := strings.to_lower(fmt.tprintf("scripts\\%s.pex", name), context.temp_allocator)
	for e in arc.entries {
		if strings.to_lower(e.path, context.temp_allocator) != want {continue}
		data, xok := bsa.extract(&arc, e, context.temp_allocator)
		if !xok {break}
		p, pok := pex.parse(data, context.temp_allocator)
		if !pok {
			fmt.eprintln("parse failed")
			os.exit(1)
		}
		for &o in p.objects {
			fmt.printfln("object %s extends %s  (auto state: %s)", o.name, o.parent, o.auto_state)
			for &v in o.variables {
				fmt.printfln("  var %s %s", v.type_name, v.name)
			}
			for &pr in o.properties {
				fmt.printfln("  prop %s %s%s", pr.type_name, pr.name, pr.auto_var != "" ? fmt.tprintf(" -> %s", pr.auto_var) : "")
			}
			for &st in o.states {
				for &f in st.functions {
					if f.is_native || len(f.instructions) == 0 {continue}
					fmt.printfln("\n  [%s] %s(%d params, %d locals) -> %s  pin %08x",
						st.name == "" ? "default" : st.name, f.name, len(f.params), len(f.locals), f.return_type, pex.function_hash(&f))
					for pv in f.params {fmt.printfln("      param %s %s", pv.type_name, pv.name)}
					for lv in f.locals {fmt.printfln("      local %s %s", lv.type_name, lv.name)}
					for ins, idx in f.instructions {
						b := strings.builder_make(context.temp_allocator)
						for a in ins.args {
							strings.write_byte(&b, ' ')
							switch a.kind {
							case .Null:
								strings.write_string(&b, "none")
							case .Identifier:
								strings.write_string(&b, a.str)
							case .String:
								fmt.sbprintf(&b, "%q", a.str)
							case .Integer:
								fmt.sbprintf(&b, "%d", a.i)
							case .Float:
								fmt.sbprintf(&b, "%.3f", a.f)
							case .Bool:
								fmt.sbprintf(&b, "%v", a.b)
							}
						}
						fmt.printfln("    %3d  %-18v%s", idx, ins.op, strings.to_string(b))
					}
				}
			}
		}
		return
	}
	fmt.eprintfln("script not found in archive: %s", want)
}

// ── BSA corpus ───────────────────────────────────────────────────────────────

Stats :: struct {
	scripts:    int,
	parsed:     int,
	failed:     int,
	objects:    int,
	functions:  int,
	natives:    int,
	fail_names: [dynamic]string,
}

corpus_mode :: proc(path: string) {
	dump_sigs := slice.contains(os.args, "--sigs")
	top_n := 40
	for i in 2 ..< len(os.args) {
		if os.args[i] == "--top" && i + 1 < len(os.args) {
			if v, ok := strconv.parse_int(os.args[i + 1]); ok {top_n = v}
		}
	}

	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA: %s", path)
		os.exit(1)
	}
	defer bsa.close(&arc)

	stats: Stats
	counts := make(map[string]int) // call target -> count; keys heap-owned (survive each file)

	for e in arc.entries {
		lower := strings.to_lower(e.path, context.temp_allocator)
		if !strings.has_prefix(lower, "scripts\\") || !strings.has_suffix(lower, ".pex") {
			continue
		}
		stats.scripts += 1

		data, xok := bsa.extract(&arc, e, context.temp_allocator)
		if !xok {
			stats.failed += 1
			append(&stats.fail_names, strings.clone(e.path))
			free_all(context.temp_allocator)
			continue
		}

		p, pok := pex.parse(data, context.temp_allocator)
		if !pok {
			stats.failed += 1
			append(&stats.fail_names, strings.clone(e.path))
			free_all(context.temp_allocator)
			continue
		}
		stats.parsed += 1
		stats.objects += len(p.objects)
		for &o in p.objects {
			for &st in o.states {
				stats.functions += len(st.functions)
				for &f in st.functions {
					if f.is_native {stats.natives += 1}
					if dump_sigs && f.is_native {
						fmt.printfln("native  %s.%s(%d) -> %s%s",
							o.name, f.name, len(f.params), f.return_type, f.is_global ? "  [global]" : "")
					}
				}
			}
		}
		// Keys cloned into the default heap allocator so they outlive this file.
		pex.tally_calls(&p, &counts, context.allocator)
		free_all(context.temp_allocator)
	}

	fmt.printfln("\n=== %s ===", path)
	fmt.printfln("scripts:    %d", stats.scripts)
	fmt.printfln("parsed:     %d", stats.parsed)
	fmt.printfln("failed:     %d", stats.failed)
	fmt.printfln("objects:    %d", stats.objects)
	fmt.printfln("functions:  %d", stats.functions)
	fmt.printfln("natives:    %d  (declared engine API surface)", stats.natives)
	fmt.printfln("call sites: %d distinct targets", len(counts))

	if stats.failed > 0 {
		fmt.printfln("\nfailures (first 20):")
		for name, i in stats.fail_names {
			if i >= 20 {break}
			fmt.printfln("  %s", name)
		}
	}

	// Top-N call targets — the implement-hot-set priority order for the registry.
	Pair :: struct {
		key:   string,
		count: int,
	}
	pairs := make([dynamic]Pair, 0, len(counts))
	for k, v in counts {
		append(&pairs, Pair{k, v})
	}
	slice.sort_by(pairs[:], proc(a, b: Pair) -> bool {return a.count > b.count})

	fmt.printfln("\ntop %d call targets (callstatic = Class.fn, <obj>/<parent> = instance):", top_n)
	for pr, i in pairs {
		if i >= top_n {break}
		fmt.printfln("  %6d  %s", pr.count, pr.key)
	}
}

// ── argument defaults ────────────────────────────────────────────────────────
// Emits skymod.params: for every function declared with a default argument, its parameters in
// order with their default values (docs/script-api.md section 1), natives and script functions in
// two tables. Read from the Creation Kit's .psc sources (the .pex does not keep defaults: the
// compiler writes them into each call). Parameter names and literal defaults only.

emit_params :: proc(dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fmt.eprintfln("emit-params: cannot read %s", dir)
		os.exit(1)
	}
	natives, scripts: map[string]string // "class.fn" -> line; a function declared in several states is one entry
	for fi in infos {
		if !strings.has_suffix(strings.to_lower(fi.name), ".psc") {continue}
		p, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		data, rerr := os.read_entire_file(p, context.allocator)
		if rerr != nil {continue}
		// A trailing backslash continues a declaration on the next line.
		src, _ := strings.replace_all(string(data), "\\\r\n", " ", context.temp_allocator)
		src, _ = strings.replace_all(src, "\\\n", " ", context.temp_allocator)
		class := ""
		for line in strings.split_lines(src, context.temp_allocator) {
			l := strings.trim_space(line)
			low := strings.to_lower(l, context.temp_allocator)
			if strings.has_prefix(low, "scriptname ") {
				class = strings.fields(l, context.temp_allocator)[1]
				continue
			}
			open := strings.index(low, "function ")
			close := strings.last_index(l, ")")
			// a declaration: nothing or one return type before the keyword
			if class == "" || open < 0 || close < open || len(strings.fields(l[:open], context.temp_allocator)) > 1 {continue}
			head := l[open + len("function "):close]
			paren := strings.index(head, "(")
			if paren < 0 {continue}
			entry, ok := param_entry(class, strings.trim_space(head[:paren]), head[paren + 1:])
			if !ok {continue}
			key := entry[:strings.index(entry, "=")]
			table := strings.contains(low[close:], "native") ? &natives : &scripts
			if key not_in table {table[strings.clone(key)] = entry}
		}
		free_all(context.temp_allocator)
	}
	fmt.eprintfln("emit-params: %d natives and %d script functions with defaults", len(natives), len(scripts))
	fmt.println("-- GENERATED — DO NOT EDIT BY HAND. Each function declared with a default argument: its")
	fmt.println("-- parameters in order, { name } required or { name, default }. Regenerate with:")
	fmt.println("--   odin run tools/pexdump -- --emit-params <extracted Scripts.zip dir> > src/script/lua/params.lua")
	fmt.println("return {")
	emit_table("natives", natives)
	emit_table("scripts", scripts)
	fmt.println("}")
}

emit_table :: proc(name: string, table: map[string]string) {
	lines := make([dynamic]string, context.temp_allocator)
	for _, e in table {append(&lines, e)}
	slice.sort(lines[:])
	fmt.printfln("%s = {{", name)
	for e in lines {fmt.println(e)}
	fmt.println("},")
}

// param_entry is one function's Lua line, or false when none of its parameters has a default.
param_entry :: proc(class, fn, params: string) -> (string, bool) {
	b := strings.builder_make()
	fmt.sbprintf(&b, "\t[\"%s.%s\"] = {{ ", strings.to_lower(class), strings.to_lower(fn))
	any_default := false
	for raw in strings.split(params, ",", context.temp_allocator) {
		param := strings.trim_space(raw)
		if param == "" {continue}
		name_part, eq, default_part := strings.partition(param, "=")
		fields := strings.fields(strings.trim_space(name_part), context.temp_allocator)
		if len(fields) < 2 {return "", false}
		if eq == "" {
			fmt.sbprintf(&b, "{{ \"%s\" }}, ", fields[1])
			continue
		}
		any_default = true
		fmt.sbprintf(&b, "{{ \"%s\", %s }}, ", fields[1], lua_literal(strings.trim_space(default_part)))
	}
	strings.write_string(&b, "},")
	return strings.to_string(b), any_default
}

// lua_literal turns a Papyrus default into Lua: numbers and quoted strings as written, booleans lowercase.
lua_literal :: proc(v: string) -> string {
	switch strings.to_lower(v, context.temp_allocator) {
	case "true":
		return "true"
	case "false":
		return "false"
	case "none":
		return "None"
	}
	return v
}
