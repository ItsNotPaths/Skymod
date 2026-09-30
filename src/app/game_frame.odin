package main

// One frame of the game session (the body of run_game's old 900-line loop), split into
// cohesive helpers per docs/run-game-refactor.md. game_frame is a FIXED SEQUENCE with real
// ordering constraints (scene select before locomotion so the capsule re-homes before it
// moves; physics before draw; cull_begin before any draw pass) — keep
// it linear, don't make it data-driven. Helpers share the per-frame Frame_State in g.fr.
//
// RATE. The frame runs at display rate; the SIMULATION does not (docs/shipped.md §E).
// game_tick — scene select, locomotion, physics, traversal, scripts (on their own thread) — runs
// the ticks the sim's clock has due, each a constant TICK_DT, and everything else (input, aiming,
// streaming, picking, drawing) runs once per frame around it. What the frame draws is the newest
// snapshot's segment, blended by g.fr.alpha.

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import "core:time"

import "../actorstate"
import "../ai"
import "../audio"
import "../combat"
import "../condfn"
import "../magic"
import "../conditions"
import "../detection"
import "../formid"
import "../gamedb"
import "../handoff"
import "../models"
import smath "../math"
import "../physics"
import "../input"
import "../platform"
import "../plugin"
import "../render"
import slog "../log"
import slua "../script/lua"
import "../settings"
import "../sight"
import "../sighthost"
import "../tools"
import "../world"
import "../worldstate"

SLOW_FRAME_MS :: f64(80)

// Debug (open-interiors walk-in): camera height above the arrival marker / exterior door
// when entering / exiting.
INTERIOR_EYE :: f32(96)

game_frame :: proc(g: ^Game) {
	frame_t0 := time.tick_now() // profile: whole-frame busy time (see `prof`)
	g.fr = {}
	render.ui_new_frame(&g.r)

	// Drive the input action manager for this frame: sample the SDL device state and
	// gate the "gameplay" context on whether ImGui owns the keyboard (the console/panels).
	// "global" actions (overlay toggle) stay live regardless.
	{
		_, kb_cap := render.ui_capturing(&g.r)
		input.set_context(&g.imgr, "gameplay", !kb_cap && !message_box_up(g))
		input.set_context(&g.imgr, "menu", !render.ui_typing(&g.r))
		f := platform.input_frame(&g.p)
		input.update(&g.imgr, &f)
	}

	if input.fired(&g.imgr, "ToggleOverlay") {
		g.show_overlay = !g.show_overlay
	}
	if input.fired(&g.imgr, "ToggleProfiler") {
		g.show_profiler = !g.show_profiler
	}
	// Pointer lock during gameplay (mouse-look, no button needed). The tilde/backtick dev overlay is the
	// cursor gate: overlay OPEN → cursor free to click its panels + console; overlay CLOSED → mouse locked
	// for look. (The overlay is on by default, so a fresh session starts cursor-free until you un-tilde.)
	// Applied on the next pump.
	platform.set_mouse_capture(&g.p, !g.show_overlay && !in_menu(g))
	g.fr.st = world.stream_stats(&g.streamer)

	frame_diag(g)
	if g.show_overlay {
		frame_overlay(g)
	}
	if g.show_profiler {
		frame_tick_graph(g)
	}
	frame_active_scene(g)
	frame_look(g)
	frame_debug_verbs(g)
	frame_message_box(g)
	frame_menus(g)
	park_for_menu(g)
	frame_subtitles(g)

	// The sim ticks on its own thread (sim_thread.odin): main hands it the controls and handles what
	// it sent.
	input := latch_input(g)
	handoff.publish(&g.simt.inputs, &input)
	handle_events(g)
	park_for_menu(g)
	if g.parks > 0 {run_console(g)} // parked, main owns the VM: a pausing menu keeps the console live
	handoff.take(&g.snaps, &g.snap)
	g.fr.alpha = tick_alpha(g.snap.at)
	sync_dialogue_menu(g)
	frame_active_scene(g) // a door in the last tick may have switched (or freed) the scene
	for s in ([]^world.Scene{&g.scene, g.fr.active_scene}) {s.poses, s.alpha, s.pretty, s.time = &g.snap.bodies, g.fr.alpha, g.pretty, g.elapsed}
	world.mark_posed(g.fr.active_scene, &g.snap.bodies) // the poses are the active space's

	frame_camera(g)
	frame_persistence(g)
	frame_stream(g)
	frame_inspect(g)
	frame_actor_grab(g)
	frame_hud(g) // publish g.snap.act to the prompt; draws into the UI drawlist end_frame composites
	audio.update(&g.audio, g.cam.pos, camera_forward(g.cam), g.p.dt, emitters(g))
	draw_actor_nametags(g)

	g.elapsed += g.p.dt
	frame_render(g)

	g.prof.frame += time.duration_milliseconds(time.tick_since(frame_t0))
	g.prof.frames += 1

	// Slow-frame detector: attribute any hitch to its phase (which one's delta dominates points
	// at the cause — physics, render/GPU-stall, or streaming). Fires on the H-shove freeze.
	if fms := time.duration_milliseconds(time.tick_since(frame_t0)); fms > SLOW_FRAME_MS {
		log.warnf(
			"SLOW FRAME %.0fms — stream=%.1f render=%.1f (acquire=%.1f)",
			fms,
			g.prof.stream - g.slowsnap.stream,
			g.prof.render - g.slowsnap.render, g.prof.acquire - g.slowsnap.acquire,
		)
	}
	g.slowsnap = {g.prof.stream, g.prof.render, g.prof.acquire}

	// POLICY (docs/memory.md): anything on context.temp_allocator lives for
	// exactly one frame — UI string formatting, draw lists, transient buffers.
	// Wiped here, every frame.
		free_all(context.temp_allocator)
}

