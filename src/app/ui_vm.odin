package main

// The PRE-WORLD UI runtime: a PERSISTENT Lua VM for the main menu / mod manager / load screen, plus
// the thin Odin↔Lua contract that drives it. Odin stays a generic engine — each frame it asks Lua
// for the composed tree (ui._frame), routes raw input to whichever node was activated (the menu loop
// in menu.odin), tells Lua which action fired (ui_vm_dispatch), exposes which node is focused
// (ui_vm_set_focus, so widgets style themselves), and reads back a result verb (ui_vm_take_result).
// It knows NOTHING about specific buttons, dialogs, or the save list — those live entirely in Lua.
//
// This VM is SEPARATE from the gameplay/script_lua VM by design: it runs before any gamedb/worldstate
// exists, so it has nothing to dispatch into the script registry. IN-WORLD UI (HUD, inventory,
// dialogue — UI that reads/mutates world state) is the opposite case and will instead drive the same
// VM-agnostic `ui` substrate from the gameplay VM, through the registry's native_call chokepoint. The
// split is along the world-context boundary, not UI-vs-gameplay (see src/script/lua/lua.odin).
//
// Engine state the pre-world UI needs is SURFACED to Lua as callable Odin procs (the `engine` table —
// the same "host call from Lua" pattern as the gameplay registry), not pushed in as globals. The menu
// calls engine.list_saves()/engine.save_exists() itself when it builds the Load panel.

import "core:c"
import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:os"
import "base:runtime"
import "core:strings"
import lua "vendor:lua/5.4"
import "../ui"
import "../vfs"
import "../worldstate"

// UI_UPVAL is lua_upvalueindex(1) — the closure upvalue holding the ^UI_VM for the engine.* host
// procs (the binding doesn't expose the macro, so derive it from REGISTRYINDEX, as script_lua does).
@(private = "file")
UI_UPVAL :: lua.REGISTRYINDEX - 1

// UI_VM is the player UI's Lua state + the host data its engine.* procs read.
UI_VM :: struct {
	L:             ^lua.State,
	base:          string,          // install base (for engine.list_saves)
	vf:            ^vfs.VFS,         // the menu's mounted VFS (mods > content > vanilla) for asset reads
	host_ctx:      runtime.Context, // captured per entry so the "c"-callconv host procs can alloc/log
	saves_checked: bool,            // engine.save_exists is polled every frame — cache the scan result
	has_saves:     bool,            // (no save can appear while we're sitting in the main menu)
	credits:       []string,        // engine.credits lines, parsed once + cached (polled every scroll frame)
	credits_loaded: bool,
}

// ui_vm_open builds the VM into the caller-owned `vm` (a POINTER, so the engine.* host closures can
// capture a STABLE ^UI_VM as their upvalue — returning by value would dangle that pointer). Opens
// libs, installs the engine host API, runs the framework files (constructors + interaction API) and
// the screen (which registers its view via ui.screen). `dir` is the on-disk UI lua root
// (content/baseui/lua); missing files fall back to the embedded copies. On failure the VM is closed.
ui_vm_open :: proc(vm: ^UI_VM, base: string, v: ^vfs.VFS, dir, screen_rel: string) -> bool {
	vm.L = lua.L_newstate()
	if vm.L == nil {
		log.error("ui: L_newstate failed")
		return false
	}
	vm.base = base
	vm.vf = v
	lua.L_openlibs(vm.L)
	install_engine_api(vm)

	for rel in UI_FRAMEWORK {
		src, sok := ui_source(dir, rel)
		if !sok {
			log.errorf("ui: missing framework file %q", rel)
			ui_vm_destroy(vm)
			return false
		}
		if !ui_run_chunk(vm.L, src, rel) {
			ui_vm_destroy(vm)
			return false
		}
	}

	src, sok := ui_source(dir, screen_rel)
	if !sok {
		log.errorf("ui: missing screen %q", screen_rel)
		ui_vm_destroy(vm)
		return false
	}
	if !ui_run_chunk(vm.L, src, screen_rel) {
		ui_vm_destroy(vm)
		return false
	}
	return true
}

