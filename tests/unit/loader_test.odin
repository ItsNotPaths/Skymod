package unit_tests

// The script loader's layering (src/script/lua/loader.odin + rt.loader): a base script, then mods
// in order, where a full <name>.lua replaces everything below it and a <name>.patch.lua edits the
// class so far. Hermetic: a temp tree, no game files.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

@(private = "file")
BASE_CHILD :: `local rt = require('skymod.rt')
local C = rt.class("Child", nil)
C.__fn["greet"] = function(self) return "base" end
return C
`

@(private = "file")
PATCH :: `return function(cls)
  local prev = cls.__fn["greet"]
  cls.__fn["greet"] = function(self) return "%s:" .. prev(self) end
end
`

@(private = "file")
write_file :: proc(t: ^testing.T, dir, name, text: string) {
	_ = os.make_directory_all(dir)
	p, _ := filepath.join({dir, name}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(p, transmute([]u8)text) == nil, "write fixture")
}

// greets builds a fresh VM over `dirs` and checks what Child:greet() says ("" when no class loads).
@(private = "file")
greets :: proc(t: ^testing.T, dirs: []string, want: string) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	vm: slua.VM
	testing.expect(t, slua.init(&vm, &reg, script.Call{ws = &ws, db = &db}), "VM init")
	defer slua.destroy(&vm)
	slua.set_script_dirs(&vm, dirs)
	check := fmt.tprintf(`
		local rt = require('skymod.rt')
		local inst = rt.instance(ref(0x1234), "child")
		local got = inst and rt.call(inst, "Greet") or ""
		assert(got === %q, got)`, want)
	testing.expectf(t, slua.do_string(&vm, check), "layers %v should greet %q", dirs, want)
}

@(test)
test_script_layers :: proc(t: ^testing.T) {
	base_tmp, _ := os.temp_dir(context.temp_allocator)
	root, _ := filepath.join({base_tmp, "skymod_loader_test"}, context.temp_allocator)
	os.remove_all(root)
	defer os.remove_all(root)
	dir :: proc(root, name: string) -> string {
		d, _ := filepath.join({root, name}, context.temp_allocator)
		return d
	}
	base, a, b, c, broken := dir(root, "base"), dir(root, "a"), dir(root, "b"), dir(root, "c"), dir(root, "broken")

	write_file(t, base, "child.lua", BASE_CHILD)
	write_file(t, a, "child.patch.lua", fmt_patch("A"))
	write_file(t, b, "Child.lua", `local rt = require('skymod.rt')
local C = rt.class("Child", nil)
C.__fn["greet"] = function(self) return "B" end
return C
`)
	write_file(t, c, "child.patch.lua", fmt_patch("C"))
	write_file(t, broken, "child.patch.lua", "return function(cls) this is not lua")

	greets(t, {base}, "base")
	greets(t, {base, a}, "A:base")
	// B replaces the class outright, dropping A's patch; C then wraps B.
	greets(t, {base, a, b, c}, "C:B")
	// A broken mod file is skipped with a warning; the layers around it still apply.
	greets(t, {base, broken, c}, "C:base")
	// A patch with nothing beneath it defines nothing.
	greets(t, {a}, "")
}

@(private = "file")
fmt_patch :: proc(tag: string) -> string {
	s, _ := strings.replace_all(PATCH, "%s", tag, context.temp_allocator)
	return s
}
