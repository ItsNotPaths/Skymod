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
//   odin run tools/pexdump -- <archive.bsa> --dis <script>  # disassemble one script's bytecode
//
// No SDL — pure formats code, runs headless.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../../src/formats/bsa"
import "../../src/formats/pex"

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
	if slice.contains(os.args, "--emit-manifest") {
		emit_manifest(path) // generates src/script/natives_manifest.odin on stdout
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
}

emit_manifest :: proc(path: string) {
	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA: %s", path)
		os.exit(1)
	}
	defer bsa.close(&arc)

	seen := make(map[string]Mentry) // lower "class.fn" -> canonical entry (heap-owned strings)
	for e in arc.entries {
		lower := strings.to_lower(e.path, context.temp_allocator)
		if !strings.has_prefix(lower, "scripts\\") || !strings.has_suffix(lower, ".pex") {
			continue
		}
		data, xok := bsa.extract(&arc, e, context.temp_allocator)
		if !xok {free_all(context.temp_allocator);continue}
		p, pok := pex.parse(data, context.temp_allocator)
		if !pok {free_all(context.temp_allocator);continue}

		for s in pex.collect_signatures(&p, context.temp_allocator) {
			if !s.is_native {continue}
			k := strings.to_lower(fmt.tprintf("%s.%s", s.class, s.fn), context.temp_allocator)
			if k in seen {continue}
			seen[strings.clone(k)] = Mentry {
				class     = strings.clone(s.class),
				fn        = strings.clone(s.fn),
				ret       = strings.clone(s.ret),
				nparams   = s.nparams,
				is_global = s.is_global,
			}
		}
		free_all(context.temp_allocator)
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
	fmt.println("// GENERATED — DO NOT EDIT BY HAND. The native API surface declared by base-game")
	fmt.println("// scripts (Skyrim - Misc.bsa): identifier + type names only (facts — proc names")
	fmt.println("// aren't copyrightable), bodies reimplemented in natives.odin. Regenerate with:")
	fmt.println("//   odin run tools/pexdump -- \"<...>/Skyrim - Misc.bsa\" --emit-manifest > src/script/natives_manifest.odin")
	fmt.println()
	fmt.println("@(rodata)")
	fmt.println("native_manifest := []Manifest_Entry{")
	for e in list {
		// Braces are emitted via plain print (fmt's format strings treat '{' as a
		// directive opener); identifiers carry no quotes, so manual quoting is safe.
		fmt.print("\t{")
		fmt.printf("\"%s\", \"%s\", \"%s\", %d, %v", e.class, e.fn, e.ret, e.nparams, e.is_global)
		fmt.println("},")
	}
	fmt.println("}")
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
					fmt.printfln("\n  [%s] %s(%d params, %d locals) -> %s",
						st.name == "" ? "default" : st.name, f.name, len(f.params), len(f.locals), f.return_type)
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
