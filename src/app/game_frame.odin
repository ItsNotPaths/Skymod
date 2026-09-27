package main

// One frame of the game session (the body of run_game's old 900-line loop), split into
// cohesive helpers per docs/run-game-refactor.md. game_frame is a FIXED SEQUENCE with real
// ordering constraints (scene select before locomotion so the capsule re-homes before it
// moves; physics before draw; cull_begin before any draw pass; shadow before scene) — keep
// it linear, don't make it data-driven. Helpers share the per-frame Frame_State in g.fr.
//
// RATE. The frame runs at display rate; the SIMULATION does not (docs/shipped.md §E).
// game_tick — scene select, locomotion, physics, traversal, scripts (on their own thread) — runs 0..MAX_TICKS_PER_FRAME times
// per frame at a constant TICK_DT, and everything else (input, aiming, streaming, picking,
// drawing) runs once per frame around it. What the frame draws is the last tick's state blended
// forward by g.tick.alpha.

import "core:log"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"

import "../audio"
import "../formid"
import "../gamedb"
import smath "../math"
import "../physics"
import "../input"
import "../platform"
import "../render"
import slog "../log"
import "../script"
import slua "../script/lua"
import "../settings"
import "../tools"
import "../world"
import "../worldstate"

SLOW_FRAME_MS :: f64(80)

// Debug (open-interiors walk-in): camera height above the arrival marker / exterior door
// when entering / exiting.
INTERIOR_EYE :: f32(96)

game_frame :: proc(g: ^Game) {
	// persist_run (overlay toggle) may have swapped a new sink into the logger last frame;
	// game_frame's scope (and every helper below) always logs through the current one.
	context.logger = g.logging.logger
	script_join(g) // the last frame's script phase ran during its render

	frame_t0 := time.tick_now() // profile: whole-frame busy time (see `prof`)
	g.fr = {}
	render.ui_new_frame(&g.r)

	// Drive the input action manager for this frame: sample the SDL device state and
	// gate the "gameplay" context on whether ImGui owns the keyboard (the console/panels).
	// "global" actions (overlay toggle) stay live regardless.
	{
		_, kb_cap := render.ui_capturing(&g.r)
		input.set_context(&g.imgr, "gameplay", !kb_cap)
		input.set_context(&g.imgr, "menu", !render.ui_typing(&g.r))
		f := platform.input_frame(&g.p)
		input.update(&g.imgr, &f)
	}

	if input.fired(&g.imgr, "ToggleOverlay") {
		g.show_overlay = !g.show_overlay
	}
	// Pointer lock during gameplay (mouse-look, no button needed). The tilde/backtick dev overlay is the
	// cursor gate: overlay OPEN → cursor free to click its panels + console; overlay CLOSED → mouse locked
	// for look. (The overlay is on by default, so a fresh session starts cursor-free until you un-tilde.)
	// Applied on the next pump.
	platform.set_mouse_capture(&g.p, !g.show_overlay && g.menu == .None)
	g.fr.st = world.stream_stats(&g.streamer)

	frame_diag(g)
	if g.show_overlay {
		frame_overlay(g)
		context.logger = g.logging.logger // re-read: the overlay's persist button adds a sink
	}
	frame_active_scene(g)
	frame_look(g)
	frame_debug_verbs(g)
	frame_menus(g)
	frame_subtitles(g)

	// The fixed-step sim. dt is clamped to the catch-up cap so a load screen or a hitch can't
	// hand the loop a backlog it would spend the next several frames grinding through. A menu that
	// pauses the world stops it.
	g.tick.accum += 0 if world_paused(g) else min(g.p.dt, TICK_DT * MAX_TICKS_PER_FRAME)
	for g.tick.accum >= TICK_DT {
		g.tick.accum -= TICK_DT
		g.tick.total += 1
		g.prof.ticks += 1
		game_tick(g)
	}
	g.tick.alpha = g.tick.accum / TICK_DT
	frame_force_greet(g)
	if g.cur_phys != nil {physics.set_render_alpha(g.cur_phys, g.tick.alpha)}

	frame_camera(g)
	frame_persistence(g)
	frame_stream(g)
	frame_inspect(g)
	frame_interact(g) // resolve the crosshair target + drive Activate (doors, pickup, grab); sets g.fr.act
	frame_actor_grab(g)
	frame_dev_shot(g)
	frame_cast(g)
	frame_hud(g) // publish g.fr.act to the prompt; draws into the UI drawlist end_frame composites
	audio.music_update(&g.db, &g.ws)
	audio.ambient_update(&g.db, &g.ws)
	audio.update(&g.audio, g.cam.pos, camera_forward(g.cam))
	draw_actor_nametags(g)

	g.elapsed += g.p.dt
	script_start(g) // the last tick's scripts run while this frame renders
	frame_render(g)

	g.prof.frame += time.duration_milliseconds(time.tick_since(frame_t0))
	g.prof.frames += 1

	// Slow-frame detector: attribute any hitch to its phase (which one's delta dominates points
	// at the cause — physics, render/GPU-stall, or streaming). Fires on the H-shove freeze.
	if fms := time.duration_milliseconds(time.tick_since(frame_t0)); fms > SLOW_FRAME_MS {
		log.warnf(
			"SLOW FRAME %.0fms — stream=%.1f phys=%.1f render=%.1f (acquire=%.1f)",
			fms,
			g.prof.stream - g.slowsnap.stream, g.prof.phys - g.slowsnap.phys,
			g.prof.render - g.slowsnap.render, g.prof.acquire - g.slowsnap.acquire,
		)
	}
	g.slowsnap = {g.prof.stream, g.prof.phys, g.prof.render, g.prof.acquire}

	// POLICY (docs/memory.md): anything on context.temp_allocator lives for
	// exactly one frame — UI string formatting, draw lists, transient buffers.
	// Wiped here, every frame.
	free_all(context.temp_allocator)
}

