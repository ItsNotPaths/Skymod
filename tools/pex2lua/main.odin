package main

// pex2lua — the standalone driver for src/transpile.
//
//   odin run tools/pex2lua -- <script.pex>                      # one script to stdout
//   odin run tools/pex2lua -- <dir> -o <outdir>                 # every .pex under a folder
//   odin run tools/pex2lua -- <archive.bsa> -o <outdir>         # every scripts\*.pex in a BSA
//   odin run tools/pex2lua -- <...> --lines                     # annotate with source lines
//   odin run tools/pex2lua -- <...> --no-inline                 # stop at T1 (diff vs T2)
//   odin run tools/pex2lua -- <...> --split <list.tsv>          # split the listed bodies (S6)
//
// The corpus harness: point it at SE's Skyrim - Misc.bsa (LE splits the same corpus over
// Misc + the three DLC archives), then check every emitted file with
// `luac -p`. Whole-corpus numbers live in docs/papyrus-transpiler.md.
//
// No SDL — pure formats code, runs headless.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../../src/formats/bsa"
import "../../src/formats/pex"
import "../../src/transpile"

Totals :: struct {
	using stats: transpile.Stats,
	files:       int,
	ok:          int,
	failed:      int,
}

Job :: struct {
	name: string, // basename without extension, lowercased
	data: []u8,
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln(
			"usage: pex2lua <script.pex | dir | archive.bsa> [-o <outdir>]" +
			" [--lines] [--no-inline] [--split <list.tsv>]",
		)
		os.exit(2)
	}
	path := os.args[1]
	outdir, split_list := "", ""
	for a, i in os.args {
		if a == "-o" && i + 1 < len(os.args) {
			outdir = os.args[i + 1]
		}
		if a == "--split" && i + 1 < len(os.args) {
			split_list = os.args[i + 1]
		}
	}
	opt := transpile.Options {
		line_comments = slice.contains(os.args, "--lines"),
		no_inline     = slice.contains(os.args, "--no-inline"),
	}
	if split_list != "" {
		text, err := os.read_entire_file(split_list, context.allocator)
		if err != nil {
			fmt.eprintfln("could not read %s: %v", split_list, err)
			os.exit(1)
		}
		opt.split = transpile.parse_split_list(string(text))
	}

	jobs := make([dynamic]Job)
	defer {
		for j in jobs {
			delete(j.data)
			delete(j.name)
		}
		delete(jobs)
	}

	switch {
	case strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".bsa"):
		collect_bsa(&jobs, path)
	case os.is_dir(path):
		collect_dir(&jobs, path)
	case:
		collect_file(&jobs, path)
	}
	if len(jobs) == 0 {
		fmt.eprintfln("no .pex found at %s", path)
		os.exit(1)
	}
	if outdir != "" {
		os.make_directory(outdir)
	}

	total: Totals
	for j in jobs {
		total.files += 1
		p, pok := pex.parse(j.data)
		defer pex.destroy(&p)
		if !pok {
			total.failed += 1
			fmt.eprintfln("  PARSE FAIL %s", j.name)
			continue
		}
		src, st := transpile.transpile(&p, opt)
		defer delete(src)
		total.ok += 1
		accumulate(&total, st)

		if outdir != "" {
			out := fmt.tprintf("%s/%s.lua", outdir, j.name)
			if os.write_entire_file(out, transmute([]u8)src) != nil {
				fmt.eprintfln("  WRITE FAIL %s", out)
			}
		} else if len(jobs) == 1 {
			fmt.print(src)
		}
		free_all(context.temp_allocator)
	}
	report(total)
}

@(private)
accumulate :: proc(t: ^Totals, s: transpile.Stats) {
	t.objects += s.objects
	t.functions += s.functions
	t.natives += s.natives
	t.bodied += s.bodied
	t.with_lines += s.with_lines
	t.instructions += s.instructions
	t.statements += s.statements
	t.labels += s.labels
	t.dropped_cast += s.dropped_cast
	t.bare_calls += s.bare_calls
	t.inlined += s.inlined
	t.split += s.split
	t.max_locals = max(t.max_locals, s.max_locals)
}

@(private)
report :: proc(t: Totals) {
	pct :: proc(n, d: int) -> f64 {
		return d > 0 ? 100.0 * f64(n) / f64(d) : 0
	}
	fmt.eprintln()
	fmt.eprintfln("files        %d (%d ok, %d failed)", t.files, t.ok, t.failed)
	fmt.eprintfln("objects      %d", t.objects)
	fmt.eprintfln("functions    %d (%d native decls)", t.functions, t.natives)
	fmt.eprintfln("bodied fns   %d", t.bodied)
	fmt.eprintfln("with lines   %d (%.1f%% of bodied)", t.with_lines, pct(t.with_lines, t.bodied))
	fmt.eprintfln("instructions %d", t.instructions)
	fmt.eprintfln("statements   %d", t.statements)
	fmt.eprintfln("labels       %d", t.labels)
	fmt.eprintfln("split        %d bodies", t.split)
	fmt.eprintfln("max locals   %d (lua 5.4 caps at 200)", t.max_locals)
	fmt.eprintfln("T1 dropped   %d self-casts", t.dropped_cast)
	fmt.eprintfln("T1 bare      %d calls to ::NoneVar", t.bare_calls)
	fmt.eprintfln("T2 inlined   %d temps folded into their reader", t.inlined)
}

// stem lowercases a path's basename and strips its extension — the output file's name.
@(private)
stem :: proc(path: string) -> string {
	s := path
	if i := strings.last_index_any(s, "\\/"); i >= 0 {
		s = s[i + 1:]
	}
	if i := strings.last_index_byte(s, '.'); i > 0 {
		s = s[:i]
	}
	return strings.to_lower(s)
}

@(private)
is_pex :: proc(path: string) -> bool {
	low := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(low, ".pex")
}

@(private)
collect_file :: proc(jobs: ^[dynamic]Job, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("failed to read %s", path)
		return
	}
	append(jobs, Job{name = stem(path), data = data})
}

@(private)
collect_dir :: proc(jobs: ^[dynamic]Job, dir: string) {
	fis, err := os.read_directory_by_path(dir, -1, context.allocator)
	if err != nil {
		fmt.eprintfln("failed to list %s", dir)
		return
	}
	defer os.file_info_slice_delete(fis, context.allocator)
	for fi in fis {
		switch {
		case fi.type == .Directory:
			collect_dir(jobs, fi.fullpath)
		case is_pex(fi.name):
			collect_file(jobs, fi.fullpath)
		}
	}
}

@(private)
collect_bsa :: proc(jobs: ^[dynamic]Job, path: string) {
	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA %s", path)
		return
	}
	defer bsa.close(&arc)
	for e in arc.entries {
		if !is_pex(e.path) {
			continue
		}
		data, dok := bsa.extract(&arc, e)
		if !dok {
			fmt.eprintfln("  EXTRACT FAIL %s", e.path)
			continue
		}
		append(jobs, Job{name = stem(e.path), data = data})
		free_all(context.temp_allocator)
	}
}