ui_vm_destroy :: proc(vm: ^UI_VM) {
	for s in vm.credits {
		delete(s)
	}
	delete(vm.credits)
	vm.credits = nil
	if vm.L != nil {
		lua.close(vm.L)
		vm.L = nil
	}
}

// ui_vm_frame calls ui._frame() and walks the composed tree (base screen + active transients) into a
// ui.Node. The node is allocated in context.allocator; free it with ui.destroy.
ui_vm_frame :: proc(vm: ^UI_VM) -> (root: ui.Node, ok: bool) {
	vm.host_ctx = context
	L := vm.L
	if !push_ui_field(L, "_frame") { // [ui, fn]
		lua.settop(L, -2) // pop ui
		log.error("ui: ui._frame missing")
		return {}, false
	}
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, -3)
		log.error("ui: ui._frame is not a function")
		return {}, false
	}
	if lua.pcall(L, 0, 1, 0) != 0 { // [ui, result] | [ui, errmsg]
		log.errorf("ui: _frame: %s", ui_lua_str(L, -1))
		lua.settop(L, -3)
		return {}, false
	}
	if lua.type(L, -1) != .TABLE {
		log.error("ui: ui._frame must return a node table")
		lua.settop(L, -3)
		return {}, false
	}
	root = ui_parse_node(L, lua.gettop(L))
	lua.settop(L, -3) // pop result + ui
	return root, true
}

// ui_vm_dispatch runs the action that the engine's input routing activated (Lua decides what it
// does: mutate state, spawn a transient, or ui.exit a result verb).
ui_vm_dispatch :: proc(vm: ^UI_VM, action: string) {
	if action == "" {
		return
	}
	vm.host_ctx = context
	call_ui_method_str(vm.L, "dispatch", action)
}

// ui_vm_back asks the UI to go back (Backspace): the framework closes the topmost transient.
ui_vm_back :: proc(vm: ^UI_VM) {
	vm.host_ctx = context
	call_ui_method0(vm.L, "back")
}

// ui_vm_set_time publishes the menu's animation clock (seconds since open) as ui.time, so Lua screens
// can tween (e.g. the Load sidebar's slide-in) without any per-widget engine animation logic.
ui_vm_set_time :: proc(vm: ^UI_VM, t: f64) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return
	}
	lua.pushnumber(L, lua.Number(t))
	lua.setfield(L, -2, "time") // pops value
	lua.settop(L, -2) // pop ui
}

// ui_vm_set_viewport publishes the screen size as ui.vw/ui.vh, so a screen that needs absolute pixels
// (e.g. the credits scroll starting just below the bottom edge) can read it instead of guessing.
ui_vm_set_viewport :: proc(vm: ^UI_VM, w, h: f32) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return
	}
	lua.pushnumber(L, lua.Number(w));lua.setfield(L, -2, "vw")
	lua.pushnumber(L, lua.Number(h));lua.setfield(L, -2, "vh")
	lua.settop(L, -2) // pop ui
}