// game_tick is ONE fixed simulation step — everything whose outcome must not depend on the
// display rate. The previous tick's scripts finish first and their activations run (a door
// crossing is a transition, between ticks). Then scene select re-homes the capsule before it
// moves, physics steps the world it moved in, traversal reads the position it ended at. This
// tick's script phase is left pending (script_thread.odin).
@(private = "file")
// (hole tick-thread :tags (world physics) :sev gap) the sim tick runs on the render thread (only its script phase has its own), so a slow tick stalls frames and a frame that falls behind runs up to 5 ticks. Decided (user, 2026-09-27): the game tick gets its own thread. Render then needs a published snapshot of poses and instances instead of reading Jolt and the chunks live.
game_tick :: proc(g: ^Game) {
	script_run_pending(g)
	player_follow(g)
	tick_activations(g)
	frame_scene_select(g)
	tick_locomotion(g)
	tick_actor_bodies(g)
	tick_projectiles(g)
	frame_physics(g)
	frame_traversal(g)
	g.scripts.pending = true
}

// frame_diag emits the periodic memory/cache/leak probe + the frame-time profile (every ~3s).
// Runs regardless of overlay visibility (it's a background crash trail, not a panel). Run with
// --persist-logs to keep the trail across a crash: climbing RSS/cache = a leak; flat RSS at
// the crash points elsewhere (e.g. a GPU hazard).
@(private = "file")
frame_diag :: proc(g: ^Game) {
	g.diag_t += g.p.dt
	if g.diag_t < 3 {
		return
	}
	g.diag_t = 0
	st := g.fr.st
	mc, tc, mb, tb, cold, coldb, tcold, tcoldb := world.cache_counts(&g.scene)
	lob, lor := world.lod_object_stats(&g.scene)
	ps := world.phys_stats(&g.scene) // the exterior — where the streaming-churn leak would be
	log.infof(
		"diag: cell (%d,%d) chunks=%d cache models=%d (%dMB) tex=%d (%dMB) cold=%d (%dMB) texcold=%d (%dMB) lodobj=%d/%d rss=%dMB",
		st.gx, st.gy, st.chunks, mc, mb / (1024 * 1024), tc, tb / (1024 * 1024), cold, coldb / (1024 * 1024),
		tcold, tcoldb / (1024 * 1024), lor, lob, proc_rss_mb(),
	)
	// Frame-time profile (avg ms over the window) — the phase whose avg climbs is the
	// fps eater. n = frames sampled. inv := 1/n.
	if g.prof.frames > 0 {
		inv := 1.0 / f64(g.prof.frames)
		log.infof(
			"prof: frame=%.2fms stream=%.2f phys=%.2f render=%.2f (avg/%d frames, %d sim ticks)",
			g.prof.frame * inv, g.prof.stream * inv, g.prof.phys * inv, g.prof.render * inv, g.prof.frames,
			g.prof.ticks,
		)
		// Render breakdown (ms): acquire = GPU-bound stall; the rest are CPU draw-submission
		// per pass. If acquire ≫ passes, we're GPU-bound (fix = fewer/cheaper draws + verts);
		// if passes dominate, CPU-bound (fix = fewer draw calls / less iteration).
		log.infof(
			"prof.render: acquire=%.2f shadow=%.2f terrain=%.2f near=%.2f objdraw=%.2f grass=%.2f water=%.2f effects=%.2f",
			g.prof.acquire * inv, g.prof.shadow * inv, g.prof.terrain * inv, g.prof.near * inv,
			g.prof.objdraw * inv, g.prof.grass * inv, g.prof.water * inv, g.prof.effects * inv,
		)
	}
	g.prof = {}
	// Leak probe: bodies/instances should be FLAT when the player stands still. Δ is the
	// change since the last window — a persistent + climb with no movement = a missing
	// release path (chunks not freeing bodies, instances re-accumulating).
	log.infof(
		"leak: bodies=%d (Δ%+d) dyn=%d instances=%d built=%d chunks=%d",
		ps.bodies, ps.bodies - g.prev_bodies, ps.dyn, ps.instances, ps.built, ps.chunks,
	)
	g.prev_bodies = ps.bodies
	g.slowsnap = {} // prof was just reset above — zero the snapshot so this frame's delta is clean

	// D1 (dev builds): deterministically assert the model refcounts match the live holders every
	// diag tick, so an acquire/release imbalance surfaces here rather than as a slow RSS creep once a
	// budget is enabled. Cheap (a temp map walk of resident chunks); dark-ship confidence.
	when DEVTOOLS {
		if ok, msg := world.debug_check_model_refs(&g.scene); !ok {
			log.warnf("diag: %s", msg)
		}
		if ok, msg := world.debug_check_texture_refs(&g.scene); !ok {
			log.warnf("diag: %s", msg)
		}
	}
}

