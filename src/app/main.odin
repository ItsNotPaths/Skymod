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
import "core:strconv"
import "core:thread"
import "core:time"

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

	// One-time layout migration: the mod profiles moved from <base>/modprofiles/ to <base>/profiles/
	// (the old lighting "profiles/" concept became the pinned content/baselighting mod). Runs before
	// any dir is read below so settings/modlists resolve from the new location.
	migrate_profiles_layout(base)

	// Root settings = the vanilla baseline profile (<base>/profiles/vanilla/settings.txt),
	// which every other profile inherits. The executable creates/refreshes it from the DEFAULTS
	// embedded in the binary (and migrates any legacy <base>/settings.txt into it) — nothing is
	// shipped alongside the exe. source_game lives here so the installer never asks twice.
	cfg := load_root_settings(base)
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

	if run_game(&logging, &cfg, loader_alloc, base) == .Main_Menu {relaunch()}
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

	// Seed the path box from the best-known install path (override first, then the
	// per-edition keys) — shown even if stale/invalid so there's something to edit.
	buf: [1024]u8
	seed := settings.get(cfg, "source_game")
	if seed == "" {seed = settings.get(cfg, "source_game_se")}
	if seed == "" {seed = settings.get(cfg, "source_game_le")}
	n := copy(buf[:len(buf) - 1], seed)
	buf[n] = 0

	log.info("no content installed — showing the installer")

	// The install runs on its own thread; the window shows its progress meanwhile.
	Install_Job :: struct {
		source, base: string,
		progress:     installer.Progress,
		ok:           bool,
	}
	job := Install_Job{base = base}
	worker: ^thread.Thread

	for platform.pump(&p) {
		render.ui_new_frame(&r)

		action := tools.Installer_Action.None
		if worker != nil {
			step, item, done, total := installer.progress_read(&job.progress)
			tools.installer_progress_screen(step, item, done, total)
		} else {
			path := string(cstring(raw_data(buf[:])))
			action = tools.installer_screen(buf[:], installer.valid_source(path))
		}

		// The installer is the whole frame — just clear behind the UI.
		if render.begin_frame(&r, {0.07, 0.08, 0.10, 1.0}) {
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)

		if worker != nil && thread.is_done(worker) {
			thread.destroy(worker) // joins
			worker = nil
			if job.ok {return true}
			log.error("install failed; leaving the installer open to retry")
		}

		#partial switch action {
		case .Install:
			// Re-read the buffer (the box may have just changed) and re-validate to
			// guard the one-frame stale-enable race before committing.
			latest := string(cstring(raw_data(buf[:])))
			if !installer.valid_source(latest) {
				continue
			}
			// Store under the key matching the install's autodetected edition, so both
			// an LE and an SE path can coexist; unknown-exe trees fall back to the
			// manual-override key.
			ed, _ := installer.detect_edition(latest)
			switch ed {
			case .SE:
				settings.set(cfg, "source_game_se", latest)
			case .LE:
				settings.set(cfg, "source_game_le", latest)
			case .Unknown:
				settings.set(cfg, "source_game", latest)
			}
			_ = settings.save(cfg)
			job.source = latest // buf is not edited while the install runs
			job.progress = {}
			worker = thread.create_and_start_with_poly_data(&job, proc(j: ^Install_Job) {
				j.ok = installer.install(j.source, j.base, &j.progress)
			}, init_context = context)
		case .Quit:
			return false
		}
	}
	return false // window closed / Esc
}

// resolve_source picks the active install: an explicit source_game (manual override)
// wins verbatim; otherwise the per-edition paths are tried — source_game_se first, then
// source_game_le — and the first that validates (Data/Skyrim.esm present) is used. The
// edition is autodetected from the exe (SkyrimSE.exe / TESV.exe) and logged once. All
// parsers self-detect per file, so either edition slots into the same pipeline.
resolve_source :: proc(cfg: ^settings.Config) -> string {
	src := settings.get(cfg, "source_game")
	if src == "" {
		for key in ([]string{"source_game_se", "source_game_le"}) {
			if s := settings.get(cfg, key); s != "" && installer.valid_source(s) {
				src = s
				break
			}
		}
	}
	if src != "" && !source_logged {
		source_logged = true
		ed, ver := installer.detect_edition(src)
		switch ed {
		case .SE:
			kind := "Anniversary" if ver[0] == 1 && ver[1] >= 6 else "Special"
			log.infof("source: Skyrim %s Edition %d.%d.%d.%d (SkyrimSE.exe) — %s", kind, ver[0], ver[1], ver[2], ver[3], src)
		case .LE:
			log.infof("source: Skyrim Legendary Edition %d.%d.%d.%d (TESV.exe) — %s", ver[0], ver[1], ver[2], ver[3], src)
		case .Unknown:
			log.warnf("source: no SkyrimSE.exe/TESV.exe found (edition unknown) — %s", src)
		}
	}
	return src
}

@(private = "file")
source_logged: bool

// run_game is the game chassis: bring the session up (game_setup), run the frame loop
// (game_frame), tear it down in the one documented order (game_teardown — see game.odin).
// Reached once content/ is installed. Logging is already up; cfg is borrowed for the
// session; loader_alloc is the thread-safe heap for cross-thread loader allocations.
// Returns where the pause menu's Quit asked to go.
run_game :: proc(logging: ^slog.Logging, cfg: ^settings.Config, loader_alloc: runtime.Allocator, base: string) -> Quit_To {
	g: Game
	defer game_teardown(&g) // also after a failed/quit setup — tears down exactly what came up
	if !game_setup(&g, logging, cfg, loader_alloc, base) {
		return .Desktop
	}
	// --seconds N: quit after N seconds of play (with --skipmenu, an unattended run to profile).
	seconds := -1.0
	if i, found := slice.linear_search(os.args, "--seconds"); found && i + 1 < len(os.args) {
		seconds, _ = strconv.parse_f64(os.args[i + 1])
	}
	start := time.tick_now()
	for {
		if !platform.pump(&g.p) || g.quit != .Stay {
			break
		}
		if seconds >= 0 && time.duration_seconds(time.tick_since(start)) > seconds {
			break
		}
		game_frame(&g)
	}
	log.info("SkyMod shutting down")
	return g.quit
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
