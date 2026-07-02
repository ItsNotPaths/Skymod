package main

// Host glue for the dev console REPL (src/script/lua/repl.odin). The REPL itself is
// engine-side and headless-tested; this file is only the app-specific wiring: it
// builds the gameplay VM against the live registry + worldstate overlay + gamedb,
// registers the console commands that toggle APP-side state the registry can't reach
// (noclip lives on the character controller, not in the overlay), and loads the
// user's console.lua rc. Everything registry-backed (disable/enable/scale/moveto…)
// comes from the REPL prelude for free.

import "core:c"
import lua "vendor:lua/5.4"
import "../gamedb"
import "../script"
import slua "../script/lua"
import "../worldstate"

// console_repl_init builds the gameplay REPL for the console panel and registers the
// host commands. `noclip` is a pointer to the frame loop's live no-clip flag so the
// `tcl`/`noclip` command toggles the same state the F-key / physics path reads.
console_repl_init :: proc(
	repl: ^slua.Repl,
	reg: ^script.Registry,
	ws: ^worldstate.World_State,
	db: ^gamedb.DB,
	noclip: ^bool,
) -> bool {
	if !slua.repl_init(repl, reg, script.Call{ws = ws, db = db}) {
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