// frame_overlay draws + handles the whole dev overlay (` toggles it in game_frame). Hidden =
// no panels, so ImGui captures nothing and the camera/door keys drive the bare scene; the
// game-logic keys (F, etc.) are independent of the panels and keep working in the helpers below.
@(private = "file")
frame_overlay :: proc(g: ^Game) {
	if tools.debug_overlay(g.p.dt, g.logging.persisting, g.logging.persist_path, &g.pretty) {
		if slog.persist_run(g.logging) {
			context.logger = g.logging.logger // re-install: persist_run added a sink
		}
	}
	st := g.fr.st
	tools.stream_panel(st.gx, st.gy, st.chunks, st.inflight, st.reqs, st.ready)
	if g.interiors_on {
		is := world.interiors_stats(&g.interiors, g.cam.pos)
		act := tools.interiors_panel(
			is.portals,
			is.load_dist,
			is.nearest_dist,
			&g.portal_push,
			&g.portal_yaw_off,
			g.interiors.active,
			g.entered,
		)
		#partial switch act {
		case .Enter:
			if g.interiors.active {
				pp := g.interiors.active_portal
				into := world.into_room_dir(pp)
				g.cam.pos = pp.tp_pos + smath.Vec3{0, 0, INTERIOR_EYE}
				g.cam.yaw = math.atan2(into.y, into.x)
				g.cam.pitch = 0
				g.entered = true
				log.infof("interiors: loaded INTO cell 0x%08X (debug walk-in)", pp.int_cell)
			}
		case .Exit:
			pp := g.interiors.active_portal
			g.cam.pos = pp.door_pos - smath.scale3(pp.ext_dir, 160) + smath.Vec3{0, 0, INTERIOR_EYE}
			g.cam.yaw = math.atan2(pp.ext_dir.y, pp.ext_dir.x)
			g.cam.pitch = -0.1
			g.entered = false
			log.info("interiors: exited to exterior")
		}
	}
	g.fr.insp_action = tools.inspector_panel(&g.insp)
	if g.fr.insp_action == .Cull_Tex && g.interiors_on {
		world.interiors_add_cull_tex(&g.interiors, g.insp.sel_tex)
	}

	// Lighting configurator: live-edit, switch the active preset, or save the look as a new preset.
	light_act := tools.lighting_panel(
		&g.lights.active,
		g.lights.names[:],
		g.lights.current,
		g.light_save_name[:],
	)
	if light_act.select >= 0 && light_act.select != g.lights.current {
		lighting_select(&g.lights, light_act.select)
		settings.set(g.cfg, "lighting_profile", g.lights.names[g.lights.current])
		_ = settings.save(g.cfg)
	}
	if light_act.save_as {
		name := strings.clone(
			strings.trim_space(string(cstring(raw_data(g.light_save_name[:])))),
			context.temp_allocator,
		)
		if name != "" && lighting_save_preset(&g.lights, name) {
			settings.set(g.cfg, "lighting_profile", g.lights.names[g.lights.current])
			_ = settings.save(g.cfg)
			log.infof("lighting: saved preset %q", name)
			g.light_save_name = {}
		}
	}

	// Dev console: evaluate the submitted line on the gameplay REPL and echo the
	// captured output (results / print / errors). Falls back to a bare echo if the
	// REPL failed to init.
	if cmd := tools.console_panel(&g.console); cmd != "" {
		tools.console_printf(&g.console, "> %s", cmd)
		if g.repl_ok {
			for line in slua.repl_eval(&g.repl, cmd) {
				tools.console_print(&g.console, line)
			}
		}
		log.infof("console: %q", cmd)
	}
}

// frame_active_scene resolves which scene the player inhabits and whether it's a full-screen
// interior (the streamer is paused there). Pure — no side effects — so the frame can call it
// even on a frame that runs no tick, and still have g.fr populated for picking and drawing.
frame_active_scene :: proc(g: ^Game) {
	// The experimental open-interiors path keeps its own debug walk-in (`entered`); the base
	// path is driven by the Traversal door navigator.
	if g.interiors_on {
		g.fr.in_interior = g.entered
		g.fr.active_scene = &g.interiors.interior_scene if g.entered else &g.scene
	} else {
		g.fr.in_interior = g.trav.mode == .Interior
		g.fr.active_scene = traversal_scene(&g.trav)
	}
}

// frame_scene_select resolves the active scene, applies pending script scene-ops, and re-homes
// the player capsule if the active physics world changed. First thing in the tick, so the
// capsule re-homes into the active world before it's moved.
@(private = "file")
frame_scene_select :: proc(g: ^Game) {
	frame_active_scene(g)
	// Live pretty toggle: apply to the exterior + whichever scene we draw this frame (draw
	// reads scene.pretty each frame, so this takes effect immediately).
	g.scene.pretty = g.pretty
	g.fr.active_scene.pretty = g.pretty

	// Deferred scene-apply (decision #3): drain the overlay changes script natives wrote this
	// frame (e.g. a console `sel:Disable()`) and apply them live to the active scene — the fixed
	// frame point where instance hide/move/scale/remove land, before physics rebuilds collision.
	world.apply_pending_scene_ops(g.fr.active_scene, &g.db)

	// Re-home the player capsule into the active scene's physics world. On a door transition
	// the active world changes (exterior `phys` ↔ an interior's own world); destroy the old
	// capsule and recreate it in the new world at the camera. A nil active world (physics off,
	// or the experimental portal interior, which has none) → no capsule → free-fly.
	want_phys := g.fr.active_scene.phys
	if want_phys != g.cur_phys {
		if g.char_ok {physics.character_destroy(&g.character);g.char_ok = false}
		actor_bodies_clear(g)
		if want_phys != nil {
			player_capsule := actor_capsule(g, formid.PLAYER)
			g.character, g.char_ok = physics.character_create(want_phys, g.cam.pos - {0, 0, EYE_HEIGHT}, player_capsule.radius, player_capsule.half_h, u64(formid.PLAYER))
			if !g.char_ok {g.noclip = true}
		}
		g.cur_phys = want_phys
	}
}

