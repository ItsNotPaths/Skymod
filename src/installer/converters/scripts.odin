package converters

// PEX -> Lua, once, at install. The engine never reads Papyrus: it loads the Lua this writes
// to <content>/scripts, and mods ship their own Lua. The hand rewrites of latent functions ship
// in the binary and are written beside it (docs/script-api.md section 10).

import "core:fmt"
import "core:hash"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../../formats/bsa"
import "../../formats/pex"
import "../../transpile"

Script_Stats :: struct {
	converted: int,
	failed:    int, // parse failures; the file is skipped
	rewrites:  int,
}

// REWRITES are <name>.patch.lua files; the loader applies each over the transpiled <name>.lua.
REWRITES := #load_directory("../../script/patches")

// SPLIT_LIST names the bodies the transpiler splits at their waits (generated: pexlatent
// --emit-split).
SPLIT_LIST :: #load("split.tsv", string)

// rewrites_hash identifies the shipped rewrites and split list, so an install made with others
// runs again.
rewrites_hash :: proc() -> u64 {
	h := hash.fnv64a(transmute([]u8)string(SPLIT_LIST))
	for f in REWRITES {
		h = hash.fnv64a(transmute([]u8)f.name, h)
		h = hash.fnv64a(f.data, h)
	}
	return h
}

// convert_scripts transpiles every scripts\*.pex in `archives` into <out_dir>/<name>.lua, name
// lowercased. `archives` is in mount order and a later archive's copy wins, the VFS rule: the
// LE DLC archives ship 73 patched copies of base scripts. An archive that will not open is
// skipped with a warning.
convert_scripts :: proc(archives: []string, out_dir: string) -> (st: Script_Stats, ok: bool) {
	os.make_directory_all(out_dir)
	if !os.is_dir(out_dir) {
		log.errorf("scripts: could not create %q", out_dir)
		return st, false
	}

	opened := make([dynamic]bsa.Archive, 0, len(archives))
	defer {
		for &a in opened {bsa.close(&a)}
		delete(opened)
	}
	Source :: struct {arc, entry: int}
	winner := make(map[string]Source) // lowercased stem -> the copy that wins
	defer {
		for k in winner {delete(k)}
		delete(winner)
	}
	for path in archives {
		a, aok := bsa.open(path)
		if !aok {
			log.warnf("scripts: skipping unreadable archive %q", path)
			continue
		}
		append(&opened, a)
		for e, i in a.entries {
			stem, is_script := script_stem(e.path)
			if !is_script {continue}
			_, had := winner[stem]
			winner[stem] = {len(opened) - 1, i} // an existing entry keeps its own key
			if had {
				delete(stem)
			}
		}
	}

	// Parse and transpile allocate freely; a per-file arena keeps the corpus from piling up.
	scratch: virtual.Arena
	if virtual.arena_init_growing(&scratch) != nil {
		return st, false
	}
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)

	opt := transpile.Options{split = transpile.parse_split_list(SPLIT_LIST)}
	defer {
		for k in opt.split {delete(k)}
		delete(opt.split)
	}
	for stem, src in winner {
		defer virtual.arena_free_all(&scratch)
		a := &opened[src.arc]
		data, xok := bsa.extract(a, a.entries[src.entry], context.temp_allocator)
		p, pok := pex.parse(data, context.temp_allocator)
		if !xok || !pok {
			log.warnf("scripts: could not parse %s", a.entries[src.entry].path)
			st.failed += 1
			continue
		}
		for f in REWRITES {
			if strings.equal_fold(f.name, strings.concatenate({stem, ".patch.lua"}, context.temp_allocator)) {
				check_rewrite_pins(&p, f.name, string(f.data))
			}
		}
		lua, _ := transpile.transpile(&p, opt, context.temp_allocator)
		out, _ := filepath.join({out_dir, strings.concatenate({stem, ".lua"}, context.temp_allocator)}, context.temp_allocator)
		if err := os.write_entire_file(out, transmute([]u8)lua); err != nil {
			log.errorf("scripts: could not write %q: %v", out, err)
			return st, false
		}
		st.converted += 1
	}
	for f in REWRITES {
		out, _ := filepath.join({out_dir, f.name}, context.temp_allocator)
		if err := os.write_entire_file(out, f.data); err != nil {
			log.errorf("scripts: could not write %q: %v", out, err)
			return st, false
		}
		st.rewrites += 1
	}
	return st, true
}

// script_stem reads an archive path as a script: "scripts\Foo.pex" -> "foo", owned by the caller.
@(private = "file")
script_stem :: proc(path: string) -> (stem: string, ok: bool) {
	lower := strings.to_lower(path)
	if !strings.has_prefix(lower, "scripts\\") || !strings.has_suffix(lower, ".pex") || strings.count(lower, "\\") != 1 {
		delete(lower)
		return "", false
	}
	stem = strings.clone(lower[len("scripts\\"):len(lower) - len(".pex")])
	delete(lower)
	return stem, true
}

// check_rewrite_pins warns for each body a rewrite was written against ("-- pex: [state.]fn hash"
// header lines) whose code here differs, as LE and SE ship different bodies under one name.
check_rewrite_pins :: proc(p: ^pex.Pex, name, patch: string) {
	PIN :: "-- pex: "
	text := patch
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, PIN) {continue}
		fields := strings.fields(line[len(PIN):], context.temp_allocator)
		if len(fields) != 2 {
			log.warnf("scripts: %s: bad pin line %q", name, line)
			continue
		}
		key, want := fields[0], fields[1]
		state, fn := "", key
		if dot := strings.index_byte(key, '.'); dot >= 0 {state, fn = key[:dot], key[dot + 1:]}
		got, found := u32(0), false
		for &o in p.objects {
			for &s in o.states {
				if !strings.equal_fold(s.name, state) {continue}
				for &f in s.functions {
					if strings.equal_fold(f.name, fn) {got, found = pex.function_hash(&f), true}
				}
			}
		}
		if !found {
			log.warnf("scripts: %s: pinned body %s is not in this game's script", name, key)
		} else if fmt.tprintf("%08x", got) != want {
			log.warnf("scripts: %s: pinned body %s is %08x here, written against %s", name, key, got, want)
		}
	}
}
