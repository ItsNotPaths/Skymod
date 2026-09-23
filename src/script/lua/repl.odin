package script_lua

// The dev console REPL — the Phase-4 native-testing loop and the user's visual
// verify surface (docs/script-runtime-decisions.md, "Console"). It evaluates typed
// lines on the SAME gameplay VM the transpiled scripts run on, so every registered
// native is a console command the instant it lands: type `sel:Disable()` (or the CE
// alias) and watch it apply through the worldstate overlay. Output (results, print,
// errors) is captured line-by-line for the host panel to render — the module carries
// no imgui dependency, so it unit-tests headless.
//
// Layers on top of the base VM (lua.odin) + ref system (ref.odin):
//   • an expression/statement REPL eval with captured print + result + error,
//   • the enumerable `cmd` table (real verbs: cmd.disable/enable/scale/…) that host
//     code extends with app commands (noclip/god) via repl_register_cmd,
//   • `player` / `sel` ref globals + the `ref()` constructor,
//   • a thin CE-syntax preprocessor (tcl/tgm, bare 0xFORMID, `obj.method args`),
//   • an optional user `console.lua` rc.

import "base:runtime"
import "core:c"
import "core:log"
import "core:os"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."

// Repl owns a gameplay VM plus an output accumulator. `out` holds the lines produced
// by the most recent repl_eval (owned by `alloc`, rebuilt each call); the host drains
// it into its scrollback.
Repl :: struct {
	vm:    VM,
	out:   [dynamic]string,
	alloc: runtime.Allocator,
}

@(private)
out_allocator :: proc(repl: ^Repl) -> runtime.Allocator {
	return repl.alloc
}

// REPL_PRELUDE installs the capture-aware `print`, the `__repl_eval` driver, and the
// `cmd` table. It runs on the gameplay VM after the ref system is up.
@(private)
REPL_PRELUDE :: `
function print(...)
  local n = select('#', ...)
  local t = {}
  for i = 1, n do t[i] = tostring((select(i, ...))) end
  __repl_out(table.concat(t, "\t"))
end

-- Expression-first eval: try to 'return <src>' (so bare expressions echo their
-- value), else run <src> as a statement. Errors are captured, never thrown out.
function __repl_eval(src)
  local chunk, err = load("return " .. src, "=repl")
  if not chunk then chunk, err = load(src, "=repl") end
  if not chunk then __repl_out("! " .. tostring(err)); return end
  local r = table.pack(pcall(chunk))
  if not r[1] then __repl_out("! " .. tostring(r[2])); return end
  for i = 2, r.n do __repl_out(tostring(r[i])) end
end

-- Enumerable command table with per-command metadata (help/aliases) → free
-- autocomplete + help. cmd.def is how both the built-ins below and host code add
-- commands; the real verb name is the good one (noclip/god/disable), CE spellings
-- are aliases layered by the preprocessor.
cmd = {}
local meta = {}
cmd.__meta = meta
function cmd.def(name, fn, help, aliases)
  cmd[name] = fn
  meta[name] = { help = help, aliases = aliases }
  if aliases then for _, a in ipairs(aliases) do cmd[a] = fn end end
end
function cmd.help(name)
  if name and meta[name] then
    __repl_out(name .. " — " .. (meta[name].help or ""))
    return
  end
  local names = {}
  for k in pairs(meta) do names[#names + 1] = k end
  table.sort(names)
  for _, k in ipairs(names) do
    __repl_out(string.format("%-14s %s", k, meta[k].help or ""))
  end
end

-- Built-in verbs — pure registry calls, so they work headless. A nil ref falls back
-- to the current selection (sel), matching CE's "command acts on the picked ref".
cmd.def("disable", function(r) (r or sel):Disable() end, "disable a ref (default: selection)")
cmd.def("enable",  function(r) (r or sel):Enable()  end, "enable a ref")
cmd.def("delete",  function(r) (r or sel):Delete()  end, "delete a ref")
cmd.def("scale",   function(a, b)
  local r, s = sel, a
  if type(a) ~= "number" then r, s = a, b end
  r:SetScale(s)
end, "setscale [ref] <scale>")
cmd.def("getscale", function(r) print((r or sel):GetScale()) end, "print a ref's scale")
cmd.def("moveto",  function(a, b)
  local r, t = sel, a
  if b ~= nil then r, t = a, b end
  r:MoveTo(t)
end, "moveto [ref] <target>")
cmd.def("god", function() print("god mode: no host handler registered") end, "toggle god mode")
-- prid <formid>: make a ref the current selection (CE 'pick reference by id'). Accepts a raw id or
-- an already-built ref (the preprocessor wraps bare hex in ref()). Assigns the GLOBAL sel.
cmd.def("prid", function(x)
  sel = (type(x) == "number") and ref(x) or x
  print(sel)
end, "prid <formid> — select a ref by id")
`

