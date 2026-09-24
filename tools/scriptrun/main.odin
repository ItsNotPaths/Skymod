package main

// Headless script run (dev harness, not shipped): load an install's plugins, give every quest and
// persistent ref its scripts, fire OnInit, and report what the scripts tried to do — the new-game
// script start without a window.
//
//   odin run tools/scriptrun -- <Skyrim root> <scripts dir> [flags]
//
//   --cell <formid>|all  also attach this cell (hex form id), or every cell; repeatable
//   --patches <dir>      layer the scripts in <dir> over <scripts dir> (.lua replaces, .patch.lua edits)
//   --driver <file.lua>  run this Lua once after the attach, before the ticks (send events, set stages);
//                        a global `driver_tick(t)` it defines is then called after every tick, t in seconds
//   --seconds <n>        how long ticks run after the attach, default 10
//   --trace              print Debug.Trace and Notification lines with the tick time they ran at
//   --all-warnings       print every warning row, not the top 40
//   --where <script>     repeatable: only list the refs (with their cells), quests and aliases that carry <script>
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
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

TICK_HZ :: 60

Args :: struct {
	root, scripts, patches: string,
	driver:                 string,
	cells, find:            [dynamic]string, // cells: hex form ids, or "all"; find: --where scripts
	seconds:                int,
	trace, all_warnings:    bool,
}

// Tally groups warnings by their text with digits masked, so one message per form collapses.
// With `trace` it also prints script trace lines, stamped with `tick`.
Tally :: struct {
	by_msg: map[string]int,
	errors: int,
	trace:  bool,
	tick:   int,
}

main :: proc() {
	args := parse_args()
	db, ok := load_plugins(args.root)
	if !ok {os.exit(1)}
	if len(args.find) > 0 {
		for name in args.find {print_where(&db, name)}
		return
	}

	reg: script.Registry
	script.init(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	vm: slua.VM
	if !slua.init(&vm, &reg, script.Call{ws = &ws, db = &db}) {os.exit(1)}
	dirs := []string{args.scripts, args.patches}
	slua.set_script_dirs(&vm, dirs[:1] if args.patches == "" else dirs)

	tally := Tally{trace = args.trace}
	context.logger = log.Logger{tally_log, &tally, .Debug, nil}
	start := time.now()
	made := slua.new_game(&vm, &db)
	took := time.since(start)
	start = time.now()
	cells := cells_arg(&db, args.cells[:])
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
	if args.driver != "" {
		guarded := fmt.tprintf("local rt = require('skymod.rt'); rt.guard('driver', assert(loadfile(%q)))", args.driver)
		if !slua.do_string(&vm, guarded) {
			fmt.eprintfln("--driver %s failed; its error is in the warnings below", args.driver)
		}
	}
	start = time.now()
	updates := 0
	for tick in 0 ..< args.seconds * TICK_HZ {
		tally.tick = tick + 1 // a trace in this tick runs after tick + 1 clock advances
		slua.tick_begin(&vm, &db, &ws, &trans, nil, cells, 1.0 / TICK_HZ)
		// The script half of the app's activate: no doors, menus or pickups.
		for a in ws.activations {
			if !a.default_only {slua.send(&vm, a.target, "OnActivate", a.by)}
		}
		clear(&ws.activations)
		updates += slua.tick_end(&vm, 1.0 / TICK_HZ)
		if args.driver != "" {
			slua.do_string(&vm, fmt.tprintf("if driver_tick then require('skymod.rt').guard('driver_tick', driver_tick, %f) end", f32(tick + 1) / TICK_HZ))
		}
		free_all(context.temp_allocator)
	}
	update_took := time.since(start)
	context.logger = log.create_console_logger(.Info)

	fmt.printfln("game start: instances %d, OnInit run in %v", made, took)
	fmt.printfln("cells: instances %d, OnInit run in %v", cell_made, cell_took)
	fmt.printfln("attach: %d events (OnCellAttach, OnLoad, OnCellLoad) run in %v", events, trans_took)
	fmt.printfln("updates: %d OnUpdate and item events over %d s of ticks (%d registered forms left), run in %v", updates, args.seconds, len(ws.updates), update_took)
	fmt.printfln("errors %d, distinct warnings %d, stubbed or unknown natives hit %d", tally.errors, len(tally.by_msg), len(reg.warned))
	Row :: struct {msg: string, n: int}
	rows := make([dynamic]Row)
	for m, n in tally.by_msg {append(&rows, Row{m, n})}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.n > b.n || (a.n == b.n && a.msg < b.msg)})
	top := len(rows) if args.all_warnings else min(len(rows), 40)
	for r in rows[:top] {
		fmt.printfln("%6d  %s", r.n, r.msg)
	}
	for r in rows[top:] {
		if strings.contains(r.msg, "unknown native") {fmt.printfln("%6d  %s", r.n, r.msg)}
	}
}