// ui_vm_get_logo reads the Lua-owned `ui.menu_logo` table (the menu's 3D logo control surface): the
// engine honors `enabled` (draw or skip), `pos` ({x,y} NDC screen offset), `scale`, and `bright`
// (flat-fullbright ambient). Returns present=false when the screen declares no table (mod with no
// logo concept) — the caller keeps its baked Menu_Logo_Cfg defaults. Each field is optional; absent
// fields leave the passed-in value.
ui_vm_get_logo :: proc(vm: ^UI_VM, enabled: ^bool, pos: ^[2]f32, scale, bright, lift: ^f32) -> (present: bool) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	defer lua.settop(L, -2) // pop ui
	if lua.type(L, -1) != .TABLE {
		return false
	}
	lua.getfield(L, -1, "menu_logo") // [ui, menu_logo]
	defer lua.settop(L, -2) // pop menu_logo
	if lua.type(L, -1) != .TABLE {
		return false
	}
	lua.getfield(L, -1, "enabled")
	if t := lua.type(L, -1); t != .NIL && t != .NONE {
		enabled^ = bool(lua.toboolean(L, -1))
	}
	lua.settop(L, -2)
	ui_read_num_field(L, "scale", scale)
	ui_read_num_field(L, "bright", bright)
	ui_read_num_field(L, "lift", lift)
	lua.getfield(L, -1, "pos") // pos = {x, y}
	if lua.type(L, -1) == .TABLE {
		ui_read_num_index(L, 1, &pos[0])
		ui_read_num_index(L, 2, &pos[1])
	}
	lua.settop(L, -2)
	return true
}

// ui_vm_set_focus tells Lua which node id is focused (widgets read ui.focus to style themselves). An
// empty id clears focus.
ui_vm_set_focus :: proc(vm: ^UI_VM, id: string) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return
	}
	if id == "" {
		lua.pushnil(L)
	} else {
		lua.pushstring(L, strings.clone_to_cstring(id, context.temp_allocator))
	}
	lua.setfield(L, -2, "focus") // pops value
	lua.settop(L, -2) // pop ui
}

// ui_vm_take_result reads + clears ui.result (the verb the menu hands back to the boot flow). The
// returned string is temp-allocated.
ui_vm_take_result :: proc(vm: ^UI_VM) -> (string, bool) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		lua.settop(L, -2)
		return "", false
	}
	lua.getfield(L, -1, "result") // [ui, result]
	res: string
	ok: bool
	if lua.type(L, -1) == .STRING {
		res = strings.clone(string(lua.tolstring(L, -1, nil)), context.temp_allocator)
		ok = true
	}
	lua.settop(L, -2) // pop result → [ui]
	if ok {
		lua.pushnil(L)
		lua.setfield(L, -2, "result") // ui.result = nil
	}
	lua.settop(L, -2) // pop ui
	return res, ok
}

// ── helpers ────────────────────────────────────────────────────────────────────────────────────

// ui_read_num_field reads numeric field `key` of the table at the top of the stack into `dst` (left
// unchanged if the field is absent / not a number). Pops only its own temporary.
@(private = "file")
ui_read_num_field :: proc(L: ^lua.State, key: cstring, dst: ^f32) {
	lua.getfield(L, -1, key)
	if lua.type(L, -1) == .NUMBER {
		dst^ = f32(lua.tonumber(L, -1))
	}
	lua.settop(L, -2)
}

// ui_read_num_index reads numeric array element `i` of the table at the top of the stack into `dst`.
@(private = "file")
ui_read_num_index :: proc(L: ^lua.State, i: lua.Integer, dst: ^f32) {
	lua.geti(L, -1, i)
	if lua.type(L, -1) == .NUMBER {
		dst^ = f32(lua.tonumber(L, -1))
	}
	lua.settop(L, -2)
}

// push_ui_field pushes the global `ui` table then its field `name` on top (leaving [ui, field]).
// Returns false (with only [ui] on the stack) if `ui` isn't a table.
@(private = "file")
push_ui_field :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.getglobal(L, "ui") // [ui]
	if lua.type(L, -1) != .TABLE {
		return false
	}
	lua.getfield(L, -1, name) // [ui, field]
	return true
}

// call_ui_method0 calls ui[name]() with no args, discarding results.
@(private = "file")
call_ui_method0 :: proc(L: ^lua.State, name: cstring) {
	if !push_ui_field(L, name) {
		lua.settop(L, -2)
		return
	}
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, -3)
		return
	}
	if lua.pcall(L, 0, 0, 0) != 0 { // [ui] | [ui, errmsg]
		log.errorf("ui: %s: %s", name, ui_lua_str(L, -1))
		lua.settop(L, -2) // pop errmsg
	}
	lua.settop(L, -2) // pop ui
}

