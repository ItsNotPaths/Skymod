package main

// The pre-world UI's `engine` host API: the app data + Odin procs surfaced to the menu's Lua VM
// (saves, credits). The generic VM runtime lives in src/ui/runtime.odin; this file is the app half —
// a UI_Host rides as vm.user, and each proc recovers it via ui.vm_from_upvalue(L).user. The menu
// calls engine.list_saves()/engine.save_exists() itself when it builds the Load panel. Kept small on
// purpose: the mod manager is imgui (engine-compiled), so no mod/profile API ever enters Lua.

import "core:c"
import "core:fmt"
import "core:path/filepath"
import "core:os"
import "base:runtime"
import "core:strings"
import lua "vendor:lua/5.4"
import "../ui"
import "../vfs"
import "../worldstate"

// UI_Host is the app data the engine.* procs read (installed as vm.user for any UI_Session). Shared by
// the main menu AND the load screen — the two never run at once, so one host carries both feature sets:
// the menu reads saves/credits; the load screen reads the load-progress fields (engine.load_progress).
UI_Host :: struct {
	base:           string,   // install base (for engine.list_saves)
	vf:             ^vfs.VFS, // the menu's mounted VFS (mods > content > vanilla) for asset reads
	saves_checked:  bool,     // engine.save_exists is polled every frame — cache the scan result
	has_saves:      bool,     // (no save can appear while we're sitting in the main menu)
	credits:        []string, // engine.credits lines, parsed once + cached (polled every scroll frame)
	credits_loaded: bool,
	// Load-screen state (engine.load_progress). The load driver (loadui.odin) writes these each frame;
	// loading_menu.lua reads them to draw the bar + level + rotating tip. `phase`/`tips` are BORROWED
	// (a static/caller-buffer string; gamedb's tip pool) — cloned into Lua at read time, so they only
	// need to be valid during the frame's ui.frame call.
	load_frac:      f32,
	load_phase:     string,
	load_level:     i32,
	load_tips:      []string,
	load_tip_i:     int,
	load_tip_t:     f32, // seconds accumulated on the current tip (drives rotation)
	// HUD activation-prompt state (engine.activation()). frame_hud writes these each gameplay frame;
	// hud.lua reads them to draw the crosshair prompt. `kind`/`name`/`dest`/`button` are BORROWED
	// (gamedb-owned or a static literal, valid during the frame) — cloned into Lua at read time.
	act_present:    bool,
	act_kind:       string, // neutral tag ("door"/"container"/…); Lua maps it to a verb
	act_name:       string, // the object's own display name
	act_dest:       string, // a door's destination place name ("Riverwood Trader")
	act_locked:     bool,
	act_button:     string, // the activate key label (e.g. "F") — Lua resolves its glyph
}

ui_host_destroy :: proc(host: ^UI_Host) {
	for s in host.credits {
		delete(s)
	}
	delete(host.credits)
	host.credits = nil
}

// install_engine_api builds the global `engine` table whose fields are Odin C closures (^ui.VM
// rides as upvalue 1; the UI_Host as vm.user). Passed to ui.open as the host installer.
install_engine_api :: proc(vm: ^ui.VM) {
	L := vm.L
	lua.createtable(L, 0, 4) // engine = {}
	ui.register_host(L, vm, "list_saves", engine_list_saves)
	ui.register_host(L, vm, "save_exists", engine_save_exists)
	ui.register_host(L, vm, "credits", engine_credits)
	ui.register_host(L, vm, "load_progress", engine_load_progress)
	ui.register_host(L, vm, "activation", engine_activation)
	lua.setglobal(L, "engine") // pops engine
}

