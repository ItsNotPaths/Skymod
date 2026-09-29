package main

// The game session: the Game struct (the long-lived state that used to be ~40 locals of
// run_game), one-time game_setup, and the explicit ordered game_teardown. The per-frame
// body lives in game_frame.odin. Split per docs/run-game-refactor.md.
//
// TEARDOWN ORDER IS LOAD-BEARING. run_game used to encode it as a LIFO defer stack whose
// correctness depended on declaration order; game_teardown states it explicitly instead.
// The constraints, so edits don't re-derive them:
//   - scene_destroy runs BEFORE physics world_destroy (it removes each chunk's bodies
//     while the Jolt world is alive);
//   - stream_destroy runs BEFORE scene_destroy (worker stopped before the cache it feeds);
//   - the character capsule dies before traversal (it may be homed in an interior's world);
//   - the worldstate overlay outlives traversal (trav borrows, never owns it);
//   - ui_shutdown before render.shutdown (device still alive).
// game_setup can fail partway (window closed mid-load, Quit at the menu); Game.up records
// exactly what came up, and game_teardown destroys exactly that.

import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:sync"
import "core:sys/info"
import "core:thread"

import "../audio"
import "../ai"
import "../assetdb"
import "../collisions"
import "../combat"
import "../condfn"
import "../magic"
import "../conditions"
import "../detection"
import "../formid"
import "../gamedb"
import "../graphics"
import "../handoff"
import "../input"
import "../installer"
import smath "../math"
import "../mods"
import "../physics"
import "../platform"
import "../plugin"
import "../render"
import slog "../log"
import "../script"
import slua "../script/lua"
import "../settings"
import "../sight"
import "../sighthost"
import "../tools"
import "../vfs"
import "../world"
import "../worldstate"

RIVERWOOD_GX :: 5
RIVERWOOD_GY :: -11

// Player capsule + locomotion (Skyrim units ≈70/m). Height 2·(half+radius)=128 (~1.8m),
// eye ~116. Run ≈370 u/s (matches the old free-fly feel), sprint ≈600 — authentic-ish
// vanilla base speeds (exact values live in MOVT records; tunable here for now).
PLAYER_RADIUS :: f32(28)
PLAYER_HALF_H :: f32(36) // cylinder half-height
EYE_HEIGHT :: f32(116)
RUN_SPEED :: f32(370)
SPRINT_SPEED :: f32(600)
SNEAK_SPEED :: f32(222) // MOVT NPC_Sneaking_MT forward run

// Which subsystems game_setup brought up. game_teardown destroys exactly these, in the
// documented order — a partial setup (early Quit, failed init) tears down only what exists.
// Subsystems with their own liveness flag (phys_ok, char_ok, repl_ok, interiors_on) use it.
Game_Up :: struct {
	platform, render, ui, audio, loadui, hud, box, profile, vfs, db, scene, ws, formtable, traversal,
	console, marker, sreg: bool,
}

// Per-phase frame-time profile (ms summed over the diag window, averaged on print). Finds
// "what's eating fps": which phase's average grows as the session runs. frames = denominator.
Frame_Profile :: struct {
	frames:                int,
	stream, render, frame: f64, // accumulated ms; the sim's own time is Tick.prof
	// Per-pass CPU command-recording times (subset of render). `acquire` is the swapchain
	// acquire — it BLOCKS when the GPU is behind, so a high acquire with low pass times means
	// GPU-bound; high pass times mean CPU(draw-submission)-bound. Sum of passes + acquire vs
	// render shows how much is unattributed (scene_begin/end_frame/present).
	acquire, terrain, near, objdraw, grass, water, effects: f64,
}

// Slow-frame detector (diagnostic): snapshot of the accumulated phase timers at the previous
// frame end, so a >SLOW_FRAME_MS frame can be attributed to its phase (which ate the hitch).
Slow_Snap :: struct {
	stream, render, acquire: f64,
}

// Fixed simulation tick (docs/shipped.md §E). Logic and physics advance in whole
// TICK_DT steps; rendering runs at whatever rate the display gives us and interpolates on
// `alpha`. Jolt's solver is not timestep-independent, so a varying step made a 144 Hz machine
// and a 60 Hz machine converge differently — the step has to be constant.
TICK_HZ :: 60
TICK_DT :: f32(1) / f32(TICK_HZ)

// MAX_CATCH_UP_TICKS caps the sim's backlog after a hitch (Sim_Clock).
MAX_CATCH_UP_TICKS :: 5

// Tick is what the tick runs with: its scratch and its profile. Its clock is the sim's (Sim_Clock).
Tick :: struct {
	temp: runtime.Default_Temp_Allocator, // the tick's context.temp_allocator, wiped after each tick
	prof: Tick_Profile,
	cur:  Tick_Sample, // this tick's parts so far
}

Tick_Part :: enum {
	Commands,
	Jail,
	Follow,
	Activations,
	Scene,
	Locomotion,
	Nav,
	Actors,
	Detection,
	Combat,
	AI,
	Social,
	Offscreen,
	Projectiles,
	Window,
	Physics,
	Traversal,
	Audio,
	Script_Events,
	Scripts,
	Publish,
}