// call_ui_method_str calls ui[name](arg) with one string arg, discarding results.
@(private = "file")
call_ui_method_str :: proc(L: ^lua.State, name: cstring, arg: string) {
	if !push_ui_field(L, name) {
		lua.settop(L, -2)
		return
	}
	if lua.type(L, -1) != .FUNCTION {
		lua.settop(L, -3)
		return
	}
	lua.pushstring(L, strings.clone_to_cstring(arg, context.temp_allocator)) // [ui, fn, arg]
	if lua.pcall(L, 1, 0, 0) != 0 { // [ui] | [ui, errmsg]
		log.errorf("ui: %s: %s", name, ui_lua_str(L, -1))
		lua.settop(L, -2) // pop errmsg
	}
	lua.settop(L, -2) // pop ui
}

// ── engine host API (Odin procs surfaced to Lua) ────────────────────────────────────────────────

// install_engine_api builds the global `engine` table whose fields are Odin C closures (^UI_VM rides
// as upvalue 1). Lua calls these to read engine state — e.g. the Load panel calls engine.list_saves.
@(private = "file")
install_engine_api :: proc(vm: ^UI_VM) {
	L := vm.L
	lua.createtable(L, 0, 3) // engine = {}
	register_host(L, vm, "list_saves", engine_list_saves)
	register_host(L, vm, "save_exists", engine_save_exists)
	register_host(L, vm, "credits", engine_credits)
	lua.setglobal(L, "engine") // pops engine
}

// engine_credits() → array of text lines for the credits scroll. Reads interface/credits.txt THROUGH
// THE VFS (so a mod can override it; resolves to the user's vanilla file otherwise), strips its
// <img>/<font> markup, and caches the lines (the scroll polls this every frame). Empty lines are
// kept as blank spacers; the Lua screen styles ALL-CAPS lines as headers.
@(private = "file")
engine_credits :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^UI_VM)lua.touserdata(L, UI_UPVAL)
	context = vm.host_ctx
	if !vm.credits_loaded {
		// Read THROUGH the VFS so a mod's interface/credits.txt overrides vanilla's (uniform resolution).
		if vm.vf != nil {
			if raw, ok := vfs.read(vm.vf, "interface/credits.txt", context.temp_allocator); ok {
				lines := parse_credits(string(raw), context.temp_allocator)
				vm.credits = make([]string, len(lines), context.allocator)
				for ln, i in lines {
					vm.credits[i] = strings.clone(ln, context.allocator)
				}
			}
		}
		vm.credits_loaded = true
	}
	lua.createtable(L, c.int(len(vm.credits)), 0)
	for ln, i in vm.credits {
		lua.pushstring(L, strings.clone_to_cstring(ln, context.temp_allocator))
		lua.seti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// parse_credits splits credits.txt into display lines: SGML-ish tags (<img>, <font>) stripped, each
// line trimmed; blank lines preserved as spacers. All strings in `alloc`.
@(private = "file")
parse_credits :: proc(text: string, alloc: runtime.Allocator) -> []string {
	raw := strings.split_lines(text, alloc)
	out := make([dynamic]string, 0, len(raw), alloc)
	for line in raw {
		b := strings.builder_make(alloc)
		in_tag := false
		for r in line {
			switch r {
			case '<':
				in_tag = true
			case '>':
				in_tag = false
			case:
				if !in_tag {
					strings.write_rune(&b, r)
				}
			}
		}
		append(&out, strings.trim_space(strings.to_string(b)))
	}
	// Drop leading blank lines (credits.txt opens with an <img> tag + blanks) so the scroll reaches
	// the logo/first text sooner instead of scrolling empty space.
	start := 0
	for start < len(out) && out[start] == "" {
		start += 1
	}
	return out[start:]
}

@(private = "file")
register_host :: proc(L: ^lua.State, vm: ^UI_VM, name: cstring, fn: lua.CFunction) {
	lua.pushlightuserdata(L, vm)
	lua.pushcclosure(L, fn, 1)
	lua.setfield(L, -2, name) // engine[name] = closure
}

// engine_list_saves() → array of save entries (tables): { id, label, character, number, created }.
// Lua groups them by character to build the Load panel (grouping is presentation; Odin returns flat
// data). The single quicksave slot today yields one entry; richer save sets come later.
@(private = "file")
engine_list_saves :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^UI_VM)lua.touserdata(L, UI_UPVAL)
	context = vm.host_ctx
	saves := gather_saves(vm.base, context.temp_allocator)
	lua.createtable(L, c.int(len(saves)), 0)
	for s, i in saves {
		push_save_entry(L, s)
		lua.seti(L, -2, lua.Integer(i + 1))
	}
	return 1
}

