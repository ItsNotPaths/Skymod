package main

// Headless script run (dev harness, not shipped): load an install's plugins, give every
// start-game-enabled quest its scripts, fire OnInit, and report what the scripts tried to do —
// the new-game script start without a window.
//
//   odin run tools/scriptrun -- <Skyrim root> <scripts dir>
//
// <scripts dir> is converted Lua, e.g. <base>/content/basescripts/scripts after an install.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

// Tally groups warnings by their text with digits masked, so one message per form collapses.
Tally :: struct {
	by_msg: map[string]int,
	errors: int,
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: scriptrun <Skyrim root> <scripts dir>")
		os.exit(2)
	}
	db, ok := load_plugins(os.args[1])
	if !ok {os.exit(1)}

	reg: script.Registry
	script.init(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	vm: slua.VM
	if !slua.init(&vm, &reg, script.Call{ws = &ws, db = &db}) {os.exit(1)}
	slua.set_script_dirs(&vm, {os.args[2]})

	tally: Tally
	context.logger = log.Logger{tally_log, &tally, .Debug, nil}
	start := time.now()
	made := slua.start_quests(&vm, &db, true)
	took := time.since(start)
	context.logger = log.create_console_logger(.Info)

	fmt.printfln("instances %d, OnInit run in %v", made, took)
	fmt.printfln("errors %d, distinct warnings %d, stubbed natives hit %d", tally.errors, len(tally.by_msg), len(reg.warned))
	Row :: struct {msg: string, n: int}
	rows := make([dynamic]Row)
	for m, n in tally.by_msg {append(&rows, Row{m, n})}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.n > b.n})
	for r in rows[:min(len(rows), 40)] {
		fmt.printfln("%6d  %s", r.n, r.msg)
	}
}

tally_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	t := cast(^Tally)data
	if level >= .Error {t.errors += 1}
	if level < .Warning {return}
	b := strings.builder_make()
	for r in text {
		strings.write_rune(&b, '#' if r >= '0' && r <= '9' else r)
	}
	t.by_msg[strings.to_string(b)] += 1
}

// load_plugins builds a gamedb from every plugin in <root>/Data, in load order.
load_plugins :: proc(root: string) -> (db: gamedb.DB, ok: bool) {
	data, _ := filepath.join({root, "Data"})
	infos, err := os.read_all_directory_by_path(data, context.allocator)
	if err != nil {
		fmt.eprintfln("cannot read %s", data)
		return {}, false
	}
	inputs := make([dynamic]gamedb.Plugin_Input)
	for fi in infos {
		lower := strings.to_lower(fi.name, context.temp_allocator)
		if !strings.has_suffix(lower, ".esm") && !strings.has_suffix(lower, ".esp") && !strings.has_suffix(lower, ".esl") {
			continue
		}
		p, _ := filepath.join({data, fi.name}, context.temp_allocator)
		bytes, rerr := os.read_entire_file(p, context.allocator)
		if rerr != nil {continue}
		append(&inputs, gamedb.Plugin_Input{name = fi.name, data = bytes})
	}
	if len(inputs) == 0 {
		fmt.eprintfln("no plugins in %s", data)
		return {}, false
	}
	order := gamedb.resolve_load_order(inputs[:], context.allocator)
	return gamedb.build_plugins(order), true
}
