package main

// The load screen DRIVER: a thin, non-interactive loop over the shared UI substrate (UI_Session +
// the `engine` host API). The screen itself is pure Lua (loading_menu.lua); this file only owns the
// session's lifetime and publishes progress into the host each frame. It replaces the old imgui
// run_load_screen / tools.loading_screen so EVERY load path shares ONE Lua screen:
//   • boot: the gamedb build (0..0.40) then the Tamriel full-load (0.40..1.0) — one continuous bar;
//   • mid-game: entering an interior (real per-instance progress) or a city gate (streamer progress);
//   • F9 quickload.
// The menu's UI_Session is stack-local (menu.odin); this one lives on Game (loadui_init in game_setup,
// loadui_destroy in game_teardown) because the load screen is invoked mid-session from the frame loop.

import "core:log"
import "core:time"
import "../physics"
import "../platform"
import "../render"
import "../tools"
import "../world"

@(private = "file")
LOAD_CLEAR :: [4]f32{0, 0, 0, 1.0} // opaque black behind the load screen (the world isn't drawn)

@(private = "file")
TIP_SECS :: f32(6) // seconds each loading tip is shown before rotating to the next

// loadui_init opens the persistent load-screen session (baseui synthesized + chrome extracted, atlas
// built, VM on loading_menu.lua). ok=false (a missing font/atlas) leaves g.loadui.ok false — loadui_frame
// then falls back to the pre-existing imgui load screen so boot still shows progress.
loadui_init :: proc(g: ^Game) -> bool {
	if !baseui_ensure(g.base) {
		return false
	}
	baseui_extract_assets(&g.v, g.base) // install-time: SWF-embedded UI art → DDS in bethassets (idempotent)
	g.loadui.host.load_level = 1
	return ui_session_open(&g.loadui, &g.r, &g.v, g.base, "loading_menu.lua")
}

loadui_destroy :: proc(g: ^Game) {
	ui_session_close(&g.loadui)
}

// loadui_hide clears the load screen's quads from the renderer so gameplay stops compositing them. The
// load session PERSISTS (reused for later cell loads), so — unlike the menu, which is torn down on exit —
// we must clear the UI drawlist explicitly when a load FINISHES, or the last load frame stays painted
// over the world forever (the "load screen never exits" bug). Called at the end of every load path.
loadui_hide :: proc(g: ^Game) {
	render.set_ui_drawlist(&g.r, {}, {}, {}, {})
}

// loadui_ready seeds the tip pool + player level once the gamedb + worldstate exist (after the DB
// build). Before this the screen shows the bar with no tips (guarded in Lua).
//
// TIP-SCOPE: today this takes the FLAT tip pool. To context-weight, the load driver would instead pass
// the load DESTINATION (worldspace + location form — known at each go_through / stream_begin_load site)
// and this would call gamedb.load_tips_for(&g.db, world, loc) so the shown tips match where you're going.
loadui_ready :: proc(g: ^Game, tips: []string, level: i32) {
	g.loadui.host.load_tips = tips
	g.loadui.host.load_level = max(level, 1)
	log.infof("loadui: %d loading tips decoded, player level %d", len(tips), g.loadui.host.load_level)
}

// loadui_interior_progress is the world→app trampoline for a synchronous interior load (wired onto the
// Traversal via traversal_set_progress): each call redraws the shared load screen at `frac`. `user` is
// the ^Game. This is what lets an interior/dungeon door show a real progress bar instead of a freeze.
loadui_interior_progress :: proc "odin" (user: rawptr, frac: f32) {
	g := cast(^Game)user
	loadui_frame(g, frac, "Loading interior…")
}

// loadui_frame draws one load-screen frame and returns false if the window closed (quit). It publishes
// (frac, phase) into the host, rotates the tip, and redraws the Lua screen over a cleared frame. The
// imgui NewFrame/Render pair MUST balance every iteration (Lua or fallback), or the next screen asserts.
loadui_frame :: proc(g: ^Game, frac: f32, phase: string) -> bool {
	alive := platform.pump(&g.p)
	render.ui_new_frame(&g.r)

	if g.loadui.ok {
		w, h := ui_screen_size()
		g.loadui.host.load_frac = clamp(frac, 0, 1)
		g.loadui.host.load_phase = phase
		loadui_rotate_tip(g)
		ui_session_draw(&g.loadui, w, h)
	} else {
		// No Lua context (font/atlas failed) — reuse the pre-existing imgui load screen so boot still works.
		anim := f32(time.duration_seconds(time.tick_since(g.loadui.start)))
		tools.loading_screen_busy(phase, anim, frac)
	}

	if render.begin_frame(&g.r, LOAD_CLEAR) {
		render.end_frame(&g.r)
	}
	free_all(context.temp_allocator)
	return alive
}

// loadui_rotate_tip advances the shown loading tip every TIP_SECS (off the platform delta).
@(private = "file")
loadui_rotate_tip :: proc(g: ^Game) {
	if len(g.loadui.host.load_tips) == 0 {
		return
	}
	g.loadui.host.load_tip_t += g.p.dt
	if g.loadui.host.load_tip_t >= TIP_SECS {
		g.loadui.host.load_tip_t = 0
		g.loadui.host.load_tip_i = (g.loadui.host.load_tip_i + 1) % len(g.loadui.host.load_tips)
	}
}

// load_screen_stream runs the shared decode-pool + physics-cook loop behind the load screen, mapping the
// streamer's model progress into [base_frac, base_frac+span]. Used for the boot Tamriel load, city gates,
// and F9 quickload — every path that fills the streamer's bubble. Drains remaining collision + rebuilds
// the broadphase once at the end so gameplay resumes on a solid world (as the old run_load_screen did).
load_screen_stream :: proc(g: ^Game, phase: string, base_frac, span: f32) {
	for world.stream_loading(&g.streamer) {
		done, total, _ := world.stream_pump_load(&g.streamer)
		if g.phys_ok {
			world.sync_physics(&g.scene, &g.scene.cache, budget = 128)
		}
		f := base_frac
		if total > 0 {
			f = base_frac + span * (f32(done) / f32(total))
		}
		if !loadui_frame(g, f, phase) {
			break
		}
	}
	if g.phys_ok {
		for world.sync_physics(&g.scene, &g.scene.cache, budget = max(int)) > 0 {}
		physics.optimize_broadphase(&g.phys)
	}
	loadui_hide(g) // load done → clear the screen so gameplay doesn't keep drawing it
}
