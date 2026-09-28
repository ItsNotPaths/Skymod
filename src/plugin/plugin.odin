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
	interior: bool,
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
	list:   [dynamic]Plugin, // lowest mod priority first
	owners: map[string]string, // seam -> the path of the plugin that last changed it
}

// load opens every trusted plugin in `dirs`, lowest priority first; in one dir, by name.
load :: proc(p: ^Plugins, dirs: []string, trust: ^Trust) {
	for dir in dirs {
		for path in native_files(dir) {
			if !trusted(trust, path) {
				log.infof("plugin: %s is not trusted; allow its mod's native code in the mod manager", path)
				continue
			}
			lib, ok := dynlib.load_library(path)
			if !ok {
				log.errorf("plugin: cannot load %s: %s", path, dynlib.last_error())
				continue
			}
			append(&p.list, Plugin{strings.clone(path), lib})
			log.infof("plugin: loaded %s", path)
		}
	}
}

// native_files is the plugin files in `dir`, by name. Temp-allocated.
native_files :: proc(dir: string) -> []string {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {return {}}
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	out := make([dynamic]string, 0, len(infos), context.temp_allocator)
	for fi in infos {
		if !strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), EXT) {continue}
		path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		append(&out, path)
	}
	return out[:]
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
			p.owners[name] = pl.path
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
	delete(p.owners)
}

// A plugin that keeps state across saves exports skymod_id (its ID, such as "pluginname.UUID"),
// skymod_save and skymod_load. Saves key its data by that ID.
Id_Proc :: #type proc "c" () -> cstring
Save_Proc :: #type proc "c" (out: [^]u8, cap: int) -> int // the size it needs; written only when that fits in cap
Load_Proc :: #type proc "c" (data: [^]u8, len: int) // len 0: no saved data, start fresh

// save_data puts each saving plugin's data into `blobs` under its ID. The data of plugins that are
// gone stays as it is.
save_data :: proc(p: ^Plugins, blobs: ^map[string][]u8) {
	for pl in p.list {
		id, save, _, ok := saves(pl)
		if !ok {continue}
		n := save(nil, 0)
		data := make([]u8, max(n, 0))
		if n > 0 && save(raw_data(data), n) != n {
			log.errorf("plugin: %s changed its save size while saving; its data is not saved", pl.path)
			delete(data)
			continue
		}
		if old, had := blobs[id]; had {
			delete(old)
			blobs[id] = data
		} else {
			blobs[strings.clone(id)] = data
		}
	}
}

// load_data hands each saving plugin its data from `blobs`, or none.
load_data :: proc(p: ^Plugins, blobs: map[string][]u8) {
	for pl in p.list {
		id, _, load, ok := saves(pl)
		if !ok {continue}
		data := blobs[id]
		load(raw_data(data), len(data))
	}
}

@(private = "file")
saves :: proc(pl: Plugin) -> (id: string, save: Save_Proc, load: Load_Proc, ok: bool) {
	id_sym := dynlib.symbol_address(pl.lib, "skymod_id") or_return
	save_sym := dynlib.symbol_address(pl.lib, "skymod_save") or_return
	load_sym := dynlib.symbol_address(pl.lib, "skymod_load") or_return
	return string((Id_Proc(id_sym))()), Save_Proc(save_sym), Load_Proc(load_sym), true
}

// owner is the plugin that owns a seam, or "built-in".
owner :: proc(p: ^Plugins, seam: string) -> string {
	return p.owners[seam] or_else "built-in"
}