// frame_look applies mouse look and latches what ImGui captured this frame. Aiming is not
// simulation: it runs every rendered frame so the view can't quantize to the tick rate. The
// tick reads the yaw it leaves behind to build the move direction.
@(private = "file")
frame_look :: proc(g: ^Game) {
	g.fr.mouse_cap, g.fr.kb_cap = render.ui_capturing(&g.r)
	if !g.fr.mouse_cap {camera_look(&g.cam, g.p.input.look)}
}

// tick_locomotion walks the player capsule one fixed tick: camera-relative WASD at the current
// yaw, Shift sprint, Space jump, in whichever world the capsule is homed to. Free-fly moves in
// frame_camera instead — no solver, so it has nothing to keep deterministic.
@(private = "file")
tick_locomotion :: proc(g: ^Game) {
	if !g.char_ok || g.noclip {
		return
	}
	move := g.p.input.move
	if g.fr.kb_cap {move = {}}
	cy, sy := math.cos(g.cam.yaw), math.sin(g.cam.yaw)
	dir := [2]f32{cy * move.x + sy * move.y, sy * move.x - cy * move.y}
	mag := math.sqrt(dir.x * dir.x + dir.y * dir.y)
	if g.p.input.fast {worldstate.set_sneaking(&g.ws, formid.PLAYER, false)} // sprinting stands up
	speed := SPRINT_SPEED if g.p.input.fast else SNEAK_SPEED if worldstate.is_sneaking(&g.ws, formid.PLAYER) else RUN_SPEED
	hv: [2]f32
	if mag > 0.001 {hv = {dir.x / mag * speed, dir.y / mag * speed}}
	physics.character_move(g.cur_phys, &g.character, hv, move.z > 0.5, TICK_DT)
}

// frame_camera puts the eye where this frame should see it: the capsule's position blended
// across the tick the frame sits inside (walking looks smooth above 60 fps), or the free-fly
// camera flown at render rate.
@(private = "file")
frame_camera :: proc(g: ^Game) {
	if g.char_ok && !g.noclip {
		g.cam.pos = physics.character_render_position(&g.character, g.tick.alpha) + {0, 0, EYE_HEIGHT}
		return
	}
	move := g.p.input.move
	if g.fr.kb_cap {move = {}}
	camera_fly(&g.cam, move, g.p.input.fast, g.p.dt)
	if g.char_ok {physics.character_set_position(&g.character, g.cam.pos)} // keep the body under the free camera
}

// frame_debug_verbs handles the physics-verification keys: G drop-test ball, K hitbox
// wireframe toggle, H clutter shove.
@(private = "file")
frame_debug_verbs :: proc(g: ^Game) {
	if input.fired(&g.imgr, "NoClip") {g.noclip = !g.noclip}

	// Drop-test: G spawns a falling ball at the camera (physics verification). Exterior only —
	// the markers read positions from `phys`, so a ball dropped inside an interior (a
	// different world) wouldn't track; gate it to the exterior to avoid the confusion.
	if g.phys_ok && input.fired(&g.imgr, "DevDrop") && !g.fr.in_interior {
		b := physics.add_sphere(&g.phys, 24, g.cam.pos, is_dynamic = true)
		if b != 0 {append(&g.drops, b)}
		log.infof("drop-test: ball %d at (%.0f, %.0f, %.0f)", len(g.drops), g.cam.pos.x, g.cam.pos.y, g.cam.pos.z)
	}

	// Collision-hitbox overlay toggle (K): show the green wireframe of what Jolt actually collides.
	if input.fired(&g.imgr, "DevHitbox") {
		g.show_hitboxes = !g.show_hitboxes
		world.clear_collision_debug(&g.scene) // rebuild fresh each enable (picks up late-loaded models)
		if g.interiors_on {world.clear_collision_debug(&g.interiors.interior_scene)}
		log.infof("collision hitboxes: %v", g.show_hitboxes)
	}

	// Shove-test (H): kick nearby movable clutter so it scatters and resettles — a visible check
	// of the 3b dynamic-body path (interiors only, where clutter is dynamic).
	if input.fired(&g.imgr, "DevShove") {
		t_shove := time.tick_now()
		n := world.shove_clutter(g.fr.active_scene, g.cam.pos, 400)
		act := physics.num_active(g.fr.active_scene.phys) if g.fr.active_scene.phys != nil else 0
		log.infof("shove: kicked %d clutter bodies in %.1fms (active now %d)", n, time.duration_milliseconds(time.tick_since(t_shove)), act)
	}
}

// frame_persistence handles quicksave (F5) / quickload (F9) — Phase 3d. Save writes the
// overlay to a .skysave; load reads it back and, when inside a base-traversal interior,
// reloads the cell so moved clutter snaps to the loaded positions immediately. Exterior
// loads apply on the next interior entry.
@(private = "file")
frame_persistence :: proc(g: ^Game) {
	if input.fired(&g.imgr, "QuickSave") {quicksave(g)}
	if input.fired(&g.imgr, "QuickLoad") {quickload(g)}
}

