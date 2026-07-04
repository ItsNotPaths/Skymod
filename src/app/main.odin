package main

// The test-bed executable (ROADMAP Phase 0). It wires the platform layer to the
// renderer and runs the frame loop — and imports NEITHER SDL nor SDL3_gpu: the
// window/input come from `platform`, all drawing goes through `render`, the camera
// math through `math`, the dev UI widgets through `tools`, logging through `log`.
// That is the render-abstraction boundary the project leans on.
//
// Phase 0 progress: window (step 2) + textured cube (step 4) + free-fly debug
// camera (step 5) + Dear ImGui overlay (step 6) + logging (step 7).

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"

import "../installer"
import "../platform"
import "../render"
import slog "../log"
import "../settings"
import "../tools"

WINDOW_W :: 1280
WINDOW_H :: 720

main :: proc() {
	// Dump a native backtrace to stderr/log on a fatal signal (flaky-crash diagnostic).
	install_crash_handler()

	// The raw heap allocator, captured BEFORE the debug tracking wrap below. The
	// streamer's worker thread allocates CPU bundles that the main thread frees; using
	// this (thread-safe, untracked) allocator for them keeps that cross-thread
	// allocate/free off the single-threaded tracking allocator (which would flag it as
	// a bad free). In release builds it's just the heap allocator.
	loader_alloc := context.allocator

	// Debug builds: wrap the heap allocator to catch leaks / double-frees (see
	// docs/memory.md). The report is deferred FIRST so it runs LAST — after every
	// other defer has freed — and prints to stderr directly (the logger is already
	// torn down by then). Release builds (-o:speed, no ODIN_DEBUG) compile it out.
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer mem_report(&track)
	}

	// The boot decision happens before any window/GPU init. Everything hangs off
	// the directory the executable lives in: settings.txt, the log, and the
	// installed content/ folder all sit beside the binary.
	base := platform.base_path()

	// Settings beside the executable. source_game (the path to the user's Skyrim
	// install) lives here so the installer never has to ask twice.
	cfg := settings.load(base)
	defer settings.destroy(&cfg)

	// Logging beside the executable. Default: skymod.log, wiped each run. With
	// --persist-logs (or persist_logs=true in settings): an accumulating logs/.
	persist := slice.contains(os.args, "--persist-logs") || settings.get_bool(&cfg, "persist_logs")
	logging := slog.init(base, persist)
	context.logger = logging.logger
	defer slog.shutdown(&logging)
	if logging.path != "" {
		log.infof("SkyMod starting — log: %s (persist=%v)", logging.path, persist)
	}

	// --uiassetview: browse the extracted UI assets (content/baseui/bethassets) — ←/→ cycle, name + size
	// shown. Available in ALL builds (a keeper utility, not a throwaway test harness), so it works in the
	// shipped/release binary where the assets actually live.
	if slice.contains(os.args, "--uiassetview") {
		run_ui_asset_view(&cfg)
		return
	}

	// Dev harnesses (compiled only when DEVTOOLS — see devtools.odin): each --flag skips the
	// normal boot and runs one isolated test scene/probe instead.
	when DEVTOOLS {
		// `--lodtest`: the BSLODTriShape LOD test grid (needs source_game; mounts the
		// archives directly, no install/streaming — same for every windowed harness).
		if slice.contains(os.args, "--lodtest") {
			run_lod_test(&cfg)
			return
		}
		// `--doortest`: the single-door sandbox for the open-interiors door rig (swing
		// the hinge, find the open pose).
		if slice.contains(os.args, "--doortest") {
			run_door_test(&cfg)
			return
		}
		// `--logotest`: the menu logo (logo.nif) ALONE with a free-fly camera — isolates
		// the mesh from the menu UI integration.
		if slice.contains(os.args, "--logotest") {
			run_logo_test(&cfg)
			return
		}
		// `--phystest`: the headless Jolt smoke (drop a sphere on a floor, log it settling)
		// — proves the vendor/build/static-link/FFI chain. No window/assets.
		if slice.contains(os.args, "--phystest") {
			run_phys_test()
			return
		}
		// `--celltest`: a small static grid of cells around Riverwood with collision
		// (no streaming/LOD/shadows) — a cheap scene to debug physics. G drops balls.
		if slice.contains(os.args, "--celltest") {
			run_cell_test(&cfg)
			return
		}
		// `--terraintest`: headlessly drop a sphere onto the Riverwood terrain trimesh and
		// log whether it rests or falls through — isolates the terrain collision path.
		if slice.contains(os.args, "--terraintest") {
			run_terrain_test(&cfg)
			return
		}
		// `--clutterprobe`: headlessly build the Riverwood bubble's collision (terrain +
		// movable clutter dynamic hulls) and time the physics step at rest vs after a shove
		// — diagnoses the "H freezes" cost. No window.
		if slice.contains(os.args, "--clutterprobe") {
			run_clutter_probe(&cfg)
			return
		}
		// `--uitest`: the UI-substrate render-path smoke test (a hardcoded retained tree via
		// the imgui-DrawList backend) — no world, no Lua.
		if slice.contains(os.args, "--uitest") {
			run_ui_test()
			return
		}
	} else {
		// Recognize the flags anyway so a release binary explains itself instead of
		// silently booting the full game.
		for flag in DEV_FLAGS {
			if slice.contains(os.args, flag) {
				log.warnf("%s: dev harnesses are compiled out of this build (rebuild with -define:DEVTOOLS=true)", flag)
			}
		}
	}

	// Console-recomp boot: no installed content => show the GUI installer, install
	// from the user's own Skyrim files, then re-exec into a clean process that
	// finds content/ ready and launches the game. relaunch() only returns if exec
	// fails, in which case we fall through and run the game in this (already
	// up-to-date) process.
	if !installer.content_ready(base) {
		if !run_installer(base, &cfg) {
			log.info("installer closed before finishing — exiting")
			return
		}
		log.info("install complete — relaunching into the game")
		relaunch()
	}

	run_game(&logging, &cfg, loader_alloc, base)
}

