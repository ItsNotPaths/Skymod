package main

// Logo test sandbox (`--logotest`). Renders the menu logo (logo.nif) ALONE with a free-fly camera,
// to isolate the mesh from the menu's UI integration: if the logo shows here but not in the menu,
// the bug is the menu camera/compositing; if it's invisible here too, it's the NIF itself (geometry,
// material, scale, or the camera framing). Also draws a unit reference cube at the origin as a
// "does any 3D render?" sanity check. Throwaway harness; mounts the vanilla archives directly.

import "core:log"
import "core:math"

import smath "../math"
import "../platform"
import "../render"
import "../settings"
import "../vfs"

run_logo_test :: proc(cfg: ^settings.Config) {
	src := settings.get(cfg, "source_game")
	if src == "" {
		log.error("--logotest: source_game not set in settings.txt")
		return
	}
	p, ok := platform.init("SkyMod — Logo test", WINDOW_W, WINDOW_H)
	if !ok {
		return
	}
	defer platform.shutdown(&p)
	r, rok := render.init(p.window)
	if !rok {
		return
	}
	defer render.shutdown(&r)
	render.ui_init(&r)
	defer render.ui_shutdown(&r)
	p.on_event = render.ui_process_event

	v := mount_game(src)
	defer vfs.destroy(&v)

	logo, lok := menu_logo_load(&r, &v)
	if !lok {
		log.error("--logotest: logo.nif failed to load")
		return
	}
	defer menu_logo_destroy(&r, &logo)
	log.infof("--logotest: %d shape(s), center=%v radius=%.1f", len(logo.shapes), logo.center, logo.radius)
	for s, i in logo.shapes {
		log.infof("--logotest:   shape %d: tex=%v alpha_cutoff=%.2f", i, s.tex.tex != nil, s.alpha_cutoff)
	}

	cfg := menu_logo_cfg_default()
	// Start in front of the logo (−Y), pulled back, looking toward it. RMB+WASD to fly to find it.
	cam := Camera{pos = logo.center + smath.Vec3{0, -logo.radius * 2, logo.radius * 0.3}, yaw = math.PI * 0.5, pitch = -0.1}
	log.info("--logotest: RMB look, WASD/QE fly. Esc quits.")

	for platform.pump(&p) {
		render.ui_new_frame(&r)

		mouse_cap, kb_cap := render.ui_capturing(&r)
		move, look := p.input.move, p.input.look
		if kb_cap {move = {}}
		if mouse_cap {look = {}}
		camera_update(&cam, move, look, p.input.fast, p.dt)

		render.set_lighting(&r, menu_logo_light(&cfg))
		if render.begin_frame(&r, {0.10, 0.11, 0.13, 1.0}) {
			vp := camera_view_proj(cam, render.aspect(&r))
			render.draw_cube(&r, vp) // reference: unit cube at the origin (confirms 3D renders)
			for s in logo.shapes {
				render.draw_mesh(&r, s.mesh, vp, s.world, s.tex, s.alpha_cutoff)
			}
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)
	}
}