// engine_save_exists() → bool: is there any loadable save? (Continue/Load gate.) The screen view
// polls this EVERY frame, so the directory scan is cached for the menu's lifetime — no save can be
// written while we're parked in the main menu.
@(private = "file")
engine_save_exists :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^UI_VM)lua.touserdata(L, UI_UPVAL)
	context = vm.host_ctx
	if !vm.saves_checked {
		saves := gather_saves(vm.base, context.temp_allocator)
		vm.has_saves = len(saves) > 0
		vm.saves_checked = true
	}
	lua.pushboolean(L, b32(vm.has_saves))
	return 1
}

@(private = "file")
Save_Item :: struct {
	id:        string, // the .skysave path (what the engine loads)
	label:     string,
	character: string,
	number:    u32,
	created:   i64,
}

// gather_saves scans <base>/saves for *.skysave and reads each manifest into a display entry. All
// strings allocated in `alloc`.
@(private = "file")
gather_saves :: proc(base: string, alloc: runtime.Allocator) -> []Save_Item {
	saves_dir, _ := filepath.join({base, "saves"}, alloc)
	infos, err := os.read_all_directory_by_path(saves_dir, alloc)
	if err != nil {
		return {}
	}
	out := make([dynamic]Save_Item, 0, len(infos), alloc)
	for fi in infos {
		low := strings.to_lower(fi.name, alloc)
		if !strings.has_suffix(low, ".skysave") {
			continue
		}
		path, _ := filepath.join({saves_dir, fi.name}, alloc)
		it := Save_Item {
			id        = path,
			label     = strings.clone(fi.name, alloc),
			character = "Player", // no per-character saves yet (single quicksave slot)
		}
		if man, ok := worldstate.read_manifest(path, alloc); ok {
			it.number = man.save_number
			it.created = man.created_unix
			name := "Quicksave" if strings.contains(low, "quicksave") else fmt.aprintf("Save %d", man.save_number, allocator = alloc)
			it.label = fmt.aprintf("%s — %d change(s)", name, man.delta_count, allocator = alloc)
		}
		append(&out, it)
	}
	return out[:]
}

// push_save_entry pushes one save as a Lua table (called with the host context set).
@(private = "file")
push_save_entry :: proc(L: ^lua.State, s: Save_Item) {
	lua.createtable(L, 0, 5)
	set_str_field(L, "id", s.id)
	set_str_field(L, "label", s.label)
	set_str_field(L, "character", s.character)
	lua.pushinteger(L, lua.Integer(s.number));lua.setfield(L, -2, "number")
	lua.pushinteger(L, lua.Integer(s.created));lua.setfield(L, -2, "created")
}

@(private = "file")
set_str_field :: proc(L: ^lua.State, key: cstring, val: string) {
	lua.pushstring(L, strings.clone_to_cstring(val, context.temp_allocator))
	lua.setfield(L, -2, key)
}
