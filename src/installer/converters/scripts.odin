package converters

// PEX -> Lua, once, at install. The engine never reads Papyrus: it loads the Lua this writes
// to <content>/scripts, and mods ship their own Lua.

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
}

// convert_scripts transpiles every scripts\*.pex in `archives` into <out_dir>/<name>.lua, name
// lowercased. `archives` is in mount order and a later archive's copy wins, the VFS rule: the
// LE DLC archives ship 73 patched copies of base scripts. An archive that will not open is
// skipped with a warning.
convert_scripts :: proc(archives: []string, out_dir: string) -> (st: Script_Stats, ok: bool) {
	os.make_directory(out_dir)
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
		lua, _ := transpile.transpile(&p, {}, context.temp_allocator)
		out, _ := filepath.join({out_dir, strings.concatenate({stem, ".lua"}, context.temp_allocator)}, context.temp_allocator)
		if err := os.write_entire_file(out, transmute([]u8)lua); err != nil {
			log.errorf("scripts: could not write %q: %v", out, err)
			return st, false
		}
		st.converted += 1
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