// Tick_Sample is one tick's ms per part.
Tick_Sample :: [Tick_Part]f32

// TICK_HISTORY is how many ticks the profiler graph shows.
TICK_HISTORY :: 4 * TICK_HZ

// PROF_REPORT_TICKS is how often the sim logs its costliest script handlers.
PROF_REPORT_TICKS :: 3 * TICK_HZ

// SLOW_TICK_MS is a tick that costs a shown frame: it logs its parts.
SLOW_TICK_MS :: f32(2000) / TICK_HZ

// Tick_Profile is the sim's time: running totals in ms, and the last ticks one by one.
Tick_Profile :: struct {
	ticks:  int,
	ms:     [Tick_Part]f64,
	events: [slua.Event_Step]f64, // Script_Events by step
	sight, conditions: f64, // the sight seam's calls and the condition plugins', inside the parts
	recent: [TICK_HISTORY]Tick_Sample, // a ring; tick n is at n % TICK_HISTORY
}

// prof_since is the ticks' totals between two of the sim's profiles.
prof_since :: proc(now, then: Tick_Profile) -> (p: Tick_Profile) {
	p.ticks = now.ticks - then.ticks
	for &ms, part in p.ms {ms = now.ms[part] - then.ms[part]}
	for &ms, s in p.events {ms = now.events[s] - then.events[s]}
	p.sight, p.conditions = now.sight - then.sight, now.conditions - then.conditions
	return
}

// Per-frame derived state, recomputed at the top of every game_frame and shared between the
// frame_* helpers (which run in a fixed order — see game_frame). Never outlives the frame.
Frame_State :: struct {
	st:                 world.Stats, // streamer snapshot (diag + overlay panel)
	insp_action:        tools.Inspect_Action, // what the inspector panel requested (overlay → traversal)
	in_interior:        bool, // the player is inside a full-screen interior this frame
	active_scene:       ^world.Scene, // the scene the player inhabits (exterior or interior)
	alpha:              f32, // how far past the newest snapshot's tick this frame draws, in ticks (0..1)
	mouse_cap, kb_cap:  bool, // ImGui owns the mouse/keyboard this frame
}