// run_installer shows the first-boot installer window: a small ImGui screen that
// takes the Skyrim source folder (seeded from settings.txt source_game, so it's
// usually one click), validates it live, and installs on click — saving the path
// back so it's never asked again. Returns true once content/ is produced (the
// caller then relaunches into the game); false if the user closed/quit first.
run_installer :: proc(base: string, cfg: ^settings.Config) -> bool {
	p, ok := platform.init("SkyMod — Install", WINDOW_W, WINDOW_H)
	if !ok {
		return false
	}
	defer platform.shutdown(&p)

	r, rok := render.init(p.window)
	if !rok {
		log.error("render init failed; cannot show installer")
		return false
	}
	defer render.shutdown(&r)

	render.ui_init(&r)
	defer render.ui_shutdown(&r)
	p.on_event = render.ui_process_event

	// Seed the path box from the saved source_game (their install path).
	buf: [1024]u8
	seed := settings.get(cfg, "source_game")
	n := copy(buf[:len(buf) - 1], seed)
	buf[n] = 0

	log.info("no content installed — showing the installer")

	for platform.pump(&p) {
		render.ui_new_frame(&r)

		path := string(cstring(raw_data(buf[:])))
		valid := installer.valid_source(path)
		action := tools.installer_screen(buf[:], valid)

		// The installer is the whole frame — just clear behind the UI.
		if render.begin_frame(&r, {0.07, 0.08, 0.10, 1.0}) {
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)

		#partial switch action {
		case .Install:
			// Re-read the buffer (the box may have just changed) and re-validate to
			// guard the one-frame stale-enable race before committing.
			latest := string(cstring(raw_data(buf[:])))
			if !installer.valid_source(latest) {
				continue
			}
			settings.set(cfg, "source_game", latest)
			_ = settings.save(cfg)
			if installer.install(latest, base) {
				return true
			}
			log.error("install failed; leaving the installer open to retry")
		case .Quit:
			return false
		}
	}
	return false // window closed / Esc
}

// run_game is the game chassis: bring the session up (game_setup), run the frame loop
// (game_frame), tear it down in the one documented order (game_teardown — see game.odin).
// Reached once content/ is installed. Logging is already up; cfg is borrowed for the
// session; loader_alloc is the thread-safe heap for cross-thread loader allocations.
run_game :: proc(logging: ^slog.Logging, cfg: ^settings.Config, loader_alloc: runtime.Allocator, base: string) {
	g: Game
	defer game_teardown(&g) // also after a failed/quit setup — tears down exactly what came up
	if !game_setup(&g, logging, cfg, loader_alloc, base) {
		return
	}
	for {
		// The overlay's persist toggle swaps a new sink into the logger and DESTROYS the old
		// multi-logger — re-read it each iteration so pump + the frame log through the live one.
		context.logger = g.logging.logger
		if !platform.pump(&g.p) {
			break
		}
		game_frame(&g)
	}
	context.logger = g.logging.logger // and once in THIS scope, for the line below + the deferred teardown
	log.info("SkyMod shutting down")
}

when ODIN_DEBUG {
	// mem_report dumps the debug allocator's leaks / bad-frees to stderr at exit.
	mem_report :: proc(track: ^mem.Tracking_Allocator) {
		for _, entry in track.allocation_map {
			fmt.eprintfln("[mem] leak: %d bytes @ %v", entry.size, entry.location)
		}
		for entry in track.bad_free_array {
			fmt.eprintfln("[mem] bad free @ %v (ptr %p)", entry.location, entry.memory)
		}
		nleak, nbad := len(track.allocation_map), len(track.bad_free_array)
		if nleak == 0 && nbad == 0 {
			fmt.eprintfln("[mem] clean — no leaks, no bad frees")
		} else {
			fmt.eprintfln("[mem] %d leak(s), %d bad free(s)", nleak, nbad)
		}
		mem.tracking_allocator_destroy(track)
	}
}
