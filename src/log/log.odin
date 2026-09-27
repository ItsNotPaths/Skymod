package slog

// Logging setup (ROADMAP Phase 0, step 7). Installs a logger into context.logger
// that writes to the console AND a file beside the executable:
//
//   default          ->  <dir>/skymod.log         truncated each run (latest only)
//   persist == true  ->  <dir>/logs/skymod-<ts>.log   accumulating, one per run
//
// At runtime, persist_run() forks the current run's log into the logs/ folder and
// then writes to BOTH files (the dev-UI "Persist this run's log" button).
//
// Call init() once at startup and pass the result to shutdown() before exit.
// Everywhere else just uses core:log — log.infof, log.errorf, etc. The logger never
// changes after init, so a thread may keep the copy its context started with.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

Logging :: struct {
	logger:         log.Logger, // the CALLER must assign context.logger = this; it never changes
	sinks:          ^Sinks,
	console:        log.Logger,
	file:           log.Logger,
	handle:         ^os.File,
	path:           string, // primary log file (heap-owned), or "" if file logging is off
	dir:            string, // base dir beside the exe, where logs/ lives
	lowest:         log.Level,

	// Runtime "persist this run" sink (default mode): a second file in logs/ that
	// mirrors the run's log, seeded with everything written so far. See persist_run.
	persist:        log.Logger,
	persist_handle: ^os.File,
	persist_path:   string,
	persisting:     bool,
}

// Sinks is what the logger writes to. It is heap-owned, so the logger's data pointer
// survives a copy of Logging, and locked, because persist_run adds a sink while other
// threads log.
@(private)
Sinks :: struct {
	mu:   sync.Mutex,
	list: [3]log.Logger,
	n:    int,
}

// init builds the logger and returns its state. `dir` is the directory to put the
// log in (beside the executable). `persist` switches the primary file from the
// single wiped file to the accumulating logs/ folder.
//
// NOTE: the caller must do `context.logger = lg.logger` — Odin's `context` is
// per-scope, so a logger installed in here would not reach the caller.
init :: proc(dir: string, persist: bool, lowest := log.Level.Debug) -> (lg: Logging) {
	lg.dir = dir
	lg.lowest = lowest
	lg.console = log.create_console_logger(lowest)

	path: string
	if persist {
		path = new_run_path(dir)
	} else {
		path, _ = filepath.join({dir, "skymod.log"}, context.temp_allocator)
	}

	if h, err := os.open(path, {.Write, .Create, .Trunc}); err == nil {
		lg.handle = h
		lg.file = log.create_file_logger(h, lowest)
		lg.path = strings.clone(path)
		if persist {
			// Already a kept file — no separate runtime sink needed.
			lg.persisting = true
			lg.persist_path = lg.path
		}
	} else {
		// Console-only; surface why through the console logger (set it locally so
		// this one warning is visible — the caller installs lg.logger afterward).
		context.logger = lg.console
		log.warnf("slog: could not open log file %q: %v (console only)", path, err)
	}

	lg.sinks = new(Sinks)
	add_sink(lg.sinks, lg.console)
	if lg.handle != nil {
		add_sink(lg.sinks, lg.file)
	}
	lg.logger = log.Logger{sinks_proc, lg.sinks, log.Level.Debug, nil}
	return
}

// persist_run forks the current run's log into a fresh logs/skymod-<ts>.log: it
// copies everything written so far, then writes to BOTH that file and the primary
// one. No-op (returns false) if already persisting or if file logging is off.
persist_run :: proc(lg: ^Logging) -> bool {
	if lg.persisting || lg.handle == nil {
		return false
	}
	path := new_run_path(lg.dir)
	h, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil {
		log.errorf("slog: persist_run could not open %q: %v", path, err)
		return false
	}
	lg.persist_handle = h
	lg.persist = log.create_file_logger(h, lg.lowest)
	lg.persist_path = strings.clone(path)
	lg.persisting = true
	{
		// Seed it with the run so far (the primary file is on disk — the file logger
		// writes unbuffered), then keep appending. Locked, so no line falls between.
		sync.guard(&lg.sinks.mu)
		if data, derr := os.read_entire_file(lg.path, context.temp_allocator); derr == nil {
			_, _ = os.write(h, data)
		}
		add_sink(lg.sinks, lg.persist)
	}
	log.infof("slog: now persisting this run's log -> %s", lg.persist_path)
	return true
}

shutdown :: proc(lg: ^Logging) {
	free(lg.sinks)
	if lg.persist_handle != nil {
		log.destroy_file_logger(lg.persist)
		os.close(lg.persist_handle)
		delete(lg.persist_path)
	}
	if lg.handle != nil {
		log.destroy_file_logger(lg.file)
		os.close(lg.handle)
		delete(lg.path)
	}
	log.destroy_console_logger(lg.console)
}

@(private)
add_sink :: proc(s: ^Sinks, l: log.Logger) {
	s.list[s.n] = l
	s.n += 1
}

@(private)
sinks_proc :: proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
	s := (^Sinks)(data)
	sync.guard(&s.mu)
	for l in s.list[:s.n] {
		if level >= l.lowest_level {
			l.procedure(l.data, level, text, l.options, location)
		}
	}
}

// new_run_path returns <dir>/logs/skymod-<timestamp>.log (creating logs/), in the
// temp allocator. Clone it if you need to keep it.
@(private)
new_run_path :: proc(dir: string) -> string {
	logs_dir, _ := filepath.join({dir, "logs"}, context.temp_allocator)
	_ = os.make_directory(logs_dir) // ignore "already exists"
	name := fmt.tprintf("skymod-%s.log", timestamp())
	path, _ := filepath.join({logs_dir, name}, context.temp_allocator)
	return path
}

@(private)
timestamp :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock_from_time(t)
	return fmt.tprintf("%4d%02d%02d-%02d%02d%02d", y, int(mo), d, h, mi, s)
}