quicksave :: proc(g: ^Game) {
	script_run_pending(g) // a save lands between whole ticks
	_ = os.make_directory(g.saves_dir) // idempotent (errors harmlessly if it exists)
	player_follow(g)
	player_publish(g)
	player, _ := worldstate.get(&g.ws, formid.PLAYER)
	man := worldstate.Save_Manifest {
		save_number  = g.save_no + 1,
		created_unix = time.to_unix_nanoseconds(time.now()),
		game_cell    = player.cell,
	}
	if g.repl_ok {slua.save_scripts(&g.repl.vm)}
	if worldstate.save_to_file(&g.ws, g.quicksave_path, man, &g.save_bridge) {
		g.save_no += 1
		log.infof("quicksave: wrote %s (%d deltas)", g.quicksave_path, worldstate.count(&g.ws))
	} else {
		log.errorf("quicksave: FAILED to write %s", g.quicksave_path)
	}
}

quickload :: proc(g: ^Game) {
	script_run_pending(g)
	m, ok := worldstate.load_from_file(&g.ws, g.quicksave_path, &g.save_bridge)
	if !ok {
		log.warnf("quickload: no valid save at %s", g.quicksave_path)
		return
	}
	log.infof("quickload: loaded %s (%d deltas)", g.quicksave_path, m.delta_count)
	if g.repl_ok {slua.reload_scripts(&g.repl.vm, &g.db)}
	g.trans.location = nil
	// Exterior: rebuild resident chunks from baseline ⊕ the loaded overlay — full
	// reconciliation (created add/remove, disabled/moved/scaled reset to the saved state).
	// The rebuild flags object collision for re-cook; run it behind the dedicated load
	// screen (reused from boot) so the world is solid before gameplay resumes.
	world.reapply_overlay_resident(&g.scene, &g.db)
	// Back to the saved cell and position, then the load screen builds + solidifies that bubble.
	// Saved in the interior we stand in: rebuild it so the loaded overlay applies.
	if kind := player_restore(g); kind == .Stay || kind == .None {traversal_reload(&g.trav)}
	load_screen_stream(g, "Loading save…", 0, 1)
}

// frame_stream re-windows the exterior around the (now-moved) camera — unless we're inside an
// interior (camera is in interior-local space; the streamer is paused). Uploads decoded models
// under the per-frame budget. Never blocks.
@(private = "file")
frame_stream :: proc(g: ^Game) {
	t_stream := time.tick_now()
	if !g.fr.in_interior {
		world.stream_update(&g.streamer, g.cam.pos)
		world.update_terrain_field(&g.scene, g.cam.pos) // re-select CDLOD terrain LOD on move
		if g.interiors_on {
			// Open interiors (EXPERIMENTAL): keep the nearest in-range portal's interior
			// loaded (GPU work, so outside begin_frame). Rendered through the doorway below.
			world.interiors_update(&g.interiors, g.cam.pos)
		}
	}
	g.prof.stream += time.duration_milliseconds(time.tick_since(t_stream))
}

// Placement is a cell and a position in it.
Placement :: struct {
	cell: Form_ID,
	pos:  smath.Vec3,
}

// player_publish writes the player's feet into its ref's Moved delta: the cell under the player
// (interior, or exterior grid cell), the position, and the heading. player_follow compares against it.
player_publish :: proc(g: ^Game) {
	cell := g.trav.cur_int_cell
	feet := g.cam.pos - {0, 0, EYE_HEIGHT}
	if g.trav.mode != .Interior {
		world_fid := g.trav.st.world_fid if g.trav.st != nil else 0
		cell = gamedb.cell_under(&g.db, world_fid, feet)
	}
	heading := math.PI / 2 - g.cam.yaw
	worldstate.set_moved(&g.ws, formid.PLAYER, cell, smath.trs(feet, {0, 0, heading}, 1), feet)
	g.published = {cell, feet}
}

// player_follow places the player where a script moved its ref (MoveTo, SetPosition) since the
// last player_publish.
player_follow :: proc(g: ^Game) {
	d, ok := worldstate.get(&g.ws, formid.PLAYER)
	if !ok || .Moved not_in d.live || (Placement{d.cell, d.pos} == g.published) {return}
	traversal_finish_load(g, player_restore(g))
}

// player_restore places the player where its ref's delta says, in any cell, and returns what the
// traversal did; the caller runs the load screen it still needs.
player_restore :: proc(g: ^Game) -> Traversal_Kind {
	d, ok := worldstate.get(&g.ws, formid.PLAYER)
	if !ok || .Moved not_in d.live || g.interiors_on {return .None}
	kind := traversal_go_to(&g.trav, d.cell, d.pos)
	if kind == .None {return .None}
	player_teleport(g, d.pos, math.PI / 2 - math.atan2(d.world[0, 1], d.world[0, 0]), 0)
	g.published = {d.cell, d.pos}
	return kind
}