// game_tick is ONE fixed simulation step on the sim thread — everything whose outcome must not
// depend on the display rate. The controls main latched come in first; a door crossing is a
// transition between ticks (send_parked). Scene select re-homes the capsule before it moves, physics
// steps the world it moved in, traversal reads the position it ended at, and the script phase runs last.
game_tick :: proc(g: ^Game) {
	worldstate.sim_enter()
	defer worldstate.sim_leave()
	context.temp_allocator = runtime.default_temp_allocator(&g.tick.temp)
	defer free_all(context.temp_allocator)
	handoff.take(&g.simt.inputs, &g.sim.input)
	t := time.tick_now()
	apply_commands(g)
	run_console(g)
	lap(g, .Commands, &t)
	tick_jail(g) // before the follow check, which carries a jailed player's move out
	lap(g, .Jail, &t)
	if player_moved(g) { // main carries the move out before anything here writes the player again
		send_parked(g, Evt_Follow{})
		return
	}
	lap(g, .Follow, &t)
	tgt := resolve_activation(g, g.sim.input.aim)
	tick_interact(g, tgt)
	tick_view(g)
	tick_cast(g, tgt)
	tick_dialogue(g)
	tick_activations(g)
	lap(g, .Activations, &t)
	frame_scene_select(g)
	sighthost.view = {g.sim.cur_phys, player_feet(g) + {0, 0, EYE_HEIGHT}, g.sim.input.view}
	lap(g, .Scene, &t)
	tick_actor_bodies(g) // laps its own parts
	t = time.tick_now()
	tick_projectiles(g)
	tick_swings(g)
	tick_magicphys(g)
	lap(g, .Projectiles, &t)
	if !inside(&g.sim.trav) {world.window_update(&g.sim.ext, &g.db, player_feet(g))}
	lap(g, .Window, &t)
	frame_physics(g)
	lap(g, .Physics, &t)
	frame_traversal(g)
	tick_force_greet(g)
	lap(g, .Traversal, &t)
	tick_weather(g)
	lap(g, .Weather, &t)
	audio.music_update(&g.sim.music, &g.audio, &g.v, &g.db, &g.sim.ws, worldstate.in_combat(&g.sim.ws, g.sim.ws.player), TICK_DT)
	audio.ambient_update(&g.sim.ambient, &g.audio, &g.v, &g.db, &g.sim.ws)
	lap(g, .Audio, &t)
	run_scripts(g)
	if len(g.sim.ws.asks) > 0 {send_parked(g, Evt_Ask{})} // the box pauses the world before the next tick
	t = time.tick_now()
	publish_snapshot(g)
	forward_ref_events(g)
	g.sim.input_was = g.sim.input
	lap(g, .Publish, &t)
	tick_prof_end(g)
}

// lap adds the time since `t` to a tick part and restarts `t`.
lap :: proc(g: ^Game, part: Tick_Part, t: ^time.Tick) {
	now := time.tick_now()
	g.tick.cur[part] += f32(time.duration_milliseconds(time.tick_diff(t^, now)))
	t^ = now
}

// tick_prof_end adds the tick's parts to the profile, and logs them when the tick was slow.
@(private = "file")
tick_prof_end :: proc(g: ^Game) {
	p := &g.tick.prof
	cur := g.tick.cur
	g.tick.cur = {}
	p.recent[p.ticks % TICK_HISTORY] = cur
	p.ticks += 1
	steps := g.sim.repl.vm.steps if g.repl_ok else {}
	for ms, s in steps {p.events[s] += f64(ms)}
	p.sight += sighthost.ms
	p.conditions += conditions.plugin_ms
	sighthost.ms, conditions.plugin_ms = 0, 0
	total: f32
	for ms, part in cur {
		p.ms[part] += f64(ms)
		total += ms
	}
	if total > SLOW_TICK_MS {
		log.warnf("SLOW TICK %.1fms:%s | Script_Events:%s", total, prof_parts(cur, 0.1), prof_parts(steps, 0.1))
	}
}

