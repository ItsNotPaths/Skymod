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
import "core:math"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:sys/info"
import "core:time"

import "../gamedb"
import "../installer"
import smath "../math"
import "../physics"
import "../platform"
import "../render"
import slog "../log"
import "../settings"
import "../tools"
import "../vfs"
import "../world"
import "../worldstate"

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

	// Dev: `--lodtest` skips straight to the BSLODTriShape LOD test grid (needs
	// source_game set; mounts the archives directly, no install/streaming).
	if slice.contains(os.args, "--lodtest") {
		run_lod_test(&cfg)
		return
	}

	// Dev: `--doortest` opens the single-door sandbox for the open-interiors door rig
	// (swing the hinge, find the open pose). Needs source_game; mounts archives directly.
	if slice.contains(os.args, "--doortest") {
		run_door_test(&cfg)
		return
	}

	// Dev: `--phystest` runs the headless Jolt smoke (drop a sphere on a floor, log it
	// settling) — proves the vendor/build/static-link/FFI chain. No window/assets.
	if slice.contains(os.args, "--phystest") {
		run_phys_test()
		return
	}

	// Dev: `--celltest` loads a small static grid of cells around Riverwood with collision
	// (no streaming/LOD/shadows) — a cheap scene to debug physics. G drops balls.
	if slice.contains(os.args, "--celltest") {
		run_cell_test(&cfg)
		return
	}

	// Dev: `--terraintest` headlessly drops a sphere onto the Riverwood terrain trimesh and
	// logs whether it rests or falls through — isolates the terrain collision path.
	if slice.contains(os.args, "--terraintest") {
		run_terrain_test(&cfg)
		return
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

// run_game holds the Phase 0 chassis: window (step 2) + textured cube (step 4) +
// free-fly debug camera (step 5) + Dear ImGui overlay (step 6) + logging (step 7).
// Reached once content/ is installed. Logging is already up; cfg is borrowed for
// any future window/gameplay settings.
run_game :: proc(logging: ^slog.Logging, cfg: ^settings.Config, loader_alloc: runtime.Allocator, base: string) {
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

	// Section F: STREAM Tamriel around Riverwood. VFS over the install's archives →
	// gamedb from Skyrim.esm → a Streamer keeps a window of cells loaded around the
	// player, decoding meshes on a worker thread (no hitches) and uploading them under
	// a per-frame budget. Fly out of the window and watch cells stream in/out.
	src := settings.get(cfg, "source_game")
	v := mount_game(src)
	defer vfs.destroy(&v)

	db, db_ok := load_gamedb(src)
	if !db_ok {
		log.error("could not load Skyrim.esm; nothing to show")
		return
	}
	defer gamedb.destroy(&db)

	// Static collision (ROADMAP §2e physics): a Jolt world the streamer fills with bhk*
	// bodies as cells load. Declared BEFORE the scene so its teardown runs AFTER
	// scene_destroy (LIFO) — scene_destroy removes each chunk's bodies while the world lives.
	phys, phys_ok := physics.world_create()
	defer if phys_ok {physics.world_destroy(&phys);physics.shutdown()}

	scene := world.scene_init(&r, &v)
	defer world.scene_destroy(&scene) // runs AFTER stream_destroy (LIFO) — worker stopped first
	if phys_ok {scene.phys = &phys}
	// pretty: hide the white untextured editor-marker placeholders (effect placements,
	// bird/patrol routes, X markers) that slip past the name filter. Initial state from
	// ./skymod --pretty (or pretty=true in settings); live-toggleable in the Stats panel and
	// pushed onto whichever scene we draw each frame (so it also reaches the active interior).
	pretty := slice.contains(os.args, "--pretty") || settings.get_bool(cfg, "pretty")
	scene.pretty = pretty
	if pretty {
		log.info("--pretty: hiding untextured marker placeholders (toggle in Stats)")
	}

	RIVERWOOD_GX :: 5
	RIVERWOOD_GY :: -11
	// LOD distances (cell radii): full-detail bubble (near terrain + grass + full objects), and how
	// far Skyrim's prebaked object-LOD meshes reach. Terrain itself is whole-world CDLOD (no knob).
	full_radius := settings.get_int(cfg, "render_distance", 2)
	obj_radius := settings.get_int(cfg, "object_lod_distance", 24)
	// Tree billboards are the cheap far-far tier — their own reach (cells), defaulting to the object
	// reach so an unset value never shrinks trees below the statics. Set it higher to fill the horizon.
	tree_radius := settings.get_int(cfg, "tree_lod_distance", obj_radius)

	// Optional LOD falloff tuning (commented out in settings.txt by default — compiled defaults
	// here). terrain_lod_falloff = the quadtree coarsening factor (lower = finer distant terrain);
	// object_lod_falloff scales the per-ring object size cull (>1 = fewer/larger-only distant objects).
	world.terr_lod_k = settings.get_float(cfg, "terrain_lod_falloff", world.terr_lod_k)
	world.OBJ_LOD_FALLOFF = settings.get_float(cfg, "object_lod_falloff", world.OBJ_LOD_FALLOFF)
	world.TREE_LOD_FALLOFF = settings.get_float(cfg, "tree_lod_falloff", world.TREE_LOD_FALLOFF)
	// Baked distant-object LOD (object_lod.odin): which MNAM LOD band every distant static uses, and
	// the merge-quad size in cells (smaller = cleaner near transition + more draws). See settings.txt.
	world.OBJECT_LOD_BAND = settings.get_int(cfg, "object_lod_band", world.OBJECT_LOD_BAND)
	world.OBJECT_LOD_QUAD = i32(settings.get_int(cfg, "object_lod_quad", int(world.OBJECT_LOD_QUAD)))
	// CDLOD geomorph tuning (smooth terrain LOD transitions): falloff = how early in each band the
	// morph starts (lower = gentler), strength = morph amount (1 = crack-free, 0 = hard snaps).
	world.terr_geomorph_falloff = settings.get_float(cfg, "terrain_geomorph_falloff", world.terr_geomorph_falloff)
	world.terr_geomorph_strength = settings.get_float(cfg, "terrain_geomorph_strength", world.terr_geomorph_strength)
	world.terr_geomorph_distance = settings.get_float(cfg, "terrain_geomorph_distance", world.terr_geomorph_distance)
	// Fade the CDLOD height-drop out at the near-terrain edge: full drop under the lod-0 bubble
	// (so the near mesh wins), zero beyond it (so distant terrain sits at true height under the
	// distant water). full_radius cells of near terrain surround the player; ramp out over the
	// next cell. Keyed to render_distance so the sink is never visible past the near terrain.
	world.terr_drop_fade_start = f32(full_radius) * world.CELL_SIZE
	world.terr_drop_fade_band = world.CELL_SIZE

	// Decode pool size. load_threads = 0 → auto (logical cores − 1, leaving the main thread a
	// core); an explicit value overrides. The heavy BSA+NIF+DDS decode is thread-safe, so more
	// threads fill the asset queue faster — the win is biggest during the initial full load.
	decode_threads := settings.get_int(cfg, "load_threads", 0)
	if decode_threads <= 0 {
		_, logical, cores_ok := info.cpu_core_count()
		decode_threads = max(logical - 1, 1) if cores_ok else 4
	}
	log.infof("stream: %d decode threads", decode_threads)

	// Grass draw distance (world units) + a basic, reusable wind (a future HDT-SMP-style
	// sim would drive/replace the procedural sway). `elapsed` advances the wind phase.
	grass_dist := f32(settings.get_int(cfg, "grass_distance", 8192))
	shadow_dist := f32(settings.get_int(cfg, "shadow_distance", 20000))
	wind := render.Wind{dir = {0.7, 0.7}, strength = 0.12, speed = 2.2}
	elapsed: f32
	diag_t: f32 // throttle for the periodic memory/cache diagnostic log
	// Per-phase frame-time profile (ms summed over the diag window, averaged on print). Finds
	// "what's eating fps": which phase's average grows as the session runs. frames = denominator.
	prof: struct {
		frames:                      int,
		stream, phys, render, frame: f64, // accumulated ms
		// Per-pass CPU command-recording times (subset of render). `acquire` is the swapchain
		// acquire — it BLOCKS when the GPU is behind, so a high acquire with low pass times means
		// GPU-bound; high pass times mean CPU(draw-submission)-bound. Sum of passes + acquire vs
		// render shows how much is unattributed (scene_begin/end_frame/present).
		acquire, shadow, terrain, near, objdraw, grass, water, effects: f64,
	}
	prev_bodies: int // last window's body count — to flag a steady climb (leak)

	// Scene lighting (ROADMAP full-scene-lighting Phases A/B): once, derive a data-faithful
	// "skyrim" profile from the user's own Skyrim.esm imagespace (local, never shipped), then
	// load the active profile (baked "vanilla"/"realistic", the derived "skyrim", or any sidecar
	// under <base>/profiles/). Live-editable via the Lighting panel; pushed each frame below.
	ensure_game_lighting_profile(base, settings.get(cfg, "source_game"))
	lights := lighting_state_init(base, settings.get(cfg, "lighting_profile"))
	defer lighting_state_destroy(&lights)

	// EXPERIMENTAL (open-interiors foundation): when experimental_open_interiors is set, discover
	// the worldspace's load-door → interior links (build_portals) so the door alignment data is
	// available + visible in the overlay. The renderer that consumes these is a future stencil-
	// portal effort; the RTT prototype was removed. See the open-interiors-portal memory notes.
	open_interiors := settings.get_bool(cfg, "experimental_open_interiors")
	interior_dist := f32(settings.get_int(cfg, "interior_load_distance", 2048))
	// Live portal-camera tuning (debug sliders): how far past the doorway plane to clamp the
	// relay eye (clears the entrance wall) + a yaw offset on the relayed look direction.
	portal_push: f32 = 32
	portal_yaw_off: f32 = 0

	cam := Camera{yaw = 2.3, pitch = -0.3}
	streamer: world.Streamer
	trav: Traversal // base door traversal (exterior ↔ interior); independent of open-interiors
	interiors: world.Interiors
	interiors_on := false
	if wfid, found := gamedb.find_world(&db, "Tamriel"); found {
		world.build_terrain_field(&scene, &db, wfid) // CDLOD whole-world height-texture terrain (backdrop tier)
		world.stream_init(&streamer, &scene, &db, wfid, full_radius, obj_radius, tree_radius, loader_alloc, decode_threads)
		if pos, sok := stream_spawn(&db, wfid, RIVERWOOD_GX, RIVERWOOD_GY); sok {
			cam.pos = pos
		}
		world.stream_begin_load(&streamer, cam.pos) // arm full-load: build the spawn bubble up front
		if open_interiors {
			world.interiors_init(&interiors, &scene, &db, &streamer, wfid, interior_dist)
			interiors_on = true
			log.infof("EXPERIMENTAL: open-interiors door discovery on (%d interiors linked)", len(interiors.portals))
		}
	} else {
		log.error("worldspace Tamriel not found")
	}
	// World-state overlay (Phase 3c): the mutable delta layer between immutable gamedb and the
	// transient scene. Moved clutter settles write here; cell loads patch from it (baseline ⊕
	// overlay). Lives for the whole session — outlives every cell stream. Declared BEFORE trav so
	// its teardown runs AFTER traversal_destroy (LIFO); the overlay is borrowed, never owned by trav.
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	// Quicksave file beside the binary (<base>/saves/), created on first save (§4.2).
	saves_dir, _ := filepath.join({base, "saves"})
	defer delete(saves_dir)
	quicksave_path, _ := filepath.join({saves_dir, "quicksave.skysave"})
	defer delete(quicksave_path)
	save_no: u32

	// Base door navigator: borrows the exterior scene + streamer (whatever their state) and
	// indexes the worldspace's load doors. Safe even if no worldspace armed (no doors → inert).
	traversal_init(&trav, &scene, &streamer, &db, &v, &r, &ws)
	defer if interiors_on {world.interiors_destroy(&interiors)} // before scene_destroy (LIFO)
	defer traversal_destroy(&trav) // frees any loaded interior + the door index
	defer world.stream_destroy(&streamer)

	// Left-click a model to inspect it (handy for confirming what streamed in).
	insp: tools.Inspector

	// Dev command console (fixed bottom-left panel): the seat for the command system to come —
	// our own semantics plus CE aliases (tcl, player.additem, …). Today it only echoes.
	console: tools.Console
	tools.console_init(&console)
	defer tools.console_destroy(&console)
	tools.console_print(&console, "SkyMod console — type a command and press Enter. (command system not wired yet)")

	// Dev overlay visibility — toggled by the ` (backtick/tilde) key. On by default.
	show_overlay := true

	// Physics drop-test (B5): press G to spawn a falling ball at the camera; it's rendered
	// as a small box marker at its live body position so you can watch it land on the
	// streamed bhk* collision. Debug-only; markers persist until exit.
	drop_marker := make_marker_mesh(&r, 24)
	defer render.release_mesh(&r, drop_marker)
	drops: [dynamic]physics.Body
	defer delete(drops)

	// Player character: walk the streamed exterior under gravity, colliding with terrain +
	// objects. Spawns at the camera; V toggles no-clip free-fly (and inside interiors, which
	// have no collision yet, locomotion falls back to free-fly automatically).
	character: physics.Character
	char_ok: bool
	if phys_ok {
		character, char_ok = physics.character_create(&phys, cam.pos, PLAYER_RADIUS, PLAYER_HALF_H)
	}
	defer if char_ok {physics.character_destroy(&character)}
	noclip := !char_ok
	// The physics world the `character` capsule currently lives in. The player walks the EXTERIOR
	// `phys` until a load door swaps the active scene to an interior (its own world); on each swap
	// the capsule is re-homed (destroy + recreate) into the new world. Seeded to the exterior so
	// frame 1 doesn't re-home. nil when physics is off (free-fly).
	cur_phys := scene.phys

	// Debug: when `entered`, we've loaded fully INTO the active portal's interior cell (camera +
	// picker operate in interior-local space) instead of viewing it through the portal — for
	// inspecting what's in the room (e.g. the door panel). INTERIOR_EYE = camera height above the
	// arrival marker / exterior door when entering / exiting.
	entered := false
	INTERIOR_EYE :: f32(96)

	// Main menu (Phase 3d): Continue (load the quicksave into the overlay) / New Game (fresh) / Quit,
	// shown over a cleared frame before the world streams in. Continue only pre-fills the overlay —
	// the player still spawns at Riverwood (player-position persistence is a later overlay category),
	// so saved interior clutter is in place the moment you step into a cell.
	{
		save_summary := ""
		has_save := false
		if man, ok := worldstate.read_manifest(quicksave_path); ok {
			has_save = true
			save_summary = fmt.tprintf("Save %d — %d change(s)", man.save_number, man.delta_count)
		}
		choice := tools.Menu_Action.None
		for choice == .None && platform.pump(&p) {
			render.ui_new_frame(&r)
			choice = tools.main_menu_screen(has_save, save_summary)
			if render.begin_frame(&r, {0.05, 0.06, 0.08, 1.0}) {
				render.end_frame(&r)
			}
			free_all(context.temp_allocator)
		}
		#partial switch choice {
		case .Continue:
			if m, ok := worldstate.load_from_file(&ws, quicksave_path); ok {
				save_no = m.save_number
				log.infof("menu: Continue — loaded %s (%d deltas)", quicksave_path, m.delta_count)
			}
		case .New:
			log.info("menu: New Game")
		case .None, .Quit:
			return // window closed or Quit
		}
	}

	log.info("Section F: Tamriel streaming around Riverwood. RMB look, WASD/QE fly, Esc to quit.")

	// Full-load screen: pump the decode pool at full tilt and show a progress bar until the
	// spawn bubble is fully resident, THEN drop into the gameplay loop — no empty-world-then-
	// pop-in. Stays responsive (input pumps, ESC/close work) since each iteration presents.
	for world.stream_loading(&streamer) && platform.pump(&p) {
		render.ui_new_frame(&r)
		done, total, _ := world.stream_pump_load(&streamer)
		// Cook collision for models that just uploaded, in step with the bubble fill — so the
		// spawn world is solid the instant gameplay starts instead of collision trickling in at
		// PHYS_BUDGET/frame for ~30s afterward. Generous budget (no gameplay frame to protect),
		// and each iteration still presents so the progress bar + ESC stay live.
		if phys_ok {
			world.sync_physics(&scene, &scene.cache, budget = 128)
		}
		tools.loading_screen("Loading Tamriel…", done, total)
		if render.begin_frame(&r, {0.05, 0.06, 0.08, 1.0}) {
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)
	}
	// Bubble resident: finish any collision the per-iteration budget didn't reach, then optimize
	// the broadphase ONCE before the first step — Jolt's quad-tree must be rebuilt after a bulk
	// static-body add or every step degrades. Mirrors the interior path (enter_interior).
	if phys_ok {
		for world.sync_physics(&scene, &scene.cache, budget = max(int)) > 0 {}
		physics.optimize_broadphase(&phys)
	}

	for platform.pump(&p) {
		frame_t0 := time.tick_now() // profile: whole-frame busy time (see `prof`)
		render.ui_new_frame(&r)
		if p.input.toggle_overlay {
			show_overlay = !show_overlay
		}

		st := world.stream_stats(&streamer)
		// Periodic memory/cache probe (run with --persist-logs to keep the trail across a crash):
		// climbing RSS/cache = a leak; flat RSS at the crash points elsewhere (e.g. a GPU hazard).
		// Runs regardless of overlay visibility (it's a background crash trail, not a panel).
		diag_t += p.dt
		if diag_t >= 3 {
			diag_t = 0
			mc, tc := world.cache_counts(&scene)
			lob, lor := world.lod_object_stats(&scene)
			ps := world.phys_stats(&scene) // the exterior — where the streaming-churn leak would be
			log.infof(
				"diag: cell (%d,%d) chunks=%d cache models=%d tex=%d lodobj=%d/%d rss=%dMB",
				st.gx, st.gy, st.chunks, mc, tc, lor, lob, proc_rss_mb(),
			)
			// Frame-time profile (avg ms over the window) — the phase whose avg climbs is the
			// fps eater. n = frames sampled. inv := 1/n.
			if prof.frames > 0 {
				inv := 1.0 / f64(prof.frames)
				log.infof(
					"prof: frame=%.2fms stream=%.2f phys=%.2f render=%.2f (avg/%d frames)",
					prof.frame * inv, prof.stream * inv, prof.phys * inv, prof.render * inv, prof.frames,
				)
				// Render breakdown (ms): acquire = GPU-bound stall; the rest are CPU draw-submission
				// per pass. If acquire ≫ passes, we're GPU-bound (fix = fewer/cheaper draws + verts);
				// if passes dominate, CPU-bound (fix = fewer draw calls / less iteration).
				log.infof(
					"prof.render: acquire=%.2f shadow=%.2f terrain=%.2f near=%.2f objdraw=%.2f grass=%.2f water=%.2f effects=%.2f",
					prof.acquire * inv, prof.shadow * inv, prof.terrain * inv, prof.near * inv,
					prof.objdraw * inv, prof.grass * inv, prof.water * inv, prof.effects * inv,
				)
			}
			prof = {}
			// Leak probe: bodies/instances should be FLAT when the player stands still. dΔ is the
			// change since the last window — a persistent + climb with no movement = a missing
			// release path (chunks not freeing bodies, instances re-accumulating).
			log.infof(
				"leak: bodies=%d (Δ%+d) dyn=%d instances=%d built=%d chunks=%d",
				ps.bodies, ps.bodies - prev_bodies, ps.dyn, ps.instances, ps.built, ps.chunks,
			)
			prev_bodies = ps.bodies
		}

		// The whole dev overlay (` toggles it). Hidden = no panels, so ImGui captures nothing
		// and the camera/door keys drive the bare scene; the game-logic keys (F, etc.) are
		// independent of the panels and keep working below.
		insp_action: tools.Inspect_Action
		if show_overlay {
			if tools.debug_overlay(p.dt, logging.persisting, logging.persist_path, &pretty) {
				if slog.persist_run(logging) {
					context.logger = logging.logger // re-install: persist_run added a sink
				}
			}
			tools.stream_panel(st.gx, st.gy, st.chunks, st.inflight, st.reqs, st.ready)
			if interiors_on {
				is := world.interiors_stats(&interiors, cam.pos)
				act := tools.interiors_panel(
					is.portals,
					is.load_dist,
					is.nearest_dist,
					&portal_push,
					&portal_yaw_off,
					interiors.active,
					entered,
				)
				#partial switch act {
				case .Enter:
					if interiors.active {
						pp := interiors.active_portal
						into := world.into_room_dir(pp)
						cam.pos = pp.tp_pos + smath.Vec3{0, 0, INTERIOR_EYE}
						cam.yaw = math.atan2(into.y, into.x)
						cam.pitch = 0
						entered = true
						log.infof("interiors: loaded INTO cell 0x%08X (debug walk-in)", pp.int_cell)
					}
				case .Exit:
					pp := interiors.active_portal
					cam.pos = pp.door_pos - smath.scale3(pp.ext_dir, 160) + smath.Vec3{0, 0, INTERIOR_EYE}
					cam.yaw = math.atan2(pp.ext_dir.y, pp.ext_dir.x)
					cam.pitch = -0.1
					entered = false
					log.info("interiors: exited to exterior")
				}
			}
			insp_action = tools.inspector_panel(&insp)
			if insp_action == .Cull_Tex && interiors_on {
				world.interiors_add_cull_tex(&interiors, insp.sel_tex)
			}

			// Lighting configurator: live-edit the active profile, switch profiles, or save.
			light_act := tools.lighting_panel(&lights.active, lights.names[:], lights.current)
			if light_act.select >= 0 && light_act.select != lights.current {
				lighting_select(&lights, light_act.select)
				settings.set(cfg, "lighting_profile", lights.names[lights.current])
				_ = settings.save(cfg)
			}
			if light_act.save {
				if lighting_save(&lights) {
					log.infof("lighting: saved profile %q", lights.names[lights.current])
				}
			}

			// Dev console: echo submitted commands for now (CE-alias dispatch is future work).
			if cmd := tools.console_panel(&console); cmd != "" {
				tools.console_printf(&console, "> %s", cmd)
				tools.console_printf(&console, "unknown command (command system not wired yet)")
				log.infof("console: %q", cmd)
			}
		}

		// Which scene the player inhabits this frame + whether it's a full-screen interior (the
		// streamer is paused there). The experimental open-interiors path keeps its own debug
		// walk-in (`entered`); the base path is driven by the Traversal door navigator. Computed
		// BEFORE locomotion so the capsule re-homes into the active world before it's moved.
		in_interior: bool
		active_scene: ^world.Scene
		if interiors_on {
			in_interior = entered
			active_scene = &interiors.interior_scene if entered else &scene
		} else {
			in_interior = trav.mode == .Interior
			active_scene = traversal_scene(&trav)
		}
		// Live pretty toggle: apply to the exterior + whichever scene we draw this frame (draw
		// reads scene.pretty each frame, so this takes effect immediately).
		scene.pretty = pretty
		active_scene.pretty = pretty

		// Re-home the player capsule into the active scene's physics world. On a door transition
		// the active world changes (exterior `phys` ↔ an interior's own world); destroy the old
		// capsule and recreate it in the new world at the camera. A nil active world (physics off,
		// or the experimental portal interior, which has none) → no capsule → free-fly.
		want_phys := active_scene.phys
		if want_phys != cur_phys {
			if char_ok {physics.character_destroy(&character);char_ok = false}
			if want_phys != nil {
				character, char_ok = physics.character_create(want_phys, cam.pos, PLAYER_RADIUS, PLAYER_HALF_H)
				if !char_ok {noclip = true}
			}
			cur_phys = want_phys
		}

		mouse_cap, kb_cap := render.ui_capturing(&r)
		move, look := p.input.move, p.input.look
		if kb_cap {move = {}}
		if mouse_cap {look = {}}

		if p.input.noclip {noclip = !noclip}
		if char_ok && !noclip {
			// Walk: mouse look + camera-relative WASD on the capsule, Shift sprint, Space jump —
			// in whichever world the capsule is homed to (exterior terrain/objects or the interior).
			cam.yaw -= look.x * LOOK_SENSITIVITY
			cam.pitch = clamp(cam.pitch - look.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
			cy, sy := math.cos(cam.yaw), math.sin(cam.yaw)
			dir := [2]f32{cy * move.x + sy * move.y, sy * move.x - cy * move.y}
			mag := math.sqrt(dir.x * dir.x + dir.y * dir.y)
			speed := SPRINT_SPEED if p.input.fast else RUN_SPEED
			hv: [2]f32
			if mag > 0.001 {hv = {dir.x / mag * speed, dir.y / mag * speed}}
			physics.character_move(cur_phys, &character, hv, move.z > 0.5, min(p.dt, f32(1.0 / 30.0)))
			cam.pos = physics.character_position(&character) + {0, 0, EYE_HEIGHT}
		} else {
			camera_update(&cam, move, look, p.input.fast, p.dt)
			if char_ok {physics.character_set_position(&character, cam.pos)} // keep the body under the free camera
		}

		// Drop-test: G spawns a falling ball at the camera (physics verification). Exterior only —
		// the markers below read positions from `phys`, so a ball dropped inside an interior (a
		// different world) wouldn't track; gate it to the exterior to avoid the confusion.
		if phys_ok && p.input.drop && !kb_cap && !in_interior {
			b := physics.add_sphere(&phys, 24, cam.pos, is_dynamic = true)
			if b != 0 {append(&drops, b)}
			log.infof("drop-test: ball %d at (%.0f, %.0f, %.0f)", len(drops), cam.pos.x, cam.pos.y, cam.pos.z)
		}

		// Shove-test (H): kick nearby movable clutter so it scatters and resettles — a visible check
		// of the 3b dynamic-body path (interiors only, where clutter is dynamic).
		if p.input.shove && !kb_cap {
			if n := world.shove_clutter(active_scene, cam.pos, 400); n > 0 {
				log.infof("shove: kicked %d clutter bodies", n)
			}
		}

		// Quicksave (F5) / quickload (F9) — Phase 3d. Save writes the overlay to a .skysave; load
		// reads it back and, when inside a base-traversal interior, reloads the cell so moved clutter
		// snaps to the loaded positions immediately. Exterior loads apply on the next interior entry.
		if p.input.quicksave && !kb_cap {
			_ = os.make_directory(saves_dir) // idempotent (errors harmlessly if it exists)
			cell := trav.cur_int_cell if (!interiors_on && trav.mode == .Interior) else u32(0)
			man := worldstate.Save_Manifest {
				save_number  = save_no + 1,
				created_unix = time.to_unix_nanoseconds(time.now()),
				game_cell    = cell,
			}
			if worldstate.save_to_file(&ws, quicksave_path, man) {
				save_no += 1
				log.infof("quicksave: wrote %s (%d deltas)", quicksave_path, worldstate.count(&ws))
			} else {
				log.errorf("quicksave: FAILED to write %s", quicksave_path)
			}
		}
		if p.input.quickload && !kb_cap {
			if m, ok := worldstate.load_from_file(&ws, quicksave_path); ok {
				log.infof("quickload: loaded %s (%d deltas)", quicksave_path, m.delta_count)
				if !interiors_on {
					traversal_reload(&trav) // re-apply the loaded overlay to the live interior
				}
			} else {
				log.warnf("quickload: no valid save at %s", quicksave_path)
			}
		}

		// Stream the exterior window around the (now-moved) camera — unless we're inside an
		// interior (camera is in interior-local space; the streamer is paused). Re-windows on
		// cell crossing, uploads decoded models under the per-frame budget. Never blocks.
		t_stream := time.tick_now()
		if !in_interior {
			world.stream_update(&streamer, cam.pos)
			world.update_terrain_field(&scene, cam.pos) // re-select CDLOD terrain LOD on move
			if interiors_on {
				// Open interiors (EXPERIMENTAL): keep the nearest in-range portal's interior
				// loaded (GPU work, so outside begin_frame). Rendered through the doorway below.
				world.interiors_update(&interiors, cam.pos)
			}
		}
		prof.stream += time.duration_milliseconds(time.tick_since(t_stream))
		// Physics (Phase 2e): build collision bodies for newly-resolved instances of the ACTIVE
		// world (streamed exterior, or the interior cell) then advance THAT world's sim. dt clamped
		// so a hitch can't explode the step. Interiors prebuild their bodies on entry (enter_interior),
		// so sync_physics here is a no-op for them; the exterior keeps building as cells stream in.
		t_phys := time.tick_now()
		if cur_phys != nil {
			// New cells streaming in add static bodies; rebuild the broadphase the frames they
			// do (made > 0) so the quad-tree stays balanced — without this the exterior tree
			// degrades with every incremental add and the step time climbs steadily. Interiors
			// build + optimize on entry, so sync_physics is a no-op there and this never fires.
			if world.sync_physics(active_scene, &active_scene.cache) > 0 {
				physics.optimize_broadphase(cur_phys)
			}
			physics.step(cur_phys, min(p.dt, f32(1.0 / 30.0)))
			world.capture_settles(active_scene) // overlay: snapshot clutter that just came to rest (3c)
		}
		prof.phys += time.duration_milliseconds(time.tick_since(t_phys))

		// Base door traversal: auto-load doors (cave/dungeon entrances) cross on PROXIMITY;
		// manual doors (real meshes, incl. cross-worldspace city gates) arm a prompt and cross
		// on F / the panel button. Covers interior, interior→interior, exterior return, and
		// cross-worldspace gates.
		if !interiors_on {
			traversal_arrival_update(&trav, cam.pos) // re-arm auto-fire once clear of the last landing
			hit := traversal_nearest_door(&trav, cam.pos)
			crossed := false
			// Auto-load: fire on proximity (no key), suppressed right after a transition.
			if hit.ok && hit.auto && hit.dist <= AUTO_DOOR_RANGE && !trav.has_arrival {
				if np, nyaw, gok := go_through(&trav, hit); gok {
					cam.pos, cam.yaw, cam.pitch = np, nyaw, 0
					crossed = true
				}
			}
			// Manual: prompt + F / button (skip for auto doors — they have no visible mesh).
			insp.near_door = hit.ok && !hit.auto && !crossed
			insp.near_door_cell = door_dest_label(&trav, hit.tp_door) if insp.near_door else ""
			if insp.near_door && insp.near_door_cell != "" && (p.input.activate || insp_action == .Go_Through) {
				if np, nyaw, gok := go_through(&trav, hit); gok {
					cam.pos, cam.yaw, cam.pitch = np, nyaw, 0
				}
			}
		}

		// A portal interior is loaded and (when not entered) viewed through the doorway.
		interior_active := interiors_on && interiors.active

		// Inspect mode: hold Ctrl to highlight the model under the mouse cursor (a ray
		// through the cursor, not the screen centre); left-click selects the highlighted
		// one for the Inspector panel. Skip while ImGui owns the mouse.
		world.clear_hover(active_scene)
		if p.input.hover && !mouse_cap {
			ro, rd := camera_ray(cam, render.aspect(&r), p.input.mouse_ndc)
			if inst, shp, hok := world.hover_pick(active_scene, ro, rd); hok && p.input.select {
				world.select_instance(active_scene)
				insp.has_sel = true
				insp.sel_name = inst.model.path
				insp.sel_base = inst.base
				insp.sel_pos = inst.pos
				insp.sel_rot = inst.rot
				insp.sel_has_door = inst.has_tp
				insp.sel_door_cell = ""
				insp.sel_tex = inst.model.shapes[shp].diffuse_path if shp >= 0 && shp < len(inst.model.shapes) else ""
				insp.sel_is_door = gamedb.is_door(&db, inst.base)
			}
		}

		elapsed += p.dt

		// Scene lighting + sun shadows. Build the env; if shadows are on (exterior only — interiors
		// have no sun), compute the cascades + fold them in for sampling. The cascade caster passes
		// run on the FRAME command buffer between frame_acquire and scene_begin, so the shadow-array
		// write → sampler read is one command buffer and SDL3_gpu inserts the barrier (a separate
		// shadow cmd buffer faulted the Intel Vulkan driver).
		t_render := time.tick_now()
		env := lighting_env(&lights.active, cam.pos)
		shadows_on := shadow_dist > 0 && lights.active.shadow_strength > 0 && !in_interior
		cascades: Cascades
		vmode := world.Veg_Shadow_Mode.Proxy
		if shadows_on {
			cascades = compute_cascades(cam, render.aspect(&r), lights.active.sun_dir, shadow_dist)
			for i in 0 ..< render.SHADOW_CASCADES {
				env.csm_vp[i] = cascades.vp[i]
				env.csm_splits[i] = cascades.splits[i]
			}
			texel := lights.active.shadow_softness / f32(render.SHADOW_RES)
			env.shadow_params = {
				lights.active.shadow_strength,
				lights.active.shadow_bias,
				texel,
				f32(render.SHADOW_CASCADES),
			}
			// Vegetation shadow tier comes from the active lighting profile (per-preset, live).
			switch lights.active.veg_shadows {
			case .Off:
				vmode = .Off
			case .Full:
				vmode = .Full
			case .Proxy:
				vmode = .Proxy
			}
		}
		render.set_lighting(&r, env)
		render.set_post(&r, lighting_post(&lights.active))
		sky := lights.active.sky_color
		t_acq := time.tick_now()
		acquired := render.frame_acquire(&r) // blocks here if the GPU is behind → GPU-bound shows up in `acquire`
		prof.acquire += time.duration_milliseconds(time.tick_since(t_acq))
		if acquired {
			// Snapshot the drawn scene's chunks into its flat per-frame list once (Fix A): every
			// draw/shadow pass below iterates that tight array instead of walking the chunk MAP and
			// streaming its big inline Chunk values through cache ~9×/frame. The interior path draws
			// active_scene; the shadow cascades + exterior passes draw &scene.
			world.cull_begin(active_scene if in_interior else &scene)
			t_shadow := time.tick_now()
			if shadows_on {
				for c in 0 ..< render.SHADOW_CASCADES {
					render.shadow_cascade(&r, c)
					// Cap casters to the shadow region (+1 cell margin for tall off-slice casters).
					world.draw_casters(&scene, &r, cascades.vp[c], cascades.frusta[c], cam.pos, shadow_dist + 4096, vmode)
					render.shadow_cascade_end(&r)
				}
			}
			prof.shadow += time.duration_milliseconds(time.tick_since(t_shadow))
			render.scene_begin(&r, {sky.x, sky.y, sky.z, 1.0})
			vp := camera_view_proj(cam, render.aspect(&r))
			if in_interior {
				// Inside a loaded interior cell (interior-local coords): draw it full-screen.
				world.draw(active_scene, &r, vp)
				world.draw_effects(active_scene, &r, vp, elapsed)
				world.draw_highlight(active_scene, &r, vp)
			} else {
				t_terrain := time.tick_now()
				world.draw_terrain_field(&scene, &r, vp, cam.pos) // CDLOD whole-world terrain (drawn under streamed detail)
				prof.terrain += time.duration_milliseconds(time.tick_since(t_terrain))
				t_near := time.tick_now()
				world.draw(&scene, &r, vp, wind, elapsed) // trees + foliage sway under the global wind
				prof.near += time.duration_milliseconds(time.tick_since(t_near))
				// Drop-test markers: a box at each falling ball's live physics position.
				for b in drops {
					bp := physics.body_position(&phys, b)
					render.draw_mesh(&r, drop_marker, vp, smath.translate({bp.x, bp.y, bp.z}), {})
				}
				t_objdraw := time.tick_now()
				world.draw_object_lod(&scene, &r, vp, cam.pos, full_radius, wind, elapsed) // baked per-quad distant objects
				prof.objdraw += time.duration_milliseconds(time.tick_since(t_objdraw))
				t_grass := time.tick_now()
				if grass_dist > 0 {
					world.draw_grass(&scene, &r, vp, cam.pos, grass_dist, wind, elapsed)
				}
				prof.grass += time.duration_milliseconds(time.tick_since(t_grass))
				// Stencil portal: render the nearest in-range interior THROUGH its doorway, from a
				// virtual camera relayed into interior space. After exterior opaque geometry (so a
				// wall in front of the door hides it), before the translucent effect pass.
				if interior_active {
					relay := world.relay_view_proj(
						interiors.active_portal,
						cam.pos,
						camera_forward(cam),
						render.aspect(&r),
						CAM_FOV_Y,
						CAM_NEAR,
						CAM_FAR,
						portal_push,
						portal_yaw_off,
					)
					world.interiors_render(&interiors, &r, vp, relay)
				}
				t_water := time.tick_now()
				world.draw_water_lod(&scene, &r, vp, cam.pos, full_radius, elapsed) // baked distant water (per-quad, real heights)
				world.draw_water(&scene, &r, vp, cam.pos, elapsed) // near animated per-cell water (bubble), over the distant
				prof.water += time.duration_milliseconds(time.tick_since(t_water))
				t_effects := time.tick_now()
				world.draw_effects(&scene, &r, vp, elapsed) // additive FX (flowing water/fire/beams), over opaque (last)
				prof.effects += time.duration_milliseconds(time.tick_since(t_effects))
				world.draw_highlight(&scene, &r, vp, wind, elapsed) // inspect-mode hover highlight
			}
			render.end_frame(&r)
		}
		prof.render += time.duration_milliseconds(time.tick_since(t_render))
		prof.frame += time.duration_milliseconds(time.tick_since(frame_t0))
		prof.frames += 1

		// POLICY (docs/memory.md): anything on context.temp_allocator lives for
		// exactly one frame — UI string formatting, draw lists, transient buffers.
		// Wiped here, every frame.
		free_all(context.temp_allocator)
	}

	log.info("SkyMod shutting down")
}

// proc_rss_mb reads this process's resident set size (MB) from /proc/self/statm (Linux) — the
// 2nd field is resident pages × 4 KiB. Returns -1 if unavailable. A diagnostic probe for the
// extended-flight segfault (is memory climbing?).
proc_rss_mb :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/statm", context.temp_allocator)
	if err != nil || len(data) == 0 {
		return -1
	}
	s := string(data)
	i := 0
	for i < len(s) && s[i] != ' ' {i += 1} // skip field 0 (total program size)
	for i < len(s) && s[i] == ' ' {i += 1}
	n := 0
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		n = n * 10 + int(s[i] - '0')
		i += 1
	}
	return n * 4096 / (1024 * 1024)
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
