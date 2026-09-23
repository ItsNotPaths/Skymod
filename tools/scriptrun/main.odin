package main

// Headless script run (dev harness, not shipped): load an install's plugins, give every quest and
// persistent ref its scripts, fire OnInit, and report what the scripts tried to do — the new-game
// script start without a window. --cell also loads and attaches one cell (hex form id), or every cell.
//
//   odin run tools/scriptrun -- <Skyrim root> <scripts dir> [--cell <formid>|all]
//
// <scripts dir> is converted Lua, e.g. <base>/content/basescripts/scripts after an install.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

// UPDATE_TICKS is how long the run lets registered OnUpdate timers play out: 10 s at 60Hz.
UPDATE_TICKS :: 600

// Tally groups warnings by their text with digits masked, so one message per form collapses.
Tally :: struct {
	by_msg: map[string]int,
	errors: int,
}

main :: proc() {
	if len(os.args) < 3 {
		fmt.eprintln("usage: scriptrun <Skyrim root> <scripts dir> [--cell <formid>|all]")
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
	made := slua.new_game(&vm, &db)
	took := time.since(start)
	start = time.now()
	cells := cells_arg(&db)
	cell_made := 0
	for cell in cells {
		cell_made += slua.attach_cell(&vm, &db, cell)
		free_all(context.temp_allocator)
	}
	cell_took := time.since(start)
	start = time.now()
	trans: slua.Transitions
	slua.tick_transitions(&vm, &db, &ws, &trans, cells)
	events := slua.drain(&vm)
	trans_took := time.since(start)
	start = time.now()
	updates := 0
	for _ in 0 ..< UPDATE_TICKS {
		slua.tick_updates(&vm, &ws, 1.0 / 60)
		slua.tick_items(&vm, &db, &ws)
		updates += slua.drain(&vm)
		free_all(context.temp_allocator)
	}
	update_took := time.since(start)
	context.logger = log.create_console_logger(.Info)

	fmt.printfln("game start: instances %d, OnInit run in %v", made, took)
	fmt.printfln("cells: instances %d, OnInit run in %v", cell_made, cell_took)
	fmt.printfln("attach: %d events (OnCellAttach, OnLoad, OnCellLoad) run in %v", events, trans_took)
	fmt.printfln("updates: %d OnUpdate and item events over %d s of ticks (%d registered forms left), run in %v", updates, UPDATE_TICKS / 60, len(ws.updates), update_took)
	fmt.printfln("errors %d, distinct warnings %d, stubbed or unknown natives hit %d", tally.errors, len(tally.by_msg), len(reg.warned))
	Row :: struct {msg: string, n: int}
	rows := make([dynamic]Row)
	for m, n in tally.by_msg {append(&rows, Row{m, n})}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.n > b.n})
	for r in rows[:min(len(rows), 40)] {
		fmt.printfln("%6d  %s", r.n, r.msg)
	}
	for r in rows[min(len(rows), 40):] {
		if strings.contains(r.msg, "unknown native") {fmt.printfln("%6d  %s", r.n, r.msg)}
	}
}

// cells_arg reads --cell: one hex form id, or every cell with refs or actors.
cells_arg :: proc(db: ^gamedb.DB) -> []gamedb.Form_ID {
	if len(os.args) < 5 || os.args[3] != "--cell" {return nil}
	if os.args[4] == "all" {
		cells := make([dynamic]gamedb.Form_ID)
		for c in db.cell_refs {append(&cells, c)}
		for c in db.actor_refs {
			if c not_in db.cell_refs {append(&cells, c)}
		}
		slice.sort(cells[:])
		return cells[:]
	}
	id, ok := strconv.parse_u64_of_base(strings.trim_prefix(os.args[4], "0x"), 16)
	if !ok {
		fmt.eprintfln("--cell: not a hex form id: %s", os.args[4])
		os.exit(2)
	}
	return slice.clone([]gamedb.Form_ID{gamedb.Form_ID(id)})
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
