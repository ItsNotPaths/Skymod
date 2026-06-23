package main

// The test-bed executable (ROADMAP Phase 0). It wires the platform layer to the
// renderer and runs the frame loop — and imports NEITHER SDL nor SDL3_gpu: the
// window/input come from `platform`, all drawing goes through `render`, the camera
// math through `math`, the dev UI widgets through `tools`, logging through `log`.
// That is the render-abstraction boundary the project leans on.
//
// Phase 0 progress: window (step 2) + textured cube (step 4) + free-fly debug
// camera (step 5) + Dear ImGui overlay (step 6) + logging (step 7).

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"

import "../gamedb"
import "../installer"
import "../platform"
import "../render"
import slog "../log"
import "../settings"
import "../tools"
import "../vfs"
import "../world"

WINDOW_W :: 1280
WINDOW_H :: 720

main :: proc() {
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

	run_game(&logging, &cfg)
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

// run_game holds the Phase 0 chassis: window (step 2) + textured cube (step 4) +
// free-fly debug camera (step 5) + Dear ImGui overlay (step 6) + logging (step 7).
// Reached once content/ is installed. Logging is already up; cfg is borrowed for
// any future window/gameplay settings.
run_game :: proc(logging: ^slog.Logging, cfg: ^settings.Config) {
	p, ok := platform.init("SkyMod", WINDOW_W, WINDOW_H)
	if !ok {
		return
	}
	defer platform.shutdown(&p)

	r, rok := render.init(p.window)
	if !rok {
		log.error("render init failed; exiting")
		return
	}
	defer render.shutdown(&r)

	render.ui_init(&r)
	defer render.ui_shutdown(&r) // runs before render.shutdown (LIFO) — device still alive
	p.on_event = render.ui_process_event

	// Section E: load Whiterun's exterior worldspace and fly the city. VFS over the
	// install's archives → gamedb from Skyrim.esm → world places every cell's REFRs at
	// their (absolute worldspace) transforms, one chunk per cell (assetdb caches/dedups).
	// Building doors still work: walk to one + F enters the interior (Milestone D path).
	src := settings.get(cfg, "source_game")
	v := mount_game(src)
	defer vfs.destroy(&v)

	db, db_ok := load_gamedb(src)
	if !db_ok {
		log.error("could not load Skyrim.esm; nothing to show")
		return
	}
	defer gamedb.destroy(&db)

	scene := world.scene_init(&r, &v)
	defer world.scene_destroy(&scene)
	if wfid, found := gamedb.find_world(&db, "WhiterunWorld"); found {
		world.load_worldspace(&scene, &db, wfid)
	} else {
		log.error("worldspace WhiterunWorld not found")
	}

	// Spawn above the city centre, angled down to survey it (no-clip: fly with WASD/QE).
	cam := Camera{yaw = 0.0, pitch = -0.3}
	if pos, ok := world.spawn(&scene); ok {
		cam.pos = pos
	}

	// Model inspector: walk up to a door for the "Go Through" prompt; left-click any
	// model to inspect it. near_door tracks the nearest in-range load door (the F /
	// button target), recomputed each frame after the camera moves.
	insp: tools.Inspector
	DOOR_RANGE :: f32(600) // activation radius (Skyrim units) around a load door
	near_door_id: u32
	near_ok: bool

	log.info("Section E: Whiterun exterior. RMB look, WASD/QE fly, walk to a door + F to go through, Esc to quit.")

	for platform.pump(&p) {
		render.ui_new_frame(&r)
		if tools.debug_overlay(p.dt, logging.persisting, logging.persist_path) {
			if slog.persist_run(logging) {
				context.logger = logging.logger // re-install: persist_run added a sink
			}
		}
		go_through := tools.inspector_panel(&insp)
		tools.crosshair()

		// Don't let the camera react while the UI has the mouse/keyboard.
		mouse_cap, kb_cap := render.ui_capturing(&r)

		// Door transition: the "Go Through" button or the F key, on the nearest
		// in-range load door. Reloads the scene and drops the camera at the dest door.
		if (go_through || (p.input.activate && !kb_cap)) && near_ok {
			if pos, yaw, tok := enter_door(&scene, &db, &r, &v, near_door_id); tok {
				cam.pos, cam.yaw, cam.pitch = pos, yaw, -0.1
				insp = {}
				near_ok = false
			}
		}

		move, look := p.input.move, p.input.look
		if kb_cap {move = {}}
		if mouse_cap {look = {}}
		camera_update(&cam, move, look, p.input.fast, p.dt)

		// Refresh the proximity door prompt for the next frame's panel.
		near_ok = false
		insp.near_door = false
		if nd, dist, ok := world.nearest_door(&scene, cam.pos); ok && dist < DOOR_RANGE {
			near_ok = true
			near_door_id = nd.tp_door
			insp.near_door = true
			insp.near_door_cell = ""
			if dref, dok := gamedb.ref_by_formid(&db, nd.tp_door); dok {
				if dc, cok := gamedb.cell_by_formid(&db, dref.cell_form_id); cok && dc.interior {
					insp.near_door_cell = dc.editor_id
				}
			}
		}

		// Left-click aims the crosshair (camera forward) and picks a model.
		if p.input.select && !mouse_cap {
			if inst, ok := world.pick(&scene, cam.pos, camera_forward(cam)); ok {
				insp.has_sel = true
				insp.sel_name = inst.model.path
				insp.sel_base = inst.base
				insp.sel_pos = inst.pos
				insp.sel_rot = inst.rot
				insp.sel_has_door = inst.has_tp
				insp.sel_door_cell = ""
				if inst.has_tp {
					if dref, dok := gamedb.ref_by_formid(&db, inst.tp_door); dok {
						if dc, cok := gamedb.cell_by_formid(&db, dref.cell_form_id); cok && dc.interior {
							insp.sel_door_cell = dc.editor_id
						}
					}
				}
			}
		}

		if render.begin_frame(&r, {0.10, 0.11, 0.13, 1.0}) {
			vp := camera_view_proj(cam, render.aspect(&r))
			world.draw(&scene, &r, vp)
			render.end_frame(&r)
		}

		// POLICY (docs/memory.md): anything on context.temp_allocator lives for
		// exactly one frame — UI string formatting, draw lists, transient buffers.
		// Wiped here, every frame.
		free_all(context.temp_allocator)
	}

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