// Game is the whole session: everything that lives from setup to teardown. One instance,
// on run_game's stack, always passed as ^Game — several subsystems hold pointers INTO it
// (space.phys → phys, space.ws → ws, the REPL closure → noclip, save_bridge → save_ft),
// so its address must be stable for the session. Fields are declared in bring-up order.
// (hole game-struct-split :sev struct) Game holds main's view, menus, dev tools, tuning and the sim boundary in one struct; per-concern structs (Dev, Menus) would make each field's owner plain.
Game :: struct {
	// borrowed from main() for the whole session
	logging: ^slog.Logging,
	cfg:     ^settings.Config, // EFFECTIVE config: the root cfg for vanilla, else &cfg_overlay
	base:    string,

	// per-profile settings overlay: when a non-vanilla profile is active, a sparse
	// Config layered over the root (main's cfg). g.cfg points at it; owned here.
	cfg_overlay:  settings.Config,
	cfg_overlaid: bool,

	up: Game_Up,

	// platform + renderer
	p: platform.Platform,
	r: render.Renderer,
	audio: audio.Audio,

	// input: rebindable action manager (src/input). Driven each frame from the SDL
	// device state; the frame_* helpers query it (input.fired/held/axis3).
	imgr: input.Manager,

	// the load screen: the shared UI substrate session (ui_session.odin), persisted for the whole
	// session because it's invoked at boot AND mid-game (interior/city/F9 loads), driven by loadui.odin.
	loadui: UI_Session,

	// the in-world HUD: an always-on, non-interactive substrate session (hud.lua) drawn every
	// gameplay frame (hud.odin). Today it's the crosshair reticle + activation prompt; the seed of
	// the full hudmenu (compass, H/M/S bars) later.
	hud: UI_Session,

	// the message box (message_box.odin): an interactive session drawn in place of the HUD while open.
	box: Message_Box,

	// mod profile + save paths
	mprofile:       mods.Profile,
	plugins:        plugin.Plugins, // the mods' native plugins, lowest priority first
	saves_dir:      string,
	quicksave_path: string,

	// immutable game data
	v:  vfs.VFS,
	db: gamedb.DB,

	// physics + the exterior scene
	phys:       physics.World,
	phys_ok:    bool,
	scene:      world.Scene,
	collisions: collisions.Store, // every scene's model collision, for the sim (assetdb)

	// streaming + door traversal + experimental open-interiors
	streamer:     world.Streamer,
	interior:     world.Scene, // the interior main draws, while shown.interior != 0
	shown:        Place, // the place main draws: the last Evt_Place
	interiors:    world.Interiors,
	interiors_on: bool,

	// the sim's own state (sim.odin): only the tick, a script phase or a parked main touches it
	sim: Sim,

	// world-state save identity
	save_ft:     mods.Form_Table,
	save_bridge: worldstate.Form_Bridge,
	save_no:     u32,

	// main's view and controls
	cam:         Camera,
	actor_mesh:  render.Mesh, // last frame's NPC capsule mesh, released at the next draw
	graphics:    graphics.Table, // who draws the scene: the built-in or a plugin's
	hover_actor: Form_ID, // the actor under the Ctrl-hover cursor, 0 for none
	actor_grab:  Actor_Grab, // the dev carry (hold DevGrabActor)
	wheel:       f32, // main's running total of wheel notches, latched into Sim_Input
	zoom_in, zoom_out: u32, // times each fired, latched into Sim_Input

	// the boundary with the sim (sim.odin)
	commands:    handoff.Queue(Sim_Command), // what main asked of the sim since the last tick
	command_buf: [dynamic]Sim_Command, // the tick's drained copy
	events:      handoff.Queue(Sim_Event), // what the sim told main since main last looked
	console_in:  handoff.Queue(string), // console lines for the sim to evaluate (heap copies)
	console_in_buf:  [dynamic]string,
	console_out: handoff.Queue(string), // their output, back to main (heap copies)
	console_out_buf: [dynamic]string,
	snaps:       handoff.Latest(Snapshot), // the sim's newest snapshot, for main to take
	snap:        Snapshot, // the one main draws from
	parks:       int, // main's holds on the sim (sim_drain): while any, no tick runs
	menu_parked: bool, // one of those holds is an open menu's (park_for_menu)

	// menus
	menu:        Menu,    // the open placeholder menu (menus.odin)
	menu_target: Form_ID, // the container the container menu shows
	menu_pick:   [Pane]int, // the selected row of each list pane (menus.odin)
	quit:        Quit_To, // the pause menu's Quit: the main loop ends
	// Debug (open-interiors): when `entered`, we've loaded fully INTO the active portal's
	// interior cell (camera + picker operate in interior-local space) instead of viewing it
	// through the portal.
	entered:  bool,

	// scripting + dev console + inspector
	sreg:         script.Registry,
	repl_ok:      bool,
	simt:         Sim_Thread,
	console:      tools.Console,
	insp:         tools.Inspector,

	// debug verbs (drop-test balls, hitbox wireframe) + overlay visibility
	drop_marker:   render.Mesh,
	show_overlay:  bool, // ` toggles
	show_profiler: bool, // F3 toggles the tick graph
	show_hitboxes: bool, // K toggles
	dev_box:       int,  // N: the next box MESG dev_message_box opens
	pretty:        bool, // hide untextured marker placeholders; live-toggleable in Stats

	// tuning (from settings; fixed for the session)
	full_radius: int, // full-detail bubble (cell radii) — also the near-water/object-LOD seam
	grass_dist:  f32,
	// Live portal-camera tuning (debug sliders): how far past the doorway plane to clamp the
	// relay eye (clears the entrance wall) + a yaw offset on the relayed look direction.
	portal_push:    f32,
	portal_yaw_off: f32,

	// frame accounting
	tick:        Tick, // fixed-step sim clock (see Tick); game_frame drives it
	elapsed:     f32, // advances the effects phase
	diag_t:      f32, // throttle for the periodic memory/cache diagnostic log
	prof:        Frame_Profile,
	prev_bodies: int, // last diag window's body count — to flag a steady climb (leak)
	slowsnap:    Slow_Snap,
	tick_seen:   Tick_Profile, // the sim's profile totals at the last diag window

	fr: Frame_State,
}