// repl_init builds the REPL onto the gameplay VM (registry + call context) and
// installs the prelude, the __repl_out capture bridge, and the player/sel globals.
repl_init :: proc(repl: ^Repl, reg: ^script.Registry, ctx: script.Call, allocator := context.allocator) -> bool {
	repl.alloc = allocator
	repl.out = make([dynamic]string, allocator)
	if !init(&repl.vm, reg, ctx) {
		return false
	}
	L := repl.vm.L

	// __repl_out(str): capture bridge — appends one output line. ^Repl rides as upvalue.
	lua.pushlightuserdata(L, repl)
	lua.pushcclosure(L, repl_out, 1)
	lua.setglobal(L, "__repl_out")

	if !do_string(&repl.vm, REPL_PRELUDE) {
		return false
	}

	// player = the tagged player actor; sel starts as None (no click-pick yet).
	push_ref(L, script.PLAYER)
	lua.setglobal(L, "player")
	push_none(L)
	lua.setglobal(L, "sel")
	return true
}

repl_destroy :: proc(repl: ^Repl) {
	repl_clear_out(repl)
	delete(repl.out)
	destroy(&repl.vm)
}

// repl_eval runs one console line and returns the captured output lines (owned by
// the Repl, valid until the next repl_eval). The line is CE-preprocessed first.
repl_eval :: proc(repl: ^Repl, line: string) -> []string {
	repl.vm.host_context = context
	repl_clear_out(repl)

	src := preprocess(line, context.temp_allocator)
	if strings.trim_space(src) == "" {
		return repl.out[:]
	}
	L := repl.vm.L
	lua.getglobal(L, "__repl_eval")
	lua.pushstring(L, strings.clone_to_cstring(src, context.temp_allocator))
	if lua.pcall(L, 1, 0, 0) != 0 {
		// __repl_eval traps its own errors; this only fires on a prelude-level fault.
		repl_push_out(repl, strings.concatenate({"! ", to_string(L, -1)}, context.temp_allocator))
		lua.pop(L, 1)
	}
	return repl.out[:]
}

// repl_set_selection updates the `sel` global to a ref (or None for form 0) — the
// host calls it each frame from the click-picker so `sel` tracks the aimed ref.
repl_set_selection :: proc(repl: ^Repl, form: script.Form_ID) {
	push_ref(repl.vm.L, form) // form 0 → None
	lua.setglobal(repl.vm.L, "sel")
}

// repl_register_cmd adds a host command to `cmd` (name + aliases + help). `fn` is a
// Lua C function; `upvalue` (optional) is handed to it as a light-userdata upvalue so
// it can reach app state (e.g. the noclip flag). Aliases route to the same function.
repl_register_cmd :: proc(
	repl: ^Repl,
	name, help: string,
	fn: lua.CFunction,
	upvalue: rawptr = nil,
	aliases: []string = nil,
) {
	L := repl.vm.L
	lua.getglobal(L, "cmd") // [cmd]
	lua.getfield(L, -1, "def") // [cmd, cmd.def]
	lua.pushstring(L, strings.clone_to_cstring(name, context.temp_allocator)) // [.., name]
	if upvalue != nil {
		lua.pushlightuserdata(L, upvalue)
		lua.pushcclosure(L, fn, 1) // [.., name, fn]
	} else {
		lua.pushcfunction(L, fn)
	}
	lua.pushstring(L, strings.clone_to_cstring(help, context.temp_allocator)) // [.., name, fn, help]
	if len(aliases) > 0 {
		lua.createtable(L, i32(len(aliases)), 0) // [.., name, fn, help, {}]
		for a, i in aliases {
			lua.pushstring(L, strings.clone_to_cstring(a, context.temp_allocator))
			lua.rawseti(L, -2, lua.Integer(i + 1))
		}
		call_or_log(repl, 4)
	} else {
		call_or_log(repl, 3)
	}
	lua.pop(L, 1) // pop cmd
}

// repl_load_rc runs a user `console.lua` if present at `path` (missing file is not an
// error — most users have none). Returns false only on a real load/runtime error.
repl_load_rc :: proc(repl: ^Repl, path: string) -> bool {
	repl.vm.host_context = context
	if !os.exists(path) {
		return true
	}
	L := repl.vm.L
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if lua.L_dofile(L, cpath) != 0 {
		log.errorf("console.lua: %s", to_string(L, -1))
		lua.pop(L, 1)
		return false
	}
	log.infof("console: loaded rc %s", path)
	return true
}

// ── internals ────────────────────────────────────────────────────────────────

// repl_out is the C bridge behind the Lua `__repl_out(str)`. Upvalue 1 = ^Repl.
@(private)
repl_out :: proc "c" (L: ^lua.State) -> c.int {
	repl := cast(^Repl)lua.touserdata(L, upvalueindex(1))
	context = repl.vm.host_context
	repl_push_out(repl, to_string(L, 1))
	return 0
}

@(private)
repl_push_out :: proc(repl: ^Repl, s: string) {
	append(&repl.out, strings.clone(s, out_allocator(repl)))
}

@(private)
repl_clear_out :: proc(repl: ^Repl) {
	for s in repl.out {
		delete(s, out_allocator(repl))
	}
	clear(&repl.out)
}

// call_or_log invokes cmd.def with `nargs` args already on the stack, logging (not
// throwing) a failure so a bad host registration can't take the console down.
@(private)
call_or_log :: proc(repl: ^Repl, nargs: c.int) {
	if lua.pcall(repl.vm.L, nargs, 0, 0) != 0 {
		log.errorf("console: cmd.def failed: %s", to_string(repl.vm.L, -1))
		lua.pop(repl.vm.L, 1)
	}
}
