package plugin

// Native mod plugins (.so, .dll) in each mod's native/ folder. A plugin exports one proc per seam
// it changes, named for the seam (for example skymod_detection). The host calls it with the seam's
// version and the seam's table, already filled by the built-in and by lower mods; the plugin
// overwrites the entries it replaces. Only plain data crosses: see Span.

import "core:dynlib"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../formid"

DIR :: "native" // a mod's plugin folder: <mod>/native/<name>.so or .dll
EXT :: ".dll" when ODIN_OS == .Windows else ".so"

// Span is a slice as plain data.
Span :: struct($T: typeid) {
	data: [^]T,
	len:  int,
}

span :: proc "contextless" (s: []$T) -> Span(T) {return {raw_data(s), len(s)}}
items :: proc "contextless" (s: Span($T)) -> []T {return s.data[:s.len]}

Form_ID :: formid.Form_ID

// Actor is one loaded actor in the snapshot that every seam reads, built once a tick.
Actor :: struct {
	id:       Form_ID,
	space:    Form_ID, // its worldspace or interior cell; 0 = none
	pos:      [3]f32,
	speed:    f32, // units/s since the last snapshot
	dead:     bool,
	sneaking: bool,
}

// Seam_Proc is what a plugin exports for a seam. It returns false for a version it does not know.
Seam_Proc :: #type proc "c" (version: u32, table: rawptr) -> b32

Plugin :: struct {
	path: string,
	lib:  dynlib.Library,
}

Plugins :: struct {
	list: [dynamic]Plugin, // lowest mod priority first
}

// (hole plugin-trust-prompt :tags (plugins ui) :sev gap) native code has full trust, but the only gate is the native_plugins setting: nothing asks the user once for each plugin.
// load opens every plugin in `dirs`, lowest priority first; in one dir, by name.
load :: proc(p: ^Plugins, dirs: []string) {
	for dir in dirs {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {continue}
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for fi in infos {
			if !strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), EXT) {continue}
			path, _ := filepath.join({dir, fi.name})
			lib, ok := dynlib.load_library(path)
			if !ok {
				log.errorf("plugin: cannot load %s: %s", path, dynlib.last_error())
				delete(path)
				continue
			}
			append(&p.list, Plugin{path, lib})
			log.infof("plugin: loaded %s", path)
		}
	}
}

// apply lets each plugin that exports `name` change `table`, in mod order. A plugin that refuses
// leaves the table as it was.
apply :: proc(p: ^Plugins, name: string, version: u32, table: ^$T) {
	for pl in p.list {
		sym, found := dynlib.symbol_address(pl.lib, name)
		if !found {continue}
		changed := table^
		if (Seam_Proc(sym))(version, &changed) {
			table^ = changed
			log.infof("plugin: %s changes %s", pl.path, name)
		} else {
			log.warnf("plugin: %s refused %s version %d", pl.path, name, version)
		}
	}
}

destroy :: proc(p: ^Plugins) {
	for pl in p.list {
		dynlib.unload_library(pl.lib)
		delete(pl.path)
	}
	delete(p.list)
}
