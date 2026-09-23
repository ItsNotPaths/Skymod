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

// set_script_dirs indexes the scripts under `dirs`, given lowest priority first. Calling it again
// replaces the index; classes rt already loaded stay loaded.
set_script_dirs :: proc(vm: ^VM, dirs: []string) {
	free_script_index(vm)
	vm.scripts = make(map[string][dynamic]Script_Layer)
	for dir in dirs {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {
			continue
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
			layers, found := &vm.scripts[stem]
			if !found {
				vm.scripts[strings.clone(stem)] = {}
				layers = &vm.scripts[stem]
			}
			append(layers, Script_Layer{path, patch})
		}
	}
}

@(private)
free_script_index :: proc(vm: ^VM) {
	for name, layers in vm.scripts {
		for l in layers {delete(l.path)}
		delete(layers)
		delete(name)
	}
	delete(vm.scripts)
	vm.scripts = nil
}

// __script_layers(lname) -> { [0] = {path = ..., patch = bool}, ... }, lowest priority first.
@(private)
rt_script_layers :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	layers := vm.scripts[to_string(L, 1)]
	lua.createtable(L, c.int(len(layers)), 0)
	for l, i in layers {
		lua.createtable(L, 0, 2)
		lua.pushstring(L, strings.clone_to_cstring(l.path, context.temp_allocator))
		lua.setfield(L, -2, "path")
		lua.pushboolean(L, b32(l.patch))
		lua.setfield(L, -2, "patch")
		lua.rawseti(L, -2, lua.Integer(i))
	}
	return 1
}
