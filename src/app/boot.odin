package main

// Boot-shell helper for the install-then-relaunch flow (console-recomp style):
// the SAME binary detects missing content, runs the GUI installer (run_installer
// in main, drawn via tools.installer_screen), then re-execs itself so a clean
// process boots straight into the game.

import "core:log"
import "core:os"
import "core:strings"
import "core:sys/posix"

// relaunch replaces this process with a fresh run of the same binary
// (/proc/self/exe) and the original arguments. A successful exec never returns;
// the new process re-runs the boot check, finds content/ ready, and launches the
// game. Only returns if exec fails — the caller then falls through and runs the
// game in this process instead.
relaunch :: proc() {
	argv := make([dynamic]cstring, 0, len(os.args) + 1, context.temp_allocator)
	for a in os.args {
		append(&argv, strings.clone_to_cstring(a, context.temp_allocator))
	}
	append(&argv, nil)

	posix.execv("/proc/self/exe", raw_data(argv[:]))
	log.errorf("relaunch: could not re-exec self: %v", posix.strerror(posix.errno()))
}