// frame_physics (Phase 2e): build collision bodies for newly-resolved instances of the ACTIVE
// world (streamed exterior, or the interior cell) then advance THAT world's sim by one fixed
// TICK_DT — never a real dt, so the solver converges the same on every machine. Interiors
// prebuild their bodies on entry (enter_interior), so sync_physics here is a no-op for them;
// the exterior keeps building as cells stream in.
@(private = "file")
frame_physics :: proc(g: ^Game) {
	t_phys := time.tick_now()
	if g.cur_phys != nil {
		// New cells streaming in add static bodies; rebuild the broadphase the frames they
		// do (made > 0) so the quad-tree stays balanced — without this the exterior tree
		// degrades with every incremental add and the step time climbs steadily. Interiors
		// build + optimize on entry, so sync_physics is a no-op there and this never fires.
		// Sub-timers (diagnostic): split the phys phase so a hitch names the culprit op.
		ts := time.tick_now()
		built_n := world.sync_physics(g.fr.active_scene, &g.fr.active_scene.cache)
		ms_sync := time.duration_milliseconds(time.tick_since(ts))
		ms_opt: f64
		if built_n > 0 {
			ts = time.tick_now()
			physics.optimize_broadphase(g.cur_phys)
			ms_opt = time.duration_milliseconds(time.tick_since(ts))
		}
		ts = time.tick_now()
		physics.step(g.cur_phys, TICK_DT)
		ms_step := time.duration_milliseconds(time.tick_since(ts))
		ts = time.tick_now()
		world.capture_settles(g.fr.active_scene) // overlay: snapshot clutter that just came to rest (3c)
		ms_settle := time.duration_milliseconds(time.tick_since(ts))
		if ms_sync + ms_opt + ms_step + ms_settle > SLOW_FRAME_MS {
			log.warnf(
				"SLOW PHYS — sync=%.1f(built %d) optimize=%.1f step=%.1f settle=%.1f | active=%d/%d bodies",
				ms_sync, built_n, ms_opt, ms_step, ms_settle,
				physics.num_active(g.cur_phys), physics.num_bodies(g.cur_phys),
			)
		}
	}
	g.prof.phys += time.duration_milliseconds(time.tick_since(t_phys))
}

// frame_traversal drives the PROXIMITY half of base door traversal: invisible auto-load doors
// (cave/dungeon AutoLoadMarkers) cross with no key when you walk into them. Manual doors (real
// meshes, incl. city gates) are crossed by the crosshair now — you look at the door and press
// Activate — so they're handled in frame_interact, not here. Inert on the experimental
// open-interiors path (it has its own walk-in).
@(private = "file")
frame_traversal :: proc(g: ^Game) {
	if g.interiors_on {
		return
	}
	traversal_arrival_update(&g.trav, g.cam.pos) // re-arm auto-fire once clear of the last landing
	// Auto-load only: the nearest door scan exists to catch the invisible markers the crosshair can't
	// hit. A manual door found here is ignored — Activate crosses it via the crosshair (frame_interact).
	hit := traversal_nearest_door(&g.trav, g.cam.pos)
	if hit.ok && hit.auto && hit.dist <= AUTO_DOOR_RANGE && !g.trav.has_arrival {
		if np, nyaw, kind := go_through(&g.trav, hit); kind != .None {
			player_teleport(g, np, nyaw, 0)
			traversal_finish_load(g, kind)
		}
	}
}

// player_teleport moves the player's feet outright — camera AND capsule. Both must move:
// frame_camera reads the eye position back off the capsule, so setting only the camera snaps
// straight back next frame. A crossing that also swaps physics world leaves the capsule to frame_scene_select
// (which re-creates it in the new world at this camera position); setting it here first is
// harmless there and is what carries the same-world case, a city gate.
player_teleport :: proc(g: ^Game, feet: smath.Vec3, yaw, pitch: f32) {
	g.cam.pos, g.cam.yaw, g.cam.pitch = feet + {0, 0, EYE_HEIGHT}, yaw, pitch
	if g.char_ok {physics.character_set_position(&g.character, feet)}
}

// traversal_finish_load runs the load screen a transition still needs AFTER go_through. An interior
// already showed its load screen inside go_through (the synchronous decode reported through t.progress);
// a city gate armed a full-bore stream in retarget_exterior, so we drive the streamer load screen here
// (like Skyrim's city load). An exterior return is instant (kept-warm window) — nothing to do.
// Package-visible: frame_interact calls it after a crosshair door crossing too.
traversal_finish_load :: proc(g: ^Game, kind: Traversal_Kind) {
	switch kind {
	case .City, .Jump:
		load_screen_stream(g, "Loading…", 0, 1) // streamer-driven; clears the load screen at its end
	case .Interior:
		loadui_hide(g) // the interior load ran inside go_through — clear its last frame's quads
	case .Stay, .Exit, .None:
	// instant / no transition — no load screen ran
	}
}