USAGE :: "usage: scriptrun <Skyrim root> <scripts dir> [--cell <formid>|all]... [--patches <dir>] [--driver <file.lua>] [--seconds <n>] [--trace] [--all-warnings] [--where <script>]"

parse_args :: proc() -> Args {
	a := Args{seconds = 10}
	rest := os.args[1:]
	positional := 0
	for len(rest) > 0 {
		arg := rest[0]
		rest = rest[1:]
		switch arg {
		case "--trace":
			a.trace = true
			continue
		case "--all-warnings":
			a.all_warnings = true
			continue
		case "--cell", "--patches", "--driver", "--where", "--seconds":
			if len(rest) == 0 {usage_exit()}
			value := rest[0]
			rest = rest[1:]
			switch arg {
			case "--cell":
				append(&a.cells, value)
			case "--patches":
				a.patches = value
			case "--driver":
				a.driver = value
			case "--where":
				append(&a.find, value)
			case "--seconds":
				n, ok := strconv.parse_int(value)
				if !ok || n < 0 {usage_exit()}
				a.seconds = n
			}
			continue
		}
		switch positional {
		case 0:
			a.root = arg
		case 1:
			a.scripts = arg
		case:
			usage_exit()
		}
		positional += 1
	}
	if positional < 2 {usage_exit()}
	return a
}

usage_exit :: proc() {
	fmt.eprintln(USAGE)
	os.exit(2)
}

// print_where lists every placed ref, quest, alias and other form that carries `name`.
print_where :: proc(db: ^gamedb.DB, name: string) {
	fmt.printfln("== %s", name)
	carries :: proc(list: []esm.Script_Attach, name: string) -> bool {
		for a in list {
			if strings.equal_fold(a.name, name) && !esm.script_attach_removed(a) {return true}
		}
		return false
	}
	refs := 0
	for groups in ([]map[gamedb.Form_ID][dynamic]gamedb.Ref{db.cell_refs, db.actor_refs}) {
		for _, list in groups {
			for r in list {
				if r.deleted || !carries(gamedb.effective_scripts(db, r.form_id, r.base, context.temp_allocator), name) {continue}
				refs += 1
				cell := gamedb.ref_attach_cell(db, r)
				fmt.printfln("ref   0x%X base 0x%X %q  cell 0x%X %s%s", u64(r.form_id), u64(r.base), gamedb.name_of(db, r.base), u64(cell), db.cells[cell].editor_id, "  (disabled)" if r.disabled else "")
			}
		}
	}
	for form, fs in db.form_scripts {
		if _, is_ref := db.ref_by_id[form]; is_ref {continue}
		if carries(fs.scripts, name) {fmt.printfln("form  0x%X %q", u64(form), gamedb.name_of(db, form))}
		if strings.equal_fold(fs.frag_file, name) {fmt.printfln("frags 0x%X %q", u64(form), gamedb.name_of(db, form))}
		for a in fs.aliases {
			if carries(a.scripts, name) {fmt.printfln("alias 0x%X alias %d", u64(form), a.owner.alias)}
		}
	}
	fmt.printfln("%d placed refs", refs)
}

// cells_arg resolves --cell values: hex form ids, or "all" for every cell with refs or actors.
cells_arg :: proc(db: ^gamedb.DB, values: []string) -> []gamedb.Form_ID {
	cells := make([dynamic]gamedb.Form_ID)
	for v in values {
		if v == "all" {
			for c in db.cell_refs {append(&cells, c)}
			for c in db.actor_refs {
				if c not_in db.cell_refs {append(&cells, c)}
			}
			continue
		}
		id, ok := strconv.parse_u64_of_base(strings.trim_prefix(v, "0x"), 16)
		if !ok {
			fmt.eprintfln("--cell: not a hex form id: %s", v)
			os.exit(2)
		}
		append(&cells, gamedb.Form_ID(id))
	}
	slice.sort(cells[:])
	return slice.unique(cells[:])
}

tally_log :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	t := cast(^Tally)data
	if t.trace && (strings.has_prefix(text, "[papyrus]") || strings.has_prefix(text, "[notification]")) {
		fmt.printfln("t=%.2fs %s", f32(t.tick) / TICK_HZ, text)
	}
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
