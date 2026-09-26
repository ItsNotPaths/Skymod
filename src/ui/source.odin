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
import lua "../../vendor/lua"

@(private = "file")
EMBED_PRELUDE :: #load("lua/lib/ui.lua", string)
@(private = "file")
EMBED_BUTTON :: #load("lua/widget/button.lua", string)
@(private = "file")
EMBED_BOX :: #load("lua/widget/box.lua", string)
@(private = "file")
EMBED_BAR :: #load("lua/widget/bar.lua", string)
@(private = "file")
EMBED_PROMPT :: #load("lua/widget/prompt.lua", string)
@(private = "file")
EMBED_MAIN_MENU :: #load("lua/main_menu.lua", string)
@(private = "file")
EMBED_LOADING_MENU :: #load("lua/loading_menu.lua", string)
@(private = "file")
EMBED_HUD :: #load("lua/hud.lua", string)

// Three screens exist: main menu, loading, HUD. Everything a player opens does not; the inventory,
// magic, skills and container menus are ImGui placeholders (app/menus.odin).
//
// (hole dialogue-screen :tags ui :sev blocker) no dialogue screen — no topic list, no response, no exit.
// (hole journal :tags ui :sev gap) no journal — quest stages and objectives are tracked in worldstate and shown nowhere.
// (hole map-screen :tags ui :sev gap) no map — no world map, no local map, no fast-travel target.
// (hole crafting-screen :tags ui :sev gap) no crafting screen, which is also why EPTemperingItemIsEnchanted (659) cannot know which item is selected.
// (hole story-craft-event :tags (quest ui) :sev gap :needs (story-manager crafting-screen)) crafting queues no CRFT story event (the smithing and alchemy tutorials).
// (hole console-screen :tags ui :sev gap) the console is an ImGui dev panel (tools.console_panel), not a Lua UI screen: a mod cannot restyle or replace it.
//
// FRAMEWORK is the framework files (relative paths under the UI lua root) run before any screen, in
// order — they install the constructor globals (container/text/button/box/bar/…).
FRAMEWORK := [?]string{"lib/ui.lua", "widget/button.lua", "widget/box.lua", "widget/bar.lua", "widget/prompt.lua"}

// (hole ui-lua-vfs :tags mods :sev gap) the app writes these to content/baseui/lua and loads them from disk, NOT through the VFS — so a mod cannot override the engine's own UI Lua.
// EMBEDDED_FILES is every built-in UI lua file carried in the binary: the framework + the screens.
// The app synthesizes these to content/baseui/lua each boot (the built-in UI mod).
EMBEDDED_FILES := [?]string {
	"lib/ui.lua",
	"widget/button.lua",
	"widget/box.lua",
	"widget/bar.lua",
	"widget/prompt.lua",
	"main_menu.lua",
	"loading_menu.lua",
	"hud.lua",
}

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
	case "widget/bar.lua":
		return EMBED_BAR, true
	case "widget/prompt.lua":
		return EMBED_PROMPT, true
	case "main_menu.lua":
		return EMBED_MAIN_MENU, true
	case "loading_menu.lua":
		return EMBED_LOADING_MENU, true
	case "hud.lua":
		return EMBED_HUD, true
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