// frame_inspect is inspect mode: hold Ctrl to highlight the model under the mouse cursor (a
// ray through the cursor, not the screen centre); left-click selects the highlighted one for
// the Inspector panel (and as the console's `sel`). Plus the Ctrl-hover mutation verbs:
// X disables the hovered ref, B spawns a copy of its base at the camera.
@(private = "file")
frame_inspect :: proc(g: ^Game) {
	active_scene := g.fr.active_scene
	world.clear_hover(active_scene)
	g.hover_actor = 0
	if g.p.input.hover && !g.fr.mouse_cap {
		ro, rd := camera_ray(g.cam, render.aspect(&g.r), g.p.input.mouse_ndc)
		actor, adist, aok := pick_actor(g, ro, rd)
		if _, idist, iok := world.probe_ray(active_scene, ro, rd); aok && (!iok || adist < idist) {
			g.hover_actor = actor
			if g.p.input.select {select_actor(g, actor)}
		} else if inst, shp, hok := world.hover_pick(active_scene, ro, rd); hok && g.p.input.select {
			world.select_instance(active_scene)
			g.insp.has_sel = true
			// Own the model-borrowed strings (path + texture): the selection can outlive the
			// instance's chunk, and cache eviction (D1) frees the Model they'd point into.
			tools.inspector_set_model_strings(
				&g.insp,
				inst.model.path,
				inst.model.shapes[shp].diffuse_path if shp >= 0 && shp < len(inst.model.shapes) else "",
			)
			g.insp.sel_display = gamedb.name_of(&g.db, gamedb.Form_ID(inst.form_id)) // FULL name (ref → base)
			g.insp.sel_base = inst.base
			g.insp.sel_pos = inst.pos
			g.insp.sel_rot = inst.rot
			g.insp.sel_has_door = inst.has_tp
			g.insp.sel_door_cell = ""
			g.insp.sel_is_door = gamedb.is_door(&g.db, inst.base)
			// Track the picked REFR as the console's `sel`. DIAG: echo the form so we can see
			// whether the instance actually carries a REFR id (vs 0 → sel becomes None).
			if g.repl_ok {
				slua.repl_set_selection(&g.repl, script.Form_ID(inst.form_id))
				tools.console_printf(&g.console, "[sel] 0x%08X (%s)", u64(inst.form_id), inst.model_path)
			}
		}
	}

	// Disable-test (Ctrl-hover + X): record a Disabled delta for the hovered ref and hide it live —
	// the Layer-1 mutation verb end-to-end (overlay delta + live-apply; persists via apply_overlay
	// on cell reload). Spread target: Alvor's house (exterior) + Sleeping Giant fireplaces (interior).
	if input.fired(&g.imgr, "DevDisable") && active_scene.has_hover {
		if chunk, ok := &active_scene.chunks[active_scene.hover_cell];
		   ok && active_scene.hover_inst >= 0 && active_scene.hover_inst < len(chunk.instances) {
			inst := &chunk.instances[active_scene.hover_inst]
			if world.disable_ref(active_scene, inst.form_id, active_scene.hover_cell, true) {
				log.infof("disable: ref 0x%08X (%s) hidden", inst.form_id, inst.model_path)
			} else {
				log.warnf("disable: scene has no overlay — ref 0x%08X not recorded", inst.form_id)
			}
		}
	}

	// Spawn-test (Ctrl-hover + B): mint a runtime created ref (0xFF space) — a copy of the hovered
	// ref's base form — at the camera, in the hovered ref's cell. Exercises the created-ref store +
	// additive overlay + live spawn; it persists (F5) and respawns on cell reload.
	if input.fired(&g.imgr, "DevSpawn") && active_scene.has_hover {
		if chunk, ok := &active_scene.chunks[active_scene.hover_cell];
		   ok && active_scene.hover_inst >= 0 && active_scene.hover_inst < len(chunk.instances) {
			base := chunk.instances[active_scene.hover_inst].base
			id := world.create_ref(active_scene, &g.db, base, active_scene.hover_cell, g.cam.pos, {0, 0, 0}, 1)
			if id != 0 {
				log.infof("spawn: created ref 0x%08X (base 0x%08X) at camera", id, base)
			} else {
				log.warnf("spawn: no overlay / base 0x%08X has no model — nothing created", base)
			}
		}
	}
}

// select_actor makes an actor the Inspector's selection and the console's `sel`.
@(private = "file")
select_actor :: proc(g: ^Game, actor: Form_ID) {
	g.fr.active_scene.has_sel = false
	g.insp.has_sel = true
	tools.inspector_set_model_strings(&g.insp, "", "")
	g.insp.sel_display = worldstate.display_name(&g.ws, &g.db, actor)
	g.insp.sel_base = worldstate.ref_base(&g.ws, &g.db, actor)
	g.insp.sel_pos = worldstate.ref_pos(&g.ws, &g.db, actor)
	g.insp.sel_rot = {}
	g.insp.sel_has_door = false
	g.insp.sel_door_cell = ""
	g.insp.sel_is_door = false
	if g.repl_ok {
		slua.repl_set_selection(&g.repl, script.Form_ID(actor))
		tools.console_printf(&g.console, "[sel] 0x%08X (%s)", u64(actor), g.insp.sel_display)
	}
}

