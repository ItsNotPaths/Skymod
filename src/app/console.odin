package main

// Host glue for the dev console REPL (src/script/lua/repl.odin). The REPL itself is
// engine-side and headless-tested; this file is only the app-specific wiring: it
// builds the gameplay VM against the live registry + worldstate overlay + gamedb,
// registers the console commands that toggle APP-side state the registry can't reach
// (noclip lives on the character controller, not in the overlay), and loads the
// user's console.lua rc. Everything registry-backed (disable/enable/scale/moveto…)
// comes from the REPL prelude for free.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import lua "../../vendor/lua"
import "../ai"
import "../audio"
import "../formid"
import "../gamedb"
import "../script"
import slua "../script/lua"
import "../vfs"
import "../worldstate"

// console_repl_init builds the gameplay REPL for the console panel and registers the
// host commands. `noclip` is a pointer to the frame loop's live no-clip flag so the
// `tcl`/`noclip` command toggles the same state the F-key / physics path reads.
console_repl_init :: proc(
	repl: ^slua.Repl,
	reg: ^script.Registry,
	ws: ^worldstate.World_State,
	db: ^gamedb.DB,
	a: ^audio.Audio,
	v: ^vfs.VFS,
	noclip: ^bool,
) -> bool {
	if !slua.repl_init(repl, reg, script.Call{ws = ws, db = db, audio = a, vfs = v}) {
		return false
	}
	// noclip toggles a bool the frame loop owns; the pointer rides as the closure's
	// upvalue. `tcl` is the CE spelling (the preprocessor maps `tcl` → cmd.noclip()).
	slua.repl_register_cmd(repl, "noclip", "toggle no-clip free-fly", console_cmd_noclip, noclip)
	return true
}

// console_cmd_noclip flips the host no-clip flag (upvalue 1 = ^bool) and prints the
// new state through the captured `print` so the panel echoes feedback.
@(private = "file")
console_cmd_noclip :: proc "c" (L: ^lua.State) -> c.int {
	// lua_upvalueindex(1): the binding omits the macro (it's REGISTRYINDEX - i).
	flag := cast(^bool)lua.touserdata(L, lua.REGISTRYINDEX - 1)
	flag^ = !flag^
	lua.getglobal(L, "print")
	lua.pushstring(L, "noclip on" if flag^ else "noclip off")
	lua.pcall(L, 1, 0, 0)
	return 0
}

// console_cmd_possess gives the player control of an actor (upvalue 1 = ^Game): the argument, else
// the selection, else the start character. Input drives it from the next tick; its AI rests.
@(private = "package")
console_cmd_possess :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	g := cast(^Game)lua.touserdata(L, lua.REGISTRYINDEX - 1)
	if lua.gettop(L) == 0 || lua.isnil(L, 1) {lua.getglobal(L, "sel")}
	form, ok := slua.ref_form(L, -1)
	form = worldstate.resolve(&g.sim.ws, form) if ok && form != 0 else formid.START_CHARACTER
	text := "possess: not an actor"
	if is_actor_ref(g, form) {
		g.sim.ws.player = form
		text = fmt.tprintf("possess: %s", worldstate.display_name(&g.sim.ws, &g.db, form))
	}
	lua.getglobal(L, "print")
	lua.pushstring(L, strings.clone_to_cstring(text, context.temp_allocator))
	lua.pcall(L, 1, 0, 0)
	return 0
}

// console_cmd_ai prints an actor's AI state (upvalue 1 = ^Game); no argument means the selection.
@(private = "package")
console_cmd_ai :: proc "c" (L: ^lua.State) -> c.int {
	context = runtime.default_context()
	g := cast(^Game)lua.touserdata(L, lua.REGISTRYINDEX - 1)
	if lua.gettop(L) == 0 {
		lua.getglobal(L, "sel")
	} else if lua.isnil(L, 1) {
		lua.getglobal(L, "sel")
		lua.replace(L, 1)
	}
	form, ok := slua.ref_form(L, 1)
	text := ai.describe(&g.sim.agents, &g.sim.ws, &g.db, form) if ok else "ai: no ref"
	lua.getglobal(L, "print")
	lua.pushstring(L, strings.clone_to_cstring(text, context.temp_allocator))
	lua.pcall(L, 1, 0, 0)
	return 0
}
