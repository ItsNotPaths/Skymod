package ui

// UI file-source resolution: the framework + screen Lua ships #load-EMBEDDED in the binary (the
// engine is bootable with no install), and is also synthesized to disk each boot (content/baseui —
// see app/baseui.odin) where a deep mod can override one file. `source` reads disk first, embedded
// fallback. `run_chunk` executes a resolved chunk in a VM with error logging.

import "core:c"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import lua "vendor:lua/5.4"

@(private = "file")
EMBED_PRELUDE :: #load("lua/lib/ui.lua", string)
@(private = "file")
EMBED_BUTTON :: #load("lua/widget/button.lua", string)
@(private = "file")
EMBED_BOX :: #load("lua/widget/box.lua", string)
@(private = "file")
EMBED_MAIN_MENU :: #load("lua/main_menu.lua", string)

// FRAMEWORK is the framework files (relative paths under the UI lua root) run before any screen, in
// order — they install the constructor globals (container/text/button/box/…).
FRAMEWORK := [?]string{"lib/ui.lua", "widget/button.lua", "widget/box.lua"}

// EMBEDDED_FILES is every built-in UI lua file carried in the binary: the framework + the screens.
// The app synthesizes these to content/baseui/lua each boot (the built-in UI mod).
EMBEDDED_FILES := [?]string{"lib/ui.lua", "widget/button.lua", "widget/box.lua", "main_menu.lua"}

// embedded returns the #load-embedded bytes for a built-in UI file (relative to the UI lua root),
// used as the fallback when content/baseui/ has no copy on disk.
embedded :: proc(rel: string) -> (string, bool) {
	switch rel {
	case "lib/ui.lua":
		return EMBED_PRELUDE, true
	case "widget/button.lua":
		return EMBED_BUTTON, true
	case "widget/box.lua":
		return EMBED_BOX, true
	case "main_menu.lua":
		return EMBED_MAIN_MENU, true
	}
	return "", false
}

// source reads a UI lua file from `dir` (disk), falling back to the embedded copy. The returned
// string is temp-allocated (valid for the load) when read from disk, or the embedded literal.
source :: proc(dir: string, rel: string) -> (string, bool) {
	if dir != "" {
		path, _ := filepath.join({dir, rel}, context.temp_allocator)
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 {
			return string(data), true
		}
	}
	return embedded(rel)
}

run_chunk :: proc(L: ^lua.State, code: string, name: string) -> bool {
	cs := strings.clone_to_cstring(code, context.temp_allocator)
	if lua.L_dostring(L, cs) != 0 {
		log.errorf("ui: %s: %s", name, lua_str(L, -1))
		lua.settop(L, -2)
		return false
	}
	return true
}

// lua_str reads the string at `idx` ("" if not a string / nil) — error-message extraction.
lua_str :: proc(L: ^lua.State, idx: c.int) -> string {
	s := lua.tolstring(L, idx, nil)
	return string(s) if s != nil else ""
}