// prof_parts lists the parts of at least `min` ms, as " Part=ms ...".
prof_parts :: proc(parts: [$E]$T, min: f64) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ms, part in parts {
		if f64(ms) >= min {fmt.sbprintf(&b, " %v=%.2f", part, ms)}
	}
	return strings.to_string(b)
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
	cell := world.grid_of(g.snap.body.feet.to)
	mc, tc, mb, tb, cold, coldb, tcold, tcoldb := world.cache_counts(&g.scene)
	lob, lor := world.lod_object_stats(&g.scene)
	ps := g.snap.phys // the exterior — where the streaming-churn leak would be
	tp := prof_since(g.snap.prof, g.tick_seen)
	g.tick_seen = g.snap.prof
	log.infof(
		"diag: cell (%d,%d) chunks=%d cache models=%d (%dMB) tex=%d (%dMB) cold=%d (%dMB) texcold=%d (%dMB) lodobj=%d/%d rss=%dMB",
		cell.x, cell.y, st.chunks, mc, mb / (1024 * 1024), tc, tb / (1024 * 1024), cold, coldb / (1024 * 1024),
		tcold, tcoldb / (1024 * 1024), lor, lob, proc_rss_mb(),
	)
	// Frame-time profile (avg ms over the window) — the phase whose avg climbs is the
	// fps eater. n = frames sampled. inv := 1/n.
	if g.prof.frames > 0 {
		inv := 1.0 / f64(g.prof.frames)
		log.infof(
			"prof: frame=%.2fms stream=%.2f render=%.2f (avg/%d frames, %d sim ticks)",
			g.prof.frame * inv, g.prof.stream * inv, g.prof.render * inv,
			g.prof.frames, tp.ticks,
		)
		// Render breakdown (ms): acquire = GPU-bound stall; the rest are CPU draw-submission
		// per pass. If acquire ≫ passes, we're GPU-bound (fix = fewer/cheaper draws + verts);
		// if passes dominate, CPU-bound (fix = fewer draw calls / less iteration).
		log.infof(
			"prof.render: acquire=%.2f terrain=%.2f near=%.2f objdraw=%.2f grass=%.2f water=%.2f effects=%.2f",
			g.prof.acquire * inv, g.prof.terrain * inv, g.prof.near * inv,
			g.prof.objdraw * inv, g.prof.grass * inv, g.prof.water * inv, g.prof.effects * inv,
		)
	}
	if tp.ticks > 0 {
		// Sim breakdown (avg ms per tick): the part that climbs is what stalls the frame.
		inv := 1.0 / f64(tp.ticks)
		total: f64
		for &ms in tp.ms {
			ms *= inv
			total += ms
		}
		for &ms in tp.events {ms *= inv}
		log.infof("prof.tick: total=%.2f%s (avg/%d ticks)", total, prof_parts(tp.ms, 0.005), tp.ticks)
		log.infof("prof.events:%s (avg/%d ticks)", prof_parts(tp.events, 0.005), tp.ticks)
		log.infof(
			"prof.seams: detection=%.2f (%s) combat=%.2f (%s) sight=%.2f (%s) conditions=%.2f (%s) magic (%s)",
			tp.ms[.Detection], plugin.owner(&g.plugins, detection.SEAM), tp.ms[.Combat], plugin.owner(&g.plugins, combat.SEAM),
			tp.sight * inv, plugin.owner(&g.plugins, sight.SEAM), tp.conditions * inv, plugin.owner(&g.plugins, condfn.SEAM),
			plugin.owner(&g.plugins, magic.SEAM),
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

// frame_tick_graph draws the sim's last ticks, oldest first, as a stacked graph of their parts.
@(private = "file")
frame_tick_graph :: proc(g: ^Game) {
	p := &g.snap.prof
	n := min(p.ticks, TICK_HISTORY)
	ticks := make([]Tick_Sample, n, context.temp_allocator)
	for &s, i in ticks {s = p.recent[(p.ticks - n + i) % TICK_HISTORY]}
	tools.stack_graph("tick", slice.reinterpret([]f32, ticks), reflect.enum_field_names(Tick_Part), 1000.0 / TICK_HZ)
}

// frame_overlay draws + handles the whole dev overlay (` toggles it in game_frame). Hidden =
// no panels, so ImGui captures nothing and the camera/door keys drive the bare scene; the
// game-logic keys (F, etc.) are independent of the panels and keep working in the helpers below.
@(private = "file")
frame_overlay :: proc(g: ^Game) {
	if tools.debug_overlay(g.p.dt, g.logging.persisting, g.logging.persist_path, &g.pretty) {
		_ = slog.persist_run(g.logging)
	}
	st := g.fr.st
	cell := world.grid_of(g.snap.body.feet.to)
	tools.stream_panel(cell.x, cell.y, st.chunks, st.inflight, st.reqs, st.ready)
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
		if act == .Enter || act == .Exit {sim_drain(g)} // `entered` picks the sim's space (active_space)
		defer if act == .Enter || act == .Exit {sim_resume(g)}
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

	// Dev console: the submitted line goes to the sim, which evaluates it on the gameplay REPL
	// (run_console); its output (results / print / errors) comes back and is echoed here.
	if cmd := tools.console_panel(&g.console); cmd != "" {
		tools.console_printf(&g.console, "> %s", cmd)
		if g.repl_ok {handoff.push(&g.console_in, strings.clone(cmd))}
		log.infof("console: %q", cmd)
	}
	handoff.drain(&g.console_out, &g.console_out_buf)
	for line in g.console_out_buf {
		tools.console_print(&g.console, line)
		delete(line)
	}
}

// frame_active_scene resolves which scene main draws the player in and whether it's a full-screen
// interior: the place main was last shown (show_place).
frame_active_scene :: proc(g: ^Game) {
	// The experimental open-interiors path keeps its own debug walk-in (`entered`); the base
	// path is driven by the Traversal door navigator.
	if g.interiors_on {
		g.fr.in_interior = g.entered
		g.fr.active_scene = &g.interiors.interior_scene if g.entered else &g.scene
	} else {
		g.fr.in_interior = g.shown.interior != 0
		g.fr.active_scene = &g.interior if g.fr.in_interior else &g.scene
	}
}

// frame_scene_select resolves the active scene, applies pending script scene-ops, and re-homes
// the player capsule if the active physics world changed. First thing in the tick, so the
// capsule re-homes into the active world before it's moved.
@(private = "file")
frame_scene_select :: proc(g: ^Game) {

	// Deferred scene-apply (decision #3): drain the overlay changes script natives wrote this
	// frame (e.g. a console `sel:Disable()`) into the active space's live cells — the fixed point
	// where hide/move/scale/remove land, before physics rebuilds collision.
	if sp := active_space(g); sp != nil {world.apply_pending_scene_ops(sp, &g.db)}

	// On a door transition the active physics world changes (exterior `phys` ↔ an interior's own
	// world): drop every body; the actor tick rebuilds them in the new world at their refs. A nil
	// active world (physics off, or the experimental portal interior, which has none) → no bodies
	// → free-fly.
	sp := active_space(g)
	want_phys := sp.phys if sp != nil else nil
	if want_phys != g.sim.cur_phys {
		actor_bodies_clear(g)
		g.sim.cur_phys = want_phys
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

// input_move is the player's controller: camera-relative WASD at the current yaw, Shift sprint,
// Space jump. Free-fly moves in frame_camera instead — no solver, so it has nothing to keep
// deterministic.
input_move :: proc(g: ^Game) -> (vel: [2]f32, jump: bool) {
	move := g.sim.input.move
	cy, sy := math.cos(g.sim.input.yaw), math.sin(g.sim.input.yaw)
	dir := [2]f32{cy * move.x + sy * move.y, sy * move.x - cy * move.y}
	mag := math.sqrt(dir.x * dir.x + dir.y * dir.y)
	if g.sim.input.sprint {actorstate.leave(&g.sim.ws.states, g.sim.ws.player, actorstate.SNEAK)} // sprinting stands up
	speed := SPRINT_SPEED if g.sim.input.sprint else SNEAK_SPEED if actorstate.current(&g.sim.ws.states, g.sim.ws.player) == actorstate.SNEAK else RUN_SPEED
	if mag > 0.001 {vel = {dir.x / mag * speed, dir.y / mag * speed}}
	return vel, move.z > 0.5
}

// frame_camera puts the eye where this frame should see it: the capsule's position blended
// across the tick the frame sits inside (walking looks smooth above 60 fps), or the free-fly
// camera flown at render rate.
@(private = "file")
frame_camera :: proc(g: ^Game) {
	if g.snap.walking {
		head := blend(g.snap.follow, g.fr.alpha) + {0, 0, EYE_HEIGHT}
		g.cam.pos = head - camera_forward(g.cam) * g.snap.boom
		return
	}
	move := g.p.input.move
	if g.fr.kb_cap {move = {}}
	camera_fly(&g.cam, move, g.p.input.fast, g.p.dt)
}

// frame_debug_verbs handles the physics-verification keys: G drop-test ball, K hitbox
// wireframe toggle, H clutter shove.
@(private = "file")
frame_debug_verbs :: proc(g: ^Game) {
	if input.fired(&g.imgr, "NoClip") {handoff.push(&g.commands, Cmd_Noclip{})}
	if input.fired(&g.imgr, "DevDrop") {handoff.push(&g.commands, Cmd_Drop{g.cam.pos})}
	if input.fired(&g.imgr, "DevShove") {handoff.push(&g.commands, Cmd_Shove{g.cam.pos})}

	// Collision-hitbox overlay toggle (K): show the green wireframe of what Jolt actually collides.
	if input.fired(&g.imgr, "DevHitbox") {
		g.show_hitboxes = !g.show_hitboxes
		world.clear_collision_debug(&g.scene) // rebuild fresh each enable (picks up late-loaded models)
		if g.interiors_on {world.clear_collision_debug(&g.interiors.interior_scene)}
		log.infof("collision hitboxes: %v", g.show_hitboxes)
	}
	if input.fired(&g.imgr, "DevMessageBox") {dev_message_box(g)}
}

// dev_message_box opens the next box MESG of the load order, one per press, and logs the pick.
@(private = "file")
dev_message_box :: proc(g: ^Game) {
	i := 0
	for form, m in g.db.messages {
		if !m.message_box {continue}
		if i == g.dev_box {
			g.dev_box += 1
			log.infof("dev box: MESG 0x%X", form)
			message_box_open(g, m.body, m.buttons, proc(g: ^Game, pick: int) {log.infof("dev box: picked %d", pick)})
			return
		}
		i += 1
	}
	g.dev_box = 0
}

// drop_ball spawns a falling ball (physics verification). Exterior only: the markers read
// positions from `phys`, so a ball dropped inside an interior (a different world) wouldn't track.
drop_ball :: proc(g: ^Game, at: smath.Vec3) {
	if !g.phys_ok || inside(&g.sim.trav) {return}
	b := physics.add_sphere(&g.phys, 24, at, is_dynamic = true)
	if b != 0 {append(&g.sim.drops, b)}
	log.infof("drop-test: ball %d at (%.0f, %.0f, %.0f)", len(g.sim.drops), at.x, at.y, at.z)
}

// shove kicks nearby movable clutter so it scatters and resettles — a visible check of the 3b
// dynamic-body path.
shove :: proc(g: ^Game, at: smath.Vec3) {
	t_shove := time.tick_now()
	sp := active_space(g)
	if sp == nil {return}
	n := world.shove_clutter(sp, at, 400)
	act := physics.num_active(sp.phys) if sp.phys != nil else 0
	log.infof("shove: kicked %d clutter bodies in %.1fms (active now %d)", n, time.duration_milliseconds(time.tick_since(t_shove)), act)
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
	sim_drain(g) // a save lands between whole ticks
	defer sim_resume(g)
	_ = os.make_directory(g.saves_dir) // idempotent (errors harmlessly if it exists)
	player_follow(g)
	player_publish(g)
	player, _ := worldstate.get(&g.sim.ws, g.sim.ws.player)
	man := worldstate.Save_Manifest {
		save_number  = g.save_no + 1,
		created_unix = time.to_unix_nanoseconds(time.now()),
		game_cell    = player.cell,
	}
	if g.repl_ok {slua.save_scripts(&g.sim.repl.vm)}
	plugin.save_data(&g.plugins, &g.sim.ws.plugin_blobs)
	if worldstate.save_to_file(&g.sim.ws, g.quicksave_path, man, &g.save_bridge) {
		g.save_no += 1
		log.infof("quicksave: wrote %s (%d deltas)", g.quicksave_path, worldstate.count(&g.sim.ws))
	} else {
		log.errorf("quicksave: FAILED to write %s", g.quicksave_path)
	}
}

quickload :: proc(g: ^Game) {
	sim_drain(g)
	defer sim_resume(g)
	m, ok := worldstate.load_from_file(&g.sim.ws, g.quicksave_path, &g.save_bridge)
	if !ok {
		log.warnf("quickload: no valid save at %s", g.quicksave_path)
		return
	}
	log.infof("quickload: loaded %s (%d deltas)", g.quicksave_path, m.delta_count)
	worldstate.split_scripted_counts(&g.sim.ws, &g.db)
	if g.repl_ok {slua.reload_scripts(&g.sim.repl.vm, &g.db)}
	plugin.load_data(&g.plugins, g.sim.ws.plugin_blobs)
	g.sim.trans.location = nil
	// Exterior: rebuild resident chunks from baseline ⊕ the loaded overlay — full
	// reconciliation (created add/remove, disabled/moved/scaled reset to the saved state).
	// The rebuild flags object collision for re-cook; run it behind the dedicated load
	// screen (reused from boot) so the world is solid before gameplay resumes.
	world.rebuild_resident_overlay(&g.sim.ext, &g.db)
	// Back to the saved cell and position, then the load screen builds + solidifies that bubble.
	// Saved in the interior we stand in: rebuild it so the loaded overlay applies.
	if kind := player_restore(g); kind == .Stay || kind == .None {traversal_reload(&g.sim.trav)}
	load_screen_stream(g, "Loading save…", 0, 1)
}

// frame_stream re-windows the exterior around the (now-moved) camera — unless we're inside an
// interior (camera is in interior-local space; the streamer is paused). Uploads decoded models
// under the per-frame budget. Never blocks.
@(private = "file")
frame_stream :: proc(g: ^Game) {
	t_stream := time.tick_now()
	world.stream_update(&g.streamer)
	if !g.fr.in_interior {
		world.update_terrain_field(&g.scene, g.cam.pos) // re-select CDLOD terrain LOD on move
		if g.interiors_on && !g.entered {
			// Open interiors (EXPERIMENTAL): keep the nearest in-range portal's interior
			// loaded (GPU work, so outside begin_frame). Rendered through the doorway below. Not
			// while entered: the sim then runs in that interior's space.
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

// player_heading is the way the camera faces, as a ref's z rotation.
player_heading :: proc(g: ^Game) -> f32 {return math.PI / 2 - g.sim.input.yaw}

// player_place writes the player's feet into its ref's Moved delta: the cell under the player
// (interior, or exterior grid cell), the position, and the heading. player_follow compares against it.
player_place :: proc(g: ^Game, feet: smath.Vec3) {
	place := g.sim.trav.place
	cell := place.interior if place.interior != 0 else gamedb.cell_under(&g.db, place.world, feet)
	worldstate.set_moved(&g.sim.ws, g.sim.ws.player, cell, smath.trs(feet, {0, 0, player_heading(g)}, 1), feet)
	g.sim.published = {cell, feet}
}

// player_publish places the player where main flew it while it has no body (physics off, or its
// collision not ready yet); a body publishes itself in the actor tick.
player_publish :: proc(g: ^Game) {
	if g.sim.ws.player not_in g.sim.actor_bodies {player_place(g, player_feet(g))}
}

// player_moved reports whether a script moved the player's ref (MoveTo, SetPosition) since the
// sim last placed it.
player_moved :: proc(g: ^Game) -> bool {
	d, ok := worldstate.get(&g.sim.ws, g.sim.ws.player)
	if !ok || .Moved not_in d.live {return false}
	if b, has := g.sim.actor_bodies[g.sim.ws.player]; has {return d.pos != b.placed}
	return Placement{d.cell, d.pos} != g.sim.published
}

// player_follow places the player where a script moved its ref, running any load that needs.
// Main runs it with the sim parked.
player_follow :: proc(g: ^Game) {
	if player_moved(g) {traversal_finish_load(g, player_restore(g))}
}

// (hole world-reload :tags (world player mods) :sev gap) nothing re-seats the world around the controlled actor: after a possess (or a mod swapping the player actor) traversal's place, the streaming window, the weather and the camera stay where the old actor was until a door crossing. Wanted: one reload primitive, callable any time by the engine and by mods through the script API, that parks the sim and rebuilds place, window and scenes from ws.player's ref, as player_follow does for a moved ref; then weather and the rest key off what it seats.
// request_reload asks for the world to be re-seated around ws.player.
request_reload :: proc(g: ^Game) {}

// cross_door takes the player through a load door. Main runs it with the sim parked: the load
// builds scenes with the renderer and draws its own frames.
cross_door :: proc(g: ^Game, hit: Door_Hit) {
	if np, nyaw, kind := go_through(&g.sim.trav, hit); kind != .None {
		player_teleport(g, np, nyaw, 0)
		traversal_finish_load(g, kind)
	}
}

// player_restore places the player where its ref's delta says, in any cell, and returns what the
// traversal did; the caller runs the load screen it still needs.
player_restore :: proc(g: ^Game) -> Traversal_Kind {
	d, ok := worldstate.get(&g.sim.ws, g.sim.ws.player)
	if !ok || .Moved not_in d.live || g.interiors_on {return .None}
	kind := traversal_go_to(&g.sim.trav, d.cell, d.pos)
	if kind == .None {return .None}
	player_teleport(g, d.pos, math.PI / 2 - math.atan2(d.world[0, 1], d.world[0, 0]), 0)
	return kind
}

// frame_physics (Phase 2e): build collision bodies for newly-resolved instances of the ACTIVE
// world (streamed exterior, or the interior cell) then advance THAT world's sim by one fixed
// TICK_DT — never a real dt, so the solver converges the same on every machine. Interiors
// build their bodies behind the load screen (settle_interior), so sync_physics here is a no-op for
// them; the exterior keeps building as cells stream in.
@(private = "file")
frame_physics :: proc(g: ^Game) {
	if g.sim.cur_phys != nil {
		// New cells streaming in add static bodies; rebuild the broadphase the frames they
		// do (made > 0) so the quad-tree stays balanced — without this the exterior tree
		// degrades with every incremental add and the step time climbs steadily. Interiors
		// build + optimize on entry, so sync_physics is a no-op there and this never fires.
		// Sub-timers (diagnostic): split the phys phase so a hitch names the culprit op.
		ts := time.tick_now()
		sp := active_space(g)
		built_n := world.sync_physics(sp)
		ms_sync := time.duration_milliseconds(time.tick_since(ts))
		ms_opt: f64
		if built_n > 0 {
			ts = time.tick_now()
			physics.optimize_broadphase(g.sim.cur_phys)
			ms_opt = time.duration_milliseconds(time.tick_since(ts))
		}
		ts = time.tick_now()
		physics.step(g.sim.cur_phys, TICK_DT)
		ms_step := time.duration_milliseconds(time.tick_since(ts))
		ts = time.tick_now()
		world.capture_settles(sp) // overlay: snapshot clutter that just came to rest (3c)
		ms_settle := time.duration_milliseconds(time.tick_since(ts))
		if ms_sync + ms_opt + ms_step + ms_settle > SLOW_FRAME_MS {
			log.warnf(
				"SLOW PHYS — sync=%.1f(built %d) optimize=%.1f step=%.1f settle=%.1f | active=%d/%d bodies",
				ms_sync, built_n, ms_opt, ms_step, ms_settle,
				physics.num_active(g.sim.cur_phys), physics.num_bodies(g.sim.cur_phys),
			)
		}
	}
}

// frame_traversal drives the PROXIMITY half of base door traversal: invisible auto-load doors
// (cave/dungeon AutoLoadMarkers) cross with no key when you walk into them. Manual doors (real
// meshes, incl. city gates) are crossed by the crosshair now — you look at the door and press
// Activate — so they're handled in tick_interact, not here. Inert on the experimental
// open-interiors path (it has its own walk-in).
@(private = "file")
frame_traversal :: proc(g: ^Game) {
	if g.interiors_on {
		return
	}
	eye := player_feet(g) + {0, 0, EYE_HEIGHT}
	traversal_arrival_update(&g.sim.trav, eye) // re-arm auto-fire once clear of the last landing
	// Auto-load only: the nearest door scan exists to catch the invisible markers the crosshair can't
	// hit. A manual door found here is ignored — Activate crosses it via the crosshair (tick_interact).
	hit := traversal_nearest_door(&g.sim.trav, eye)
	if hit.ok && hit.auto && hit.dist <= AUTO_DOOR_RANGE && !g.sim.trav.has_arrival {
		send_parked(g, Evt_Door{hit})
	}
}

// player_teleport moves the player's feet outright — camera AND capsule. Main runs it with the sim
// parked. Both must move: frame_camera reads the eye back off the published capsule, so setting
// only the camera snaps straight back next frame. A crossing that also swaps physics world leaves
// the capsule to frame_scene_select (which re-creates it in the new world at player_feet);
// setting it here first is harmless there and is what carries the same-world case, a city gate.
player_teleport :: proc(g: ^Game, feet: smath.Vec3, yaw, pitch: f32) {
	g.cam.pos, g.cam.yaw, g.cam.pitch = feet + {0, 0, EYE_HEIGHT}, yaw, pitch
	g.sim.input.eye, g.sim.input.yaw = feet + {0, 0, EYE_HEIGHT}, yaw // the rest of this frame's ticks see the move
	if b, ok := &g.sim.actor_bodies[g.sim.ws.player]; ok {
		physics.character_set_position(&b.char, feet)
		b.placed = feet
	}
	player_place(g, feet)
	publish_snapshot(g)
}

// traversal_finish_load shows main what a transition did, with the load screen it needs. Main runs it
// with the sim parked. A city gate or a far jump fills the exterior bubble (like Skyrim's city load);
// an interior loads its models behind its own load screen, then the sim builds its bodies; an exterior
// return is instant (the live cells stayed).
traversal_finish_load :: proc(g: ^Game, kind: Traversal_Kind) {
	switch kind {
	case .City, .Jump:
		load_screen_stream(g, "Loading…", 0, 1) // clears the load screen at its end
	case .Interior:
		catch_up(g)
		settle_interior(&g.sim.trav)
		loadui_hide(g)
	case .Exit:
		catch_up(g)
	case .Stay, .None:
	}
}

// catch_up has main draw what the parked sim changed: the player's place, then its live cells.
catch_up :: proc(g: ^Game) {
	handoff.push(&g.events, Evt_Place{g.sim.trav.place})
	forward_ref_events(g)
	handle_events(g)
}

// show_place makes main draw a place: the interior's scene, and the exterior's worldspace.
show_place :: proc(g: ^Game, p: Place) {
	if p == g.shown {return}
	if g.shown.interior != 0 {
		world.scene_destroy(&g.interior)
		g.interior = {}
	}
	if p.world != g.shown.world {
		world.stream_retarget(&g.streamer, p.world)
		world.release_terrain_field(&g.scene)
		world.build_terrain_field(&g.scene, &g.db, p.world)
	}
	if p.interior != 0 {
		g.interior = world.scene_init(&g.r, &g.v, &g.collisions)
		g.interior.dynamic_clutter = true
	}
	g.shown = p
	frame_active_scene(g) // the rest of this frame draws the new scene
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
				models.path(inst.model_id),
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
				handoff.push(&g.commands, Cmd_Select{inst.form_id})
				tools.console_printf(&g.console, "[sel] 0x%08X (%s)", u64(inst.form_id), models.path(inst.model_id))
			}
		}
	}

	// Disable-test (Ctrl-hover + X): record a Disabled delta for the hovered ref and hide it live —
	// the Layer-1 mutation verb end-to-end (overlay delta + live-apply; persists via apply_overlay
	// on cell reload). Spread target: Alvor's house (exterior) + Sleeping Giant fireplaces (interior).
	if input.fired(&g.imgr, "DevDisable") && active_scene.has_hover {
		if chunk, ok := &active_scene.chunks[active_scene.hover_cell];
		   ok && active_scene.hover_inst >= 0 && active_scene.hover_inst < len(chunk.instances) {
			handoff.push(&g.commands, Cmd_Disable{chunk.instances[active_scene.hover_inst].form_id, active_scene.hover_cell})
		}
	}

	// Spawn-test (Ctrl-hover + B): mint a runtime created ref (0xFF space) — a copy of the hovered
	// ref's base form — at the camera, in the hovered ref's cell. Exercises the created-ref store +
	// additive overlay + live spawn; it persists (F5) and respawns on cell reload.
	if input.fired(&g.imgr, "DevSpawn") && active_scene.has_hover {
		if chunk, ok := &active_scene.chunks[active_scene.hover_cell];
		   ok && active_scene.hover_inst >= 0 && active_scene.hover_inst < len(chunk.instances) {
			handoff.push(&g.commands, Cmd_Spawn{chunk.instances[active_scene.hover_inst].base, active_scene.hover_cell, g.cam.pos})
		}
	}
}

dev_disable :: proc(g: ^Game, c: Cmd_Disable) {
	if sp := active_space(g); sp != nil && world.disable_ref(sp, c.ref, c.cell, true) {
		log.infof("disable: ref 0x%08X hidden", c.ref)
	} else {
		log.warnf("disable: scene has no overlay — ref 0x%08X not recorded", c.ref)
	}
}

dev_spawn :: proc(g: ^Game, c: Cmd_Spawn) {
	sp := active_space(g)
	id := world.create_ref(sp, &g.db, c.base, c.cell, c.at, {0, 0, 0}, 1) if sp != nil else 0
	if id != 0 {
		log.infof("spawn: created ref 0x%08X (base 0x%08X) at camera", id, c.base)
	} else {
		log.warnf("spawn: no overlay / base 0x%08X has no model — nothing created", c.base)
	}
}

// select_actor makes an actor the Inspector's selection and the console's `sel`.
@(private = "file")
select_actor :: proc(g: ^Game, actor: Form_ID) {
	g.fr.active_scene.has_sel = false
	g.insp.has_sel = true
	tools.inspector_set_model_strings(&g.insp, "", "")
	for v in g.snap.actors {
		if v.form != actor {continue}
		g.insp.sel_display = text(&g.snap, v.name)
		g.insp.sel_base = v.base
		g.insp.sel_pos = blend(v.feet, g.fr.alpha)
	}
	g.insp.sel_rot = {}
	g.insp.sel_has_door = false
	g.insp.sel_door_cell = ""
	g.insp.sel_is_door = false
	if g.repl_ok {
		handoff.push(&g.commands, Cmd_Select{actor})
		tools.console_printf(&g.console, "[sel] 0x%08X (%s)", u64(actor), g.insp.sel_display)
	}
}

SKY_COLOR :: [4]f32{0.45, 0.58, 0.78, 1.0} // the clear colour behind the world (no sky yet)

// frame_render acquires the swapchain, has the graphics table draw the scene into the frame's
// target, and composes the UI over it.
@(private = "file")
frame_render :: proc(g: ^Game) {
	t_render := time.tick_now()
	t_acq := time.tick_now()
	acquired := render.frame_acquire(&g.r) // blocks here if the GPU is behind → GPU-bound shows up in `acquire`
	g.prof.acquire += time.duration_milliseconds(time.tick_since(t_acq))
	if acquired {
		draw_graphics(g)
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

// emitters are where the snapshot's moving refs are this frame, for sounds that follow them.
emitters :: proc(g: ^Game) -> map[Form_ID][3]f32 {
	at := make(map[Form_ID][3]f32, allocator = context.temp_allocator)
	at[g.snap.body.form] = blend(g.snap.body.feet, g.fr.alpha)
	for v in g.snap.actors {at[v.form] = blend(v.feet, g.fr.alpha)}
	for key in g.snap.bodies.at {
		if key.part != world.WHOLE {continue}
		if m, ok := world.posed(&g.snap.bodies, key, g.fr.alpha); ok {at[key.form] = (m * [4]f32{0, 0, 0, 1}).xyz}
	}
	return at
}