// game_setup brings the whole session up: window → boot menus → gamedb → physics/scene →
// streaming/traversal → overlay/saves → scripting/console → the boot full-load. Returns
// false if the user quit at a boot screen or an init failed; game_teardown (run by the
// caller in both cases) destroys whatever `up` records.
game_setup :: proc(g: ^Game, logging: ^slog.Logging, cfg: ^settings.Config, loader_alloc: runtime.Allocator, base: string) -> bool {
	worldstate.sim_enter() // no sim runs yet: setup builds its state
	defer worldstate.sim_leave()
	g.logging, g.cfg, g.base = logging, cfg, base

	ok: bool
	g.p, ok = platform.init("SkyMod", WINDOW_W, WINDOW_H)
	if !ok {
		return false
	}
	g.up.platform = true

	rok: bool
	g.r, rok = render.init(g.p.window)
	if !rok {
		log.error("render init failed; exiting")
		return false
	}
	g.up.render = true

	render.ui_init(&g.r)
	g.up.ui = true
	g.p.on_event = render.ui_process_event

	audio.init(&g.audio) // no device: the game runs silent
	g.up.audio = true

	// Section F: STREAM Tamriel around Riverwood. VFS over the install's archives →
	// gamedb from Skyrim.esm → a Streamer keeps a window of cells loaded around the
	// player, decoding meshes on a worker thread (no hitches) and uploading them under
	// a per-frame budget. Fly out of the window and watch cells stream in/out.
	src := resolve_source(cfg)

	// Mod profile (docs/mods.md layer 4): the MO2-style mod list, persisted per profile as
	// <base>/profiles/<name>/modlist.txt; the mods/ folder is shared across all profiles.
	// Loaded, reconciled against the mod folders under <base>/mods (new folders enabled by
	// default), and used to build the VFS overlay + the derived plugin load order. The
	// mod-manager boot screen edits it; the world below builds from whichever is active.
	active_profile := settings.get(cfg, "active_profile")
	if active_profile == "" {
		active_profile = DEFAULT_PROFILE
	}
	ensure_profile_dir(base, active_profile)

	mods.profile_init(&g.mprofile)
	g.up.profile = true
	_ = mods.profile_load(&g.mprofile, modlist_path_for(base, active_profile))
	mods.profile_reconcile(&g.mprofile, discover_mod_folders(base, context.temp_allocator))
	mods.profile_set_system(&g.mprofile, system_mod_names(src, base)) // locked rows: Skyrim + DLCs + UI baseline

	// Quicksave path (needs only `base`) — read by the boot menu's save summary + the frame loop.
// (hole save-slots :tags save :sev gap) one flat quicksave slot and no per-character folders, so a second character overwrites the first.
	g.saves_dir, _ = filepath.join({base, "saves"})
	g.quicksave_path, _ = filepath.join({g.saves_dir, "quicksave.skysave"})

	// PRE-WORLD boot screens (preworld.odin): Main Menu ⇆ Mod Manager, shown BEFORE the world
	// builds. The mod manager edits the profile there, so mount/load below build from the FINAL
	// profile — enabling a mod and entering the world is seamless (no relaunch). The menu also
	// appears instantly on launch instead of after the stream. Records the player's choice; the
	// Continue save-apply runs after the world exists (further below).
	boot_choice := run_preworld(&g.p, &g.r, base, src, &g.mprofile, cfg, g.quicksave_path)
	if boot_choice == .Quit {
		return false
	}

	// The mod manager may have switched the active profile, so resolve settings AFTER the menu.
	// Per-profile overlay: vanilla uses the root cfg directly; any other profile layers its sparse
	// settings.txt over the root — g.cfg reads inherit vanilla, writes land in the profile. Built
	// before input_setup so the effective bind.<id> overrides (baseline ⊕ profile) resolve.
	final_profile := settings.get(cfg, "active_profile")
	if final_profile == "" {
		final_profile = DEFAULT_PROFILE
	}
	if final_profile != DEFAULT_PROFILE {
		ensure_profile_dir(base, final_profile)
		profile_dir, _ := filepath.join({base, PROFILES_DIRNAME, final_profile}, context.temp_allocator)
		g.cfg_overlay = settings.load_child(profile_dir, cfg)
		g.cfg = &g.cfg_overlay
		g.cfg_overlaid = true
	}
	// Input actions: register the default scheme + apply the effective settings' bind overrides.
	// Leaf subsystem (no window dep); destroyed in game_teardown.
	input_setup(&g.imgr, g.cfg)

	// VFS is cheap (BSA headers) — build it on the main thread.
	g.v = mount_game_mods(src, base, &g.mprofile)
	g.up.vfs = true

	// The load screen (Lua, on the shared UI substrate) — built now so it drives the gamedb-build bar
	// below too, then reused for the Tamriel full-load and every mid-game cell load. If it can't init
	// (font/atlas), loadui_frame falls back to the imgui load screen so boot still shows progress.
	g.up.loadui = loadui_init(g)

	// The gamedb build parses ~250 MB of masters (~20s of pure CPU). Run it on a worker thread while
	// the main thread animates a loading screen, so the post-menu build doesn't look frozen. The DB
	// is built in loader_alloc (thread-safe, like the streamer's cross-thread CPU bundles) and handed
	// back to the main thread, which owns + frees it.
	load_job := Game_Load_Job {
		src          = src,
		base         = base,
		profile      = &g.mprofile,
		vfs          = &g.v, // mounted above; the worker only reads (thread-safe like asset decode)
		loader_alloc = loader_alloc,
	}
	load_thread := thread.create(game_load_worker)
	load_thread.data = &load_job
	thread.start(load_thread)
	// The DB build is the FIRST 40% of one continuous load bar (the Tamriel stream+physics is 40→100%).
	// One Lua screen spans both — no more "two bars, first half sweeps".
	for !sync.atomic_load(&load_job.done) {
		done := sync.atomic_load(&load_job.progress.done)
		total := sync.atomic_load(&load_job.progress.total)
		frac := f32(0) // 0 until the total is known (the bar sits at the start, then fills to 0.40)
		if total > 0 {frac = 0.40 * f32(done) / f32(total)}
		if !loadui_frame(g, frac, "Loading game data…") {break} // window closed mid-load
	}
	thread.join(load_thread)
	thread.destroy(load_thread)
	if !load_job.ok {
		log.error("could not load Skyrim.esm; nothing to show")
		return false
	}
	g.db = load_job.db
	g.up.db = true

	// Static collision (ROADMAP §2e physics): a Jolt world the streamer fills with bhk*
	// bodies as cells load. Torn down AFTER scene_destroy — see game_teardown.
	g.phys, g.phys_ok = physics.world_create()

	g.scene = world.scene_init(&g.r, &g.v, &g.collisions)
	g.up.scene = true
	// Movable clutter (cups/plates/etc.) as DYNAMIC bodies in the exterior too — now that Jolt runs
	// double precision, far-from-origin dynamic bodies are safe (interiors already did this). Static
	// world geometry is unaffected (only CLUTTER/PROPS-layer, mass>0 shapes go dynamic).
	world.space_init(&g.sim.ext, &g.phys if g.phys_ok else nil, &g.collisions, &g.sim.ws, dynamic_clutter = g.phys_ok)
	g.scene.dynamic_clutter = g.phys_ok
	// pretty: hide the white untextured editor-marker placeholders (effect placements,
	// bird/patrol routes, X markers) that slip past the name filter. Initial state from
	// ./skymod --pretty (or pretty=true in settings); live-toggleable in the Stats panel and
	// pushed onto whichever scene we draw each frame (so it also reaches the active interior).
	g.pretty = slice.contains(os.args, "--pretty") || settings.get_bool(g.cfg, "pretty")
	g.scene.pretty = g.pretty
	if g.pretty {
		log.info("--pretty: hiding untextured marker placeholders (toggle in Stats)")
	}

	// The full-detail bubble in cell radii: the sim's live cells (near terrain + grass + full objects).
	// Terrain itself is whole-world CDLOD (no knob).
	g.full_radius = settings.get_int(g.cfg, "render_distance", 3)

	// Optional LOD falloff tuning (commented out in settings.txt by default — compiled defaults
	// here). terrain_lod_falloff = the quadtree coarsening factor (lower = finer distant terrain);
	// object_lod_falloff scales the per-ring object size cull (>1 = fewer/larger-only distant objects).
	world.terr_lod_k = settings.get_float(g.cfg, "terrain_lod_falloff", world.terr_lod_k)
	world.OBJ_LOD_FALLOFF = settings.get_float(g.cfg, "object_lod_falloff", world.OBJ_LOD_FALLOFF)
	world.TREE_LOD_FALLOFF = settings.get_float(g.cfg, "tree_lod_falloff", world.TREE_LOD_FALLOFF)
	// Baked distant-object LOD (object_lod.odin): which MNAM LOD band every distant static uses, and
	// the merge-quad size in cells (smaller = cleaner near transition + more draws). See settings.txt.
	world.OBJECT_LOD_BAND = settings.get_int(g.cfg, "object_lod_band", world.OBJECT_LOD_BAND)
	world.OBJECT_LOD_QUAD = i32(settings.get_int(g.cfg, "object_lod_quad", int(world.OBJECT_LOD_QUAD)))
	// CDLOD geomorph tuning (smooth terrain LOD transitions): falloff = how early in each band the
	// morph starts (lower = gentler), strength = morph amount (1 = crack-free, 0 = hard snaps).
	world.terr_geomorph_falloff = settings.get_float(g.cfg, "terrain_geomorph_falloff", world.terr_geomorph_falloff)
	world.terr_geomorph_strength = settings.get_float(g.cfg, "terrain_geomorph_strength", world.terr_geomorph_strength)
	world.terr_geomorph_distance = settings.get_float(g.cfg, "terrain_geomorph_distance", world.terr_geomorph_distance)
	// Fade the CDLOD height-drop out at the near-terrain edge: full drop under the lod-0 bubble
	// (so the near mesh wins), zero beyond it (so distant terrain sits at true height under the
	// distant water). full_radius cells of near terrain surround the player; ramp out over the
	// next cell. Keyed to render_distance so the sink is never visible past the near terrain.
	world.terr_drop_fade_start = f32(g.full_radius) * world.CELL_SIZE
	world.terr_drop_fade_band = world.CELL_SIZE

	// Texture resolution cap (0 = full): drops the DDS's own top mips at upload — a memory/
	// quality knob that matters most for high-res mod texture packs. World textures only
	// (models + terrain ground); the UI atlas paths don't go through the asset cache.
	assetdb.TEXTURE_MAX_DIM = settings.get_int(g.cfg, "texture_max_dim", 0)

	// D1 model-cache eviction budget (MB of zero-ref "cold" model payload kept warm before evicting
	// oldest-first). 0 (default) = eviction OFF — the cache stays monotonic. Ships DARK: the refcounts
	// run and the diag prints cold=N so acquire/release balance can be validated before a budget frees
	// anything. Set model_cache_mb=256 (~a few regions of backtracking warmth) once verified.
	assetdb.MODEL_CACHE_BYTES = settings.get_int(g.cfg, "model_cache_mb", 0) * 1024 * 1024

	// D1 slice 2: texture-cache eviction budget (MB of zero-ref, non-pinned cold texture payload kept
	// warm before evicting oldest-first). Textures are ~83% of a region's footprint, so this is the
	// real memory lever. 0 (default) = OFF (dark). Terrain-ground textures are pinned (never counted).
	assetdb.TEXTURE_CACHE_BYTES = settings.get_int(g.cfg, "texture_cache_mb", 0) * 1024 * 1024

	// Decode pool size. load_threads = 0 → auto (logical cores − 1, leaving the main thread a
	// core); an explicit value overrides. The heavy BSA+NIF+DDS decode is thread-safe, so more
	// threads fill the asset queue faster — the win is biggest during the initial full load.
	decode_threads := settings.get_int(g.cfg, "load_threads", 0)
	if decode_threads <= 0 {
		_, logical, cores_ok := info.cpu_core_count()
		decode_threads = max(logical - 1, 1) if cores_ok else 4
	}
	log.infof("stream: %d decode threads", decode_threads)

	g.grass_dist = f32(settings.get_int(g.cfg, "grass_distance", 8192)) // world units

	// EXPERIMENTAL (open-interiors foundation): when experimental_open_interiors is set, discover
	// the worldspace's load-door → interior links (build_portals) so the door alignment data is
	// available + visible in the overlay. The renderer that consumes these is a future stencil-
	// portal effort; the RTT prototype was removed. See the open-interiors-portal memory notes.
	open_interiors := settings.get_bool(g.cfg, "experimental_open_interiors")
	interior_dist := f32(settings.get_int(g.cfg, "interior_load_distance", 2048))
	g.portal_push = 32
	g.portal_yaw_off = 0

	// World-state overlay (Phase 3c): the mutable delta layer between immutable gamedb and the
	// transient scene. Moved clutter settles write here; cell loads patch from it (baseline ⊕
	// overlay). Lives for the whole session — outlives every cell stream AND traversal (which
	// borrows, never owns it). Before the spawn bubble builds, so its cells get the overlay.
	worldstate.init(&g.sim.ws)
	g.up.ws = true

	g.cam = Camera{yaw = 2.3, pitch = -0.3}
	if wfid, found := gamedb.find_world(&g.db, "Tamriel"); found {
		world.build_terrain_field(&g.scene, &g.db, wfid) // CDLOD whole-world height-texture terrain (backdrop tier)
		world.stream_init(&g.streamer, &g.scene, &g.db, wfid, loader_alloc, decode_threads)
		world.set_world(&g.sim.ext, &g.db, wfid, g.full_radius)
		if pos, sok := stream_spawn(&g.db, wfid, RIVERWOOD_GX, RIVERWOOD_GY); sok {
			g.cam.pos = pos
		}
		if open_interiors {
			world.interiors_init(&g.interiors, &g.scene, &g.db, &g.streamer, wfid, interior_dist)
			g.interiors_on = true
			log.infof("EXPERIMENTAL: open-interiors door discovery on (%d interiors linked)", len(g.interiors.portals))
		}
	} else {
		log.error("worldspace Tamriel not found")
	}
	// Now the DB + overlay exist: hand the load screen the real vanilla loading tips (LSCR DESC pool) +
	// the player level, so the Tamriel load bar below shows a rotating tip and "Level N".
	loadui_ready(g, gamedb.load_tips(&g.db), worldstate.player_level(&g.sim.ws, &g.db))
	// Form-table bridge: the identity remap that lets a save survive a load-order/cross-install change
	// (docs/saves.md §4.4). Loaded once for the session (the mod set is fixed after world build) and
	// handed to every save/load below so slots resolve to THIS install's forms.
	g.save_ft = load_form_table(base)
	g.up.formtable = true
	g.save_bridge = form_bridge(&g.save_ft)

	// Base door navigator: indexes the worldspace's load doors. Safe even if no worldspace armed
	// (no doors → inert).
	traversal_init(&g.sim.trav, &g.sim.ext, &g.db, &g.sim.ws)
	g.shown = g.sim.trav.place
	g.up.traversal = true

	// In-world HUD (crosshair reticle + activation prompt) — its own always-on substrate session.
	// Non-fatal if it fails to init (frame_hud becomes a no-op); the game still plays.
	g.up.hud = hud_init(g)
	g.up.box = message_box_init(g)

	// Dev command console (fixed bottom-left panel): a Lua REPL on the gameplay VM plus
	// CE aliases (tcl, player.additem, …). The panel is just the widget; the REPL that
	// backs it is built below (needs `noclip`/`ws`/`db`), which prints the ready banner.
	tools.console_init(&g.console)
	g.up.console = true

	// Dev overlay visibility — toggled by the ` (backtick/tilde) key. Off at start.
	g.show_overlay = false

	// Physics drop-test (B5): press G to spawn a falling ball at the camera; it's rendered
	// as a small box marker at its live body position so you can watch it land on the
	// streamed bhk* collision. Debug-only; markers persist until exit.
	g.drop_marker = make_marker_mesh(&g.r, 24)
	g.up.marker = true

	// The player walks in its actor body once the tick builds it at the spawn camera; V toggles
	// no-clip free-fly.
	g.sim.input.eye, g.sim.input.yaw = g.cam.pos, g.cam.yaw
	g.sim.noclip = !g.phys_ok
	publish_snapshot(g)

	// Gameplay script registry + the dev-console REPL on top of it (Phase 4). The REPL
	// evaluates typed console lines on the same VM transpiled scripts will run on, so
	// every registered native is a live command; it reads/writes the worldstate overlay
	// (`ws`) over the gamedb baseline (`db`). `&g.sim.noclip` lets the tcl/noclip command
	// toggle the frame loop's own free-fly flag (stable address — a Game field).
	trust: plugin.Trust
	trust_path, _ := filepath.join({base, plugin.TRUST_FILE}, context.temp_allocator)
	plugin.trust_load(&trust, trust_path)
	plugin.load(&g.plugins, mod_dirs(base, &g.mprofile, plugin.DIR), &trust)
	plugin.trust_destroy(&trust)
	g.sim.detection = detection.BUILTIN
	plugin.apply(&g.plugins, detection.SEAM, detection.VERSION, &g.sim.detection)
	g.sim.combat = combat.BUILTIN
	plugin.apply(&g.plugins, combat.SEAM, combat.VERSION, &g.sim.combat)
	plugin.apply(&g.plugins, sight.SEAM, sight.VERSION, &sighthost.table)
	plugin.apply(&g.plugins, condfn.SEAM, condfn.VERSION, &conditions.table)
	plugin.apply(&g.plugins, magic.SEAM, magic.VERSION, &script.magic_table)
	g.graphics = GRAPHICS_BUILTIN
	plugin.apply(&g.plugins, graphics.SEAM, graphics.VERSION, &g.graphics)
	script.init(&g.sreg)
	g.up.sreg = true
	g.repl_ok = console_repl_init(&g.sim.repl, &g.sreg, &g.sim.ws, &g.db, &g.audio, &g.v, &g.sim.noclip)
	if g.repl_ok {
		g.sim.agents.quest_vars = g.sim.repl.vm.ctx.quest_vars
		g.sim.agents.lua = {&g.sim.repl.vm, slua.run_procedure}
		g.sim.agents.furniture = {g, actor_furniture_markers}
		slua.repl_register_cmd(&g.sim.repl, "ai", "ai [ref] — an actor's package, tree nodes, mover and trip", console_cmd_ai, g)
		slua.repl_register_cmd(&g.sim.repl, "possess", "possess [ref] — control an actor; no ref and no selection = the start character", console_cmd_possess, g)
		slua.set_script_dirs(&g.sim.repl.vm, mod_dirs(base, &g.mprofile, installer.SCRIPTS_DIR))
		slua.set_profile(&g.sim.repl.vm, slice.contains(os.args, "--profile")) // prof.scripts: each handler's time
		rc_path, _ := filepath.join({base, "console.lua"}, context.temp_allocator)
		slua.repl_load_rc(&g.sim.repl, rc_path)
		tools.console_print(&g.console, "SkyMod console — Lua REPL on the gameplay VM. `cmd.help()` lists commands.")
	} else {
		log.error("console: REPL init failed; falling back to echo")
	}
	// Seed the capsule's home world to the exterior so frame 1 doesn't re-home.
	g.sim.cur_phys = g.sim.ext.phys

	// POST-WORLD: apply the Continue save now that the overlay + scene + streamer + character exist
	// (New Game = nothing to do; the overlay starts empty). The choice was made before world init,
	// so any mod the manager enabled already took effect in the build above — seamless, no relaunch.
	if boot_choice == .Continue {
		if m, mok := worldstate.load_from_file(&g.sim.ws, g.quicksave_path, &g.save_bridge); mok {
			g.save_no = m.save_number
			// Rebuild resident chunks (the pinned persistent cell) from baseline ⊕ the loaded overlay;
			// grid cells stream in afterward and pick it up on build.
			world.rebuild_resident_overlay(&g.sim.ext, &g.db)
			// Return to where they saved; this re-arms the spawn bubble (armed at the default spawn)
			// so the full-load screen below builds the right cells.
			player_restore(g)
			log.infof("menu: Continue — loaded %s (%d deltas)", g.quicksave_path, m.delta_count)
		}
	} else {
		log.info("menu: New Game")
	}
	plugin.load_data(&g.plugins, g.sim.ws.plugin_blobs) // a new game hands them none

	// Quests, aliases and persistent refs get their scripts: OnInit for the forms a Continue's save
	// does not know, saved members for the ones it does.
	if g.repl_ok {
		n := slua.start_game(&g.sim.repl.vm, &g.db) if boot_choice == .Continue else slua.new_game(&g.sim.repl.vm, &g.db)
		log.infof("scripts: %d game-start script instance(s), %d known to the save", n, len(g.sim.ws.script_state))
	}

	g.p.keep_escape = true // Esc opens the pause menu from here on
	log.info("Section F: Tamriel streaming around Riverwood. Mouse look, WASD/QE fly, LMB/RMB cast, Esc for the pause menu.")

	// Full-load screen: pump the decode pool + cook collision behind the loading screen until the
	// spawn bubble is fully resident + solid, THEN drop into gameplay — no empty-world pop-in. This is
	// the back 60% of the one continuous bar (the DB build was the front 40%).
	load_screen_stream(g, "Loading Tamriel…", 0.40, 0.60)
	sim_thread_start(g)
	return true
}