// engine_load_progress() → { frac, phase, level, tip }: the load screen (loading_menu.lua) reads this
// every frame to draw the progress bar, the player level, and the current rotating loading tip. The
// fields are published by the load driver (loadui.odin) into the host before each frame.
@(private = "file")
engine_load_progress :: proc "c" (L: ^lua.State) -> c.int {
	vm := ui.vm_from_upvalue(L)
	context = vm.host_ctx
	host := cast(^UI_Host)vm.user
	lua.createtable(L, 0, 4)
	lua.pushnumber(L, lua.Number(host.load_frac));lua.setfield(L, -2, "frac")
	set_str_field(L, "phase", host.load_phase)
	lua.pushinteger(L, lua.Integer(host.load_level));lua.setfield(L, -2, "level")
	tip := ""
	if len(host.load_tips) > 0 {
		tip = host.load_tips[host.load_tip_i % len(host.load_tips)]
	}
	set_str_field(L, "tip", tip)
	return 1
}

// engine_activation() → { present, kind, name, dest, locked, button }: the HUD (hud.lua) reads this
// every frame to draw the crosshair activation prompt. `kind` is a neutral tag the Lua side maps to a
// verb, so the wording/styling stay moddable. frame_hud publishes the fields (resolve_activation)
// each gameplay frame; a non-gameplay frame leaves present=false (just the reticle).
@(private = "file")
engine_activation :: proc "c" (L: ^lua.State) -> c.int {
	vm := ui.vm_from_upvalue(L)
	context = vm.host_ctx
	host := cast(^UI_Host)vm.user
	lua.createtable(L, 0, 6)
	lua.pushboolean(L, b32(host.act_present));lua.setfield(L, -2, "present")
	set_str_field(L, "kind", host.act_kind)
	set_str_field(L, "name", host.act_name)
	set_str_field(L, "dest", host.act_dest)
	lua.pushboolean(L, b32(host.act_locked));lua.setfield(L, -2, "locked")
	set_str_field(L, "button", host.act_button)
	return 1
}

// engine_credits() → array of text lines for the credits scroll. Reads interface/credits.txt THROUGH
// THE VFS (so a mod can override it; resolves to the user's vanilla file otherwise), strips its
// <img>/<font> markup, and caches the lines (the scroll polls this every frame). Empty lines are
// kept as blank spacers; the Lua screen styles ALL-CAPS lines as headers.
@(private = "file")
engine_credits :: proc "c" (L: ^lua.State) -> c.int {
	vm := ui.vm_from_upvalue(L)
	context = vm.host_ctx
	host := cast(^UI_Host)vm.user
	if !host.credits_loaded {
		// Read THROUGH the VFS so a mod's interface/credits.txt overrides vanilla's (uniform resolution).
		if host.vf != nil {
			if raw, ok := vfs.read(host.vf, "interface/credits.txt", context.temp_allocator); ok {
				lines := parse_credits(string(raw), context.temp_allocator)
				host.credits = make([]string, len(lines), context.allocator)
				for ln, i in lines {
					host.credits[i] = strings.clone(ln, context.allocator)
				}
			}
		}
		host.credits_loaded = true
	}
	lua.createtable(L, c.int(len(host.credits)), 0)
	for ln, i in host.credits {
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

// engine_list_saves() → array of save entries (tables): { id, label, character, number, created }.
// Lua groups them by character to build the Load panel (grouping is presentation; Odin returns flat
// data). The single quicksave slot today yields one entry; richer save sets come later.
@(private = "file")
engine_list_saves :: proc "c" (L: ^lua.State) -> c.int {
	vm := ui.vm_from_upvalue(L)
	context = vm.host_ctx
	host := cast(^UI_Host)vm.user
	saves := gather_saves(host.base, context.temp_allocator)
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
	vm := ui.vm_from_upvalue(L)
	context = vm.host_ctx
	host := cast(^UI_Host)vm.user
	if !host.saves_checked {
		saves := gather_saves(host.base, context.temp_allocator)
		host.has_saves = len(saves) > 0
		host.saves_checked = true
	}
	lua.pushboolean(L, b32(host.has_saves))
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
