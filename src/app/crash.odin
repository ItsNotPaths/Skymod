package main

// Crash backtrace handler (dev diagnostic). On a fatal signal (SIGSEGV/SIGABRT/SIGBUS/…) dump a
// native backtrace to stderr (which the logger mirrors to skymod.log / the persisted log), so a
// flaky crash with "no heavy debug" still yields a stack to localize it. Linux/glibc only (uses
// <execinfo.h> backtrace); a no-op stub elsewhere. The release build keeps symbols (-o:speed,
// no -strip), so frames are named. Run with --persist-logs to keep the trail across the crash.

when ODIN_OS == .Linux {

	foreign import libc "system:c"

	@(default_calling_convention = "c")
	foreign libc {
		backtrace :: proc(buffer: [^]rawptr, size: i32) -> i32 ---
		backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: i32, fd: i32) ---
		signal :: proc(sig: i32, handler: proc "c" (i32)) -> proc "c" (i32) ---
		@(link_name = "write")
		c_write :: proc(fd: i32, buf: rawptr, n: uint) -> int ---
		@(link_name = "_exit")
		c_exit :: proc(code: i32) -> ! ---
	}

	@(private = "file")
	CRASH_MSG := "\n*** SkyMod crashed (fatal signal) — native backtrace: ***\n"

	// Async-signal-safe-ish: only foreign C calls (write / backtrace_symbols_fd / _exit) + a raw
	// stack buffer — no Odin allocator / context use.
	@(private = "file")
	crash_handler :: proc "c" (sig: i32) {
		c_write(2, raw_data(CRASH_MSG), len(CRASH_MSG))
		buf: [64]rawptr
		n := backtrace(raw_data(buf[:]), 64)
		backtrace_symbols_fd(raw_data(buf[:]), n, 2) // fd 2 = stderr
		c_exit(1)
	}

	install_crash_handler :: proc() {
		for sig in ([?]i32{11, 6, 7, 4, 8}) { // SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE
			signal(sig, crash_handler)
		}
	}

} else {

	install_crash_handler :: proc() {}

}