// game_teardown destroys whatever game_setup brought up, in the one true order (see the
// header comment for why each ordering exists). Safe after a partial setup: `up` gates
// every step. Replaces run_game's old declaration-order-is-load-bearing defer stack.
game_teardown :: proc(g: ^Game) {
	worldstate.sim_enter()
	defer worldstate.sim_leave()
	sim_thread_stop(g)
	runtime.default_temp_allocator_destroy(&g.tick.temp)
	handoff.destroy(&g.commands)
	delete(g.command_buf)
	for e in g.events.items {event_destroy(e)}
	handoff.destroy(&g.events)
	strings_queue_destroy(&g.console_in, &g.console_in_buf)
	strings_queue_destroy(&g.console_out, &g.console_out_buf)
	for s in ([]^Snapshot{&g.snaps.slot, &g.sim.snap_back, &g.snap}) {snapshot_destroy(s)}
	if g.repl_ok {slua.repl_destroy(&g.sim.repl)}
	slua.transitions_destroy(&g.sim.trans)
	if g.up.sreg {script.destroy(&g.sreg)}
	actor_bodies_clear(g) // may be homed in an interior world — before traversal
	delete(g.sim.actor_bodies)
	ai.destroy(&g.sim.agents)
	actor_snapshot_destroy(&g.sim.actors)
	plugin.destroy(&g.plugins)
	render.release_mesh(&g.r, g.actor_mesh)
	delete(g.sim.drops)
	delete(g.sim.talk.choices)
	if g.up.marker {render.release_mesh(&g.r, g.drop_marker)}
	tools.inspector_destroy(&g.insp) // frees the owned selection strings (safe on zero value)
	if g.up.console {tools.console_destroy(&g.console)}
	if g.up.traversal {
		world.stream_destroy(&g.streamer) // worker stopped before the cache it feeds (scene) is freed
		if g.shown.interior != 0 {world.scene_destroy(&g.interior)}
		traversal_destroy(&g.sim.trav) // frees the interior's cells + the door index
		if g.interiors_on {world.interiors_destroy(&g.interiors)} // before scene_destroy
	}
	if g.up.formtable {mods.formtable_destroy(&g.save_ft)}
	if g.up.ws {worldstate.destroy(&g.sim.ws)} // outlives traversal (trav borrows the overlay)
	if g.up.scene {world.scene_destroy(&g.scene)} // removes chunk bodies while the phys world lives
	world.space_destroy(&g.sim.ext)
	collisions.destroy(&g.collisions) // after every scene that reads it
	if g.phys_ok {
		physics.world_destroy(&g.phys)
		physics.shutdown()
	}
	if g.up.db {gamedb.destroy(&g.db)}
	if g.up.vfs {vfs.destroy(&g.v)}
	delete(g.quicksave_path)
	delete(g.saves_dir)
	if g.up.profile {mods.profile_destroy(&g.mprofile)}
	if g.up.box {message_box_destroy(g)}
	if g.up.hud {hud_destroy(g)} // releases the HUD atlas/UI textures — before render.shutdown (device alive)
	if g.up.loadui {loadui_destroy(g)} // releases the atlas/UI textures — before render.shutdown (device alive)
	if g.up.ui {render.ui_shutdown(&g.r)} // before render.shutdown — device still alive
	if g.up.render {render.shutdown(&g.r)}
	if g.up.audio {
		audio.ambient_destroy(&g.sim.ambient)
		audio.shutdown(&g.audio)
	}
	input.destroy(&g.imgr) // leaf; safe on a zero-value manager
	if g.cfg_overlaid {settings.destroy(&g.cfg_overlay)} // frees only its own overrides, not the root
	if g.up.platform {platform.shutdown(&g.p)}
}

