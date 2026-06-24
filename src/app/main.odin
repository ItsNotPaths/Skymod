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
import "core:slice"
import "core:sys/info"

import "../gamedb"
import "../installer"
import smath "../math"
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

	scene := world.scene_init(&r, &v)
	defer world.scene_destroy(&scene) // runs AFTER stream_destroy (LIFO) — worker stopped first
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
	// Full-detail radius (objects+grass+textured terrain) and the outer terrain-LOD
	// radius, behind the render_distance / lod_distance settings. Cells between them
	// stream as terrain-only, downsampled coarser with distance.
	full_radius := settings.get_int(cfg, "render_distance", 2)
	lod_radius := max(settings.get_int(cfg, "lod_distance", 24), full_radius)
	obj_radius := settings.get_int(cfg, "object_lod_distance", 8)

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
		world.build_far_terrain(&scene, &db, wfid) // whole-world coarse backdrop (visible from anywhere)
		world.stream_init(&streamer, &scene, &db, wfid, lod_radius, full_radius, obj_radius, loader_alloc, decode_threads)
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
	// Base door navigator: borrows the exterior scene + streamer (whatever their state) and
	// indexes the worldspace's load doors. Safe even if no worldspace armed (no doors → inert).
	traversal_init(&trav, &scene, &streamer, &db, &v, &r)
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

	// Debug: when `entered`, we've loaded fully INTO the active portal's interior cell (camera +
	// picker operate in interior-local space) instead of viewing it through the portal — for
	// inspecting what's in the room (e.g. the door panel). INTERIOR_EYE = camera height above the
	// arrival marker / exterior door when entering / exiting.
	entered := false
	INTERIOR_EYE :: f32(96)

	log.info("Section F: Tamriel streaming around Riverwood. RMB look, WASD/QE fly, Esc to quit.")

	// Full-load screen: pump the decode pool at full tilt and show a progress bar until the
	// spawn bubble is fully resident, THEN drop into the gameplay loop — no empty-world-then-
	// pop-in. Stays responsive (input pumps, ESC/close work) since each iteration presents.
	for world.stream_loading(&streamer) && platform.pump(&p) {
		render.ui_new_frame(&r)
		done, total, _ := world.stream_pump_load(&streamer)
		tools.loading_screen("Loading Tamriel…", done, total)
		if render.begin_frame(&r, {0.05, 0.06, 0.08, 1.0}) {
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)
	}

	for platform.pump(&p) {
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
			log.infof(
				"diag: cell (%d,%d) chunks=%d cache models=%d tex=%d rss=%dMB",
				st.gx, st.gy, st.chunks, mc, tc, proc_rss_mb(),
			)
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

		mouse_cap, kb_cap := render.ui_capturing(&r)
		move, look := p.input.move, p.input.look
		if kb_cap {move = {}}
		if mouse_cap {look = {}}
		camera_update(&cam, move, look, p.input.fast, p.dt)

		// Which scene the player inhabits this frame + whether it's a full-screen interior
		// (the streamer is paused there). The experimental open-interiors path keeps its own
		// debug walk-in (`entered`); the base path is driven by the Traversal door navigator.
		in_interior: bool
		active_scene: ^world.Scene
		if interiors_on {
			in_interior = entered
			if entered {
				active_scene = &interiors.interior_scene
			} else {
				active_scene = &scene
			}
		} else {
			in_interior = trav.mode == .Interior
			active_scene = traversal_scene(&trav)
		}
		// Live pretty toggle: apply to the exterior + whichever scene we draw this frame (draw
		// reads scene.pretty each frame, so this takes effect immediately).
		scene.pretty = pretty
		active_scene.pretty = pretty

		// Stream the exterior window around the (now-moved) camera — unless we're inside an
		// interior (camera is in interior-local space; the streamer is paused). Re-windows on
		// cell crossing, uploads decoded models under the per-frame budget. Never blocks.
		if !in_interior {
			world.stream_update(&streamer, cam.pos)
			if interiors_on {
				// Open interiors (EXPERIMENTAL): keep the nearest in-range portal's interior
				// loaded (GPU work, so outside begin_frame). Rendered through the doorway below.
				world.interiors_update(&interiors, cam.pos)
			}
		}

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
		if render.frame_acquire(&r) {
			if shadows_on {
				for c in 0 ..< render.SHADOW_CASCADES {
					render.shadow_cascade(&r, c)
					// Cap casters to the shadow region (+1 cell margin for tall off-slice casters).
					world.draw_casters(&scene, &r, cascades.vp[c], cascades.frusta[c], cam.pos, shadow_dist + 4096, vmode)
					render.shadow_cascade_end(&r)
				}
			}
			render.scene_begin(&r, {sky.x, sky.y, sky.z, 1.0})
			vp := camera_view_proj(cam, render.aspect(&r))
			if in_interior {
				// Inside a loaded interior cell (interior-local coords): draw it full-screen.
				world.draw(active_scene, &r, vp)
				world.draw_effects(active_scene, &r, vp, elapsed)
				world.draw_highlight(active_scene, &r, vp)
			} else {
				world.draw_far_terrain(&scene, &r, vp) // whole-world coarse backdrop (drawn under detail)
				world.draw(&scene, &r, vp, wind, elapsed) // trees + foliage sway under the global wind
				world.draw_objects(&scene, &r, vp, wind, elapsed) // distant instanced statics + their veg (LOD rings)
				if grass_dist > 0 {
					world.draw_grass(&scene, &r, vp, cam.pos, grass_dist, wind, elapsed)
				}
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
				world.draw_water(&scene, &r, vp, cam.pos, elapsed) // flat per-cell water planes (transparent, over opaque)
				world.draw_effects(&scene, &r, vp, elapsed) // additive FX (flowing water/fire/beams), over opaque (last)
				world.draw_highlight(&scene, &r, vp, wind, elapsed) // inspect-mode hover highlight
			}
			render.end_frame(&r)
		}

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