// frame_render is the whole draw side: scene lighting + sun-shadow cascades, the swapchain
// acquire, then the fixed draw sequence (shadow casters → terrain → near scene → object LOD →
// grass → portal → water → effects → highlight → hitboxes). The cascade caster passes run on
// the FRAME command buffer between frame_acquire and scene_begin, so the shadow-array write →
// sampler read is one command buffer and SDL3_gpu inserts the barrier (a separate shadow cmd
// buffer faulted the Intel Vulkan driver).
@(private = "file")
frame_render :: proc(g: ^Game) {
	in_interior, active_scene := g.fr.in_interior, g.fr.active_scene
	// A portal interior is loaded and (when not entered) viewed through the doorway.
	interior_active := g.interiors_on && g.interiors.active

	t_render := time.tick_now()
	env := lighting_env(&g.lights.active, g.cam.pos)
	shadows_on := g.shadow_dist > 0 && g.lights.active.shadow_strength > 0 && !in_interior
	cascades: Cascades
	vmode := world.Veg_Shadow_Mode.Proxy
	if shadows_on {
		cascades = compute_cascades(g.cam, render.aspect(&g.r), g.lights.active.sun_dir, g.shadow_dist)
		for i in 0 ..< render.SHADOW_CASCADES {
			env.csm_vp[i] = cascades.vp[i]
			env.csm_splits[i] = cascades.splits[i]
		}
		texel := g.lights.active.shadow_softness / f32(render.SHADOW_RES)
		env.shadow_params = {
			g.lights.active.shadow_strength,
			g.lights.active.shadow_bias,
			texel,
			f32(render.SHADOW_CASCADES),
		}
		// Vegetation shadow tier comes from the active lighting profile (per-preset, live).
		switch g.lights.active.veg_shadows {
		case .Off:
			vmode = .Off
		case .Full:
			vmode = .Full
		case .Proxy:
			vmode = .Proxy
		}
	}
	render.set_lighting(&g.r, env)
	render.set_post(&g.r, lighting_post(&g.lights.active))
	sky := g.lights.active.sky_color
	t_acq := time.tick_now()
	acquired := render.frame_acquire(&g.r) // blocks here if the GPU is behind → GPU-bound shows up in `acquire`
	g.prof.acquire += time.duration_milliseconds(time.tick_since(t_acq))
	if acquired {
		// Snapshot the drawn scene's chunks into its flat per-frame list once (Fix A): every
		// draw/shadow pass below iterates that tight array instead of walking the chunk MAP and
		// streaming its big inline Chunk values through cache ~9×/frame. The interior path draws
		// active_scene; the shadow cascades + exterior passes draw &scene.
		world.cull_begin(active_scene if in_interior else &g.scene)
		t_shadow := time.tick_now()
		if shadows_on {
			for c in 0 ..< render.SHADOW_CASCADES {
				render.shadow_cascade(&g.r, c)
				// Cap casters to the shadow region (+1 cell margin for tall off-slice casters).
				world.draw_casters(&g.scene, &g.r, cascades.vp[c], cascades.frusta[c], g.cam.pos, g.shadow_dist + 4096, vmode)
				render.shadow_cascade_end(&g.r)
			}
		}
		g.prof.shadow += time.duration_milliseconds(time.tick_since(t_shadow))
		render.scene_begin(&g.r, {sky.x, sky.y, sky.z, 1.0})
		vp := camera_view_proj(g.cam, render.aspect(&g.r))
		if in_interior {
			// Inside a loaded interior cell (interior-local coords): draw it full-screen.
			world.draw(active_scene, &g.r, vp)
			world.draw_effects(active_scene, &g.r, vp, g.elapsed)
			world.draw_highlight(active_scene, &g.r, vp)
		} else {
			t_terrain := time.tick_now()
			world.draw_terrain_field(&g.scene, &g.r, vp, g.cam.pos) // CDLOD whole-world terrain (drawn under streamed detail)
			g.prof.terrain += time.duration_milliseconds(time.tick_since(t_terrain))
			t_near := time.tick_now()
			world.draw(&g.scene, &g.r, vp, g.wind, g.elapsed) // trees + foliage sway under the global wind
			g.prof.near += time.duration_milliseconds(time.tick_since(t_near))
			// Drop-test markers: a box at each falling ball's pose, blended across the tick.
			for b in g.drops {
				render.draw_mesh(&g.r, g.drop_marker, vp, physics.body_transform(&g.phys, b), {})
			}
			t_objdraw := time.tick_now()
			world.draw_object_lod(&g.scene, &g.r, vp, g.cam.pos, g.full_radius, g.wind, g.elapsed) // baked per-quad distant objects
			g.prof.objdraw += time.duration_milliseconds(time.tick_since(t_objdraw))
			t_grass := time.tick_now()
			if g.grass_dist > 0 {
				world.draw_grass(&g.scene, &g.r, vp, g.cam.pos, g.grass_dist, g.wind, g.elapsed)
			}
			g.prof.grass += time.duration_milliseconds(time.tick_since(t_grass))
			// Stencil portal: render the nearest in-range interior THROUGH its doorway, from a
			// virtual camera relayed into interior space. After exterior opaque geometry (so a
			// wall in front of the door hides it), before the translucent effect pass.
			if interior_active {
				relay := world.relay_view_proj(
					g.interiors.active_portal,
					g.cam.pos,
					camera_forward(g.cam),
					render.aspect(&g.r),
					CAM_FOV_Y,
					CAM_NEAR,
					CAM_FAR,
					g.portal_push,
					g.portal_yaw_off,
				)
				world.interiors_render(&g.interiors, &g.r, vp, relay)
			}
			t_water := time.tick_now()
			world.draw_water_lod(&g.scene, &g.r, vp, g.cam.pos, g.full_radius, g.elapsed) // baked distant water (per-quad, real heights)
			world.draw_water(&g.scene, &g.r, vp, g.cam.pos, g.elapsed) // near animated per-cell water (bubble), over the distant
			g.prof.water += time.duration_milliseconds(time.tick_since(t_water))
			t_effects := time.tick_now()
			world.draw_effects(&g.scene, &g.r, vp, g.elapsed) // additive FX (flowing water/fire/beams), over opaque (last)
			g.prof.effects += time.duration_milliseconds(time.tick_since(t_effects))
			world.draw_highlight(&g.scene, &g.r, vp, g.wind, g.elapsed) // inspect-mode hover highlight
		}
		// Collision-hitbox wireframe (K): green outlines of EXACTLY what Jolt collides — static
		// geometry (cached) + dynamic clutter at its live body pose. Over the lit scene, before end.
		draw_actor_bodies(g, vp)
		if g.show_hitboxes {
			dbg_scene := active_scene if in_interior else &g.scene
			world.build_collision_debug(dbg_scene, &g.db)
			world.draw_collision_debug(dbg_scene, &g.r, vp)
		}
		render.end_frame(&g.r)
	}
	g.prof.render += time.duration_milliseconds(time.tick_since(t_render))
}

// proc_rss_mb reads this process's resident set size (MB) from /proc/self/statm (Linux) — the
// 2nd field is resident pages × 4 KiB. Returns -1 if unavailable. A diagnostic probe for the
// extended-flight segfault (is memory climbing?).
@(private = "file")
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