// Game_Load_Job carries the threaded gamedb build (run while the loading screen animates). The DB
// is built in loader_alloc — a thread-safe heap — so it's safe to hand back to the main thread,
// which owns and frees it. `done` is the atomically-published completion flag.
@(private = "file")
Game_Load_Job :: struct {
	src, base:    string,
	profile:      ^mods.Profile,
	vfs:          ^vfs.VFS, // mounted before the worker spawns; concurrent read-only use (like the asset decoders)
	loader_alloc: runtime.Allocator,
	db:           gamedb.DB,
	ok:           bool,
	done:         bool,
	progress:     Load_Progress, // byte progress, published by the build for the loading bar
}

// game_load_worker runs load_gamedb_mods on a worker thread (all allocations in loader_alloc, off
// the main thread's tracking allocator), then publishes `done`.
@(private = "file")
game_load_worker :: proc(t: ^thread.Thread) {
	job := (^Game_Load_Job)(t.data)
	context.allocator = job.loader_alloc
	job.db, job.ok = load_gamedb_mods(job.src, job.base, job.profile, job.vfs, &job.progress)
	sync.atomic_store(&job.done, true)
}

// make_marker_mesh builds a small box mesh (half-size `h`) for the drop-test: a marker drawn
// at each falling ball's live physics position. Per-corner normals (= normalized corner) give
// it readable shading under the lit mesh shader. 8 verts, 12 triangles.
make_marker_mesh :: proc(r: ^render.Renderer, h: f32) -> render.Mesh {
	c := [8][3]f32 {
		{-h, -h, -h}, {h, -h, -h}, {h, h, -h}, {-h, h, -h},
		{-h, -h, h}, {h, -h, h}, {h, h, h}, {-h, h, h},
	}
	verts: [8]render.Mesh_Vertex
	for i in 0 ..< 8 {
		n := smath.normalize3(c[i])
		verts[i] = render.mesh_vertex(c[i], n, {0, 0})
	}
	idx := [36]u16 {
		0, 1, 2, 0, 2, 3, // z-
		4, 6, 5, 4, 7, 6, // z+
		0, 5, 1, 0, 4, 5, // y-
		3, 2, 6, 3, 6, 7, // y+
		0, 3, 7, 0, 7, 4, // x-
		1, 5, 6, 1, 6, 2, // x+
	}
	return render.upload_mesh(r, verts[:], idx[:])
}
