package script_lua

// Where rt's loader finds a script: every folder that ships it, lowest priority first. Converted
// base scripts come from content/basescripts/scripts, then each enabled mod's scripts/. A
// full <name>.lua replaces everything below it; a <name>.patch.lua is applied to the class so far
// (rt.lua does the layering).

import "core:c"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import lua "../../../vendor/lua"

Script_Layer :: struct {
	path:  string,
	patch: bool,
}

// Content is a folder of definition files beside a mod's scripts, loaded whole at game start.
Content :: enum u8 {
	Effects, // effects/: rt.effect
	Spells,  // spells/: rt.spell
	Powers,  // powers/: rt.power
}

CONTENT_DIRS := [Content]string{.Effects = "effects", .Spells = "spells", .Powers = "powers"}

// set_script_dirs indexes the scripts under `dirs`, given lowest priority first, and the definition
// files in each one's content folders. Calling it again replaces the index; classes rt already
// loaded stay loaded.
set_script_dirs :: proc(vm: ^VM, dirs: []string) {
	free_script_index(vm)
	vm.scripts = make(map[string][dynamic]Script_Layer)
	for &index in vm.content {index = make(map[string][dynamic]Script_Layer)}
	for dir in dirs {
		index_layers(&vm.scripts, dir)
		for sub, kind in CONTENT_DIRS {
			d, _ := filepath.join({dir, sub}, context.temp_allocator)
			index_layers(&vm.content[kind], d)
		}
	}
}

@(private)
index_layers :: proc(index: ^map[string][dynamic]Script_Layer, dir: string) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	// Name order puts foo.lua ahead of foo.patch.lua, so a mod's own patch lands on its own file.
	slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	for fi in infos {
		lower := strings.to_lower(fi.name, context.temp_allocator)
		patch := strings.has_suffix(lower, ".patch.lua")
		if !patch && !strings.has_suffix(lower, ".lua") {
			continue
		}
		stem := strings.trim_suffix(lower, ".patch.lua" if patch else ".lua")
		path, _ := filepath.join({dir, fi.name})
		layers, found := &index[stem]
		if !found {
			index[strings.clone(stem)] = {}
			layers = &index[stem]
		}
		append(layers, Script_Layer{path, patch})
	}
}

@(private)
free_script_index :: proc(vm: ^VM) {
	for index in ([]^map[string][dynamic]Script_Layer{&vm.scripts, &vm.content[.Effects], &vm.content[.Spells], &vm.content[.Powers]}) {
		for name, layers in index {
			for l in layers {delete(l.path)}
			delete(layers)
			delete(name)
		}
		delete(index^)
		index^ = nil
	}
}

// __script_layers(lname) -> { [0] = {path = ..., patch = bool}, ... }, lowest priority first.
@(private)
rt_script_layers :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	push_layers(L, vm.scripts[to_string(L, 1)][:])
	return 1
}

// __content_files(folder) -> { [0] = { name = ..., layers = {...} }, ... }: every definition file
// in that content folder ("effects", "spells"), in name order.
@(private)
rt_content_files :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	kind: Content
	for sub, k in CONTENT_DIRS {
		if sub == to_string(L, 1) {kind = k}
	}
	files := vm.content[kind]
	names := make([dynamic]string, 0, len(files), context.temp_allocator)
	for name in files {append(&names, name)}
	slice.sort(names[:])
	lua.createtable(L, c.int(len(names)), 0)
	for name, i in names {
		lua.createtable(L, 0, 2)
		lua.pushstring(L, strings.clone_to_cstring(name, context.temp_allocator))
		lua.setfield(L, -2, "name")
		push_layers(L, files[name][:])
		lua.setfield(L, -2, "layers")
		lua.rawseti(L, -2, lua.Integer(i))
	}
	return 1
}

@(private)
push_layers :: proc(L: ^lua.State, layers: []Script_Layer) {
	lua.createtable(L, c.int(len(layers)), 0)
	for l, i in layers {
		lua.createtable(L, 0, 2)
		lua.pushstring(L, strings.clone_to_cstring(l.path, context.temp_allocator))
		lua.setfield(L, -2, "path")
		lua.pushboolean(L, b32(l.patch))
		lua.setfield(L, -2, "patch")
		lua.rawseti(L, -2, lua.Integer(i))
	}
}
