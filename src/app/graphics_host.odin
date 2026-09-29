package main

// The host side of the graphics seam (src/graphics): the frame each draw gets, the Host queries,
// and the built-in, which draws the loaded scene fullbright with the actor capsules.

import "base:runtime"
import "core:mem"
import "core:time"
import "../graphics"
import "../models"
import "../plugin"
import "../render"
import "../vfs"
import "../world"
import "../worldstate"

@(private = "file")
Host_Data :: struct {
	ctx: runtime.Context,
	g:   ^Game,
}

// draw_graphics runs the graphics table for this frame. Call between frame_acquire and end_frame.
draw_graphics :: proc(g: ^Game) {
	d := Host_Data{context, g}
	actors := make([dynamic]graphics.Actor, 0, len(g.snap.actors), context.temp_allocator)
	for v in g.snap.actors {append(&actors, graphics_actor(g, v))}
	cells := make([dynamic]graphics.Cell, 0, context.temp_allocator)
	for _, &c in drawn_scene(g).chunks {
		append(&cells, graphics.Cell{c.cell_form_id, c.gx, c.gy, !c.has_grid})
	}
	visuals := make([]graphics.Visual, len(g.snap.visuals), context.temp_allocator)
	for v, i in g.snap.visuals {
		visuals[i] = v.visual
		visuals[i].node = cstring_temp(text(&g.snap, v.node))
	}
	f := graphics.Frame {
		host = {&d, host_refs, host_model_path, host_read_file},
		table = &g.graphics,
		device = g.r.device,
		cmd = g.r.frame_cmd,
		target = g.r.present_tex,
		format = u32(g.r.swapchain_format),
		width = g.r.present_w,
		height = g.r.present_h,
		camera = {g.cam.pos, camera_view(g.cam), camera_proj(render.aspect(&g.r))},
		time = g.elapsed,
		interior = g.fr.in_interior,
		first_person = g.snap.first_person,
		player = graphics_actor(g, g.snap.body),
		actors = plugin.span(actors[:]),
		cells = plugin.span(cells[:]),
		visuals = plugin.span(visuals[:]),
	}
	g.graphics.draw(&f)
}

// Visual_View is a visual in the snapshot; its node name is in the snapshot's text.
Visual_View :: struct {
	visual: graphics.Visual, // node is nil
	node:   Text_Span,
}

@(private = "file", rodata)
visual_kinds := [worldstate.Visual_Kind]graphics.Visual_Kind {
	.Shader = .Shader,
	.Art    = .Art,
	.Impact = .Impact,
	.Imod   = .Imod,
}

// view_visuals copies the sim's visuals into the snapshot.
view_visuals :: proc(g: ^Game, s: ^Snapshot) {
	clear(&s.visuals)
	now := g.sim.ws.clock.played
	for h, v in g.sim.ws.visuals {
		append(&s.visuals, Visual_View{
			visual = {
				handle = h,
				kind = visual_kinds[v.kind],
				form = v.form,
				ref = v.ref,
				facing = v.facing,
				strength = v.strength,
				cross = v.cross,
				fade = v.fade,
				age = f32(now - v.start),
				left = f32(v.until - now) if v.until > 0 else 0,
			},
			node = add_text(s, v.node),
		})
	}
}

// drawn_scene is the scene the camera is in: the interior entered, else the exterior.
@(private = "file")
drawn_scene :: proc(g: ^Game) -> ^world.Scene {
	return g.fr.active_scene if g.fr.in_interior else &g.scene
}

@(private = "file")
graphics_actor :: proc(g: ^Game, v: Actor_View) -> graphics.Actor {
	return {v.form, v.base, blend(v.feet, g.fr.alpha), v.capsule.radius, v.capsule.half_h, v.dead}
}

@(private = "file")
host_refs :: proc "c" (data: rawptr, out: [^]graphics.Ref, cap: int) -> int {
	d := (^Host_Data)(data)
	context = d.ctx
	s := drawn_scene(d.g)
	n := 0
	for _, &c in s.chunks {
		for &inst in c.instances {
			if n < cap {
				out[n] = {inst.form_id, inst.base, c.cell_form_id, u32(inst.model_id), world.instance_world(s, &inst), inst.vis != .Show}
			}
			n += 1
		}
	}
	return n
}

@(private = "file")
host_model_path :: proc "c" (data: rawptr, model: u32) -> cstring {
	context = (^Host_Data)(data).ctx
	return cstring_temp(models.path(models.ID(model)))
}

@(private = "file")
host_read_file :: proc "c" (data: rawptr, path: cstring, out: [^]u8, cap: int) -> int {
	d := (^Host_Data)(data)
	context = d.ctx
	bytes, ok := vfs.read(&d.g.v, string(path), context.temp_allocator)
	if !ok {return -1}
	if len(bytes) <= cap {mem.copy(out, raw_data(bytes), len(bytes))}
	return len(bytes)
}

@(private = "file")
cstring_temp :: proc(s: string) -> cstring {
	b := make([]u8, len(s) + 1, context.temp_allocator)
	copy(b, s)
	return cstring(raw_data(b))
}

GRAPHICS_BUILTIN :: graphics.Table{draw_builtin}

// (hole graphics-gpu-streaming :tags (render unclaimed) :sev polish) the streamer uploads every mesh, texture, terrain and grass batch to the GPU for the built-in, also when a plugin owns graphics and never reads them.
@(private = "file")
draw_builtin :: proc "c" (f: ^graphics.Frame) {
	g := (^Host_Data)(f.host.data).g
	context = (^Host_Data)(f.host.data).ctx
	in_interior, active_scene := g.fr.in_interior, g.fr.active_scene
	// A portal interior is loaded and (when not entered) viewed through the doorway.
	interior_active := g.interiors_on && g.interiors.active

	// Snapshot the drawn scene's chunks into its flat per-frame list once (Fix A): every
	// draw pass below iterates that tight array instead of walking the chunk MAP and
	// streaming its big inline Chunk values through cache ~9×/frame.
	world.cull_begin(drawn_scene(g))
	render.scene_begin(&g.r, SKY_COLOR)
	vp := f.camera.proj * f.camera.view
	if in_interior {
		// Inside a loaded interior cell (interior-local coords): draw it full-screen.
		world.draw(active_scene, &g.r, vp)
		world.draw_effects(active_scene, &g.r, vp, f.time)
		world.draw_highlight(active_scene, &g.r, vp)
	} else {
		t_terrain := time.tick_now()
		world.draw_terrain_field(&g.scene, &g.r, vp, f.camera.pos) // CDLOD whole-world terrain (drawn under streamed detail)
		g.prof.terrain += time.duration_milliseconds(time.tick_since(t_terrain))
		t_near := time.tick_now()
		world.draw(&g.scene, &g.r, vp)
		g.prof.near += time.duration_milliseconds(time.tick_since(t_near))
		// Drop-test markers: a box at each falling ball's pose, blended across the tick.
		for i in 0 ..< g.snap.drops {
			if m, ok := world.posed(&g.snap.bodies, {0, i32(i)}, g.fr.alpha); ok {render.draw_mesh(&g.r, g.drop_marker, vp, m, {})}
		}
		t_objdraw := time.tick_now()
		world.draw_object_lod(&g.scene, &g.r, vp, f.camera.pos, g.full_radius) // baked per-quad distant objects
		g.prof.objdraw += time.duration_milliseconds(time.tick_since(t_objdraw))
		t_grass := time.tick_now()
		if g.grass_dist > 0 {
			world.draw_grass(&g.scene, &g.r, vp, f.camera.pos, g.grass_dist)
		}
		g.prof.grass += time.duration_milliseconds(time.tick_since(t_grass))
		// Stencil portal: render the nearest in-range interior THROUGH its doorway, from a
		// virtual camera relayed into interior space. After exterior opaque geometry (so a
		// wall in front of the door hides it), before the translucent effect pass.
		if interior_active {
			relay := world.relay_view_proj(
				g.interiors.active_portal,
				f.camera.pos,
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
		world.draw_water_lod(&g.scene, &g.r, vp, f.camera.pos, g.full_radius, f.time) // baked distant water (per-quad, real heights)
		world.draw_water(&g.scene, &g.r, vp, f.camera.pos, f.time) // near animated per-cell water (bubble), over the distant
		g.prof.water += time.duration_milliseconds(time.tick_since(t_water))
		t_effects := time.tick_now()
		world.draw_effects(&g.scene, &g.r, vp, f.time) // additive FX (flowing water/fire/beams), over opaque (last)
		g.prof.effects += time.duration_milliseconds(time.tick_since(t_effects))
		world.draw_highlight(&g.scene, &g.r, vp) // inspect-mode hover highlight
	}
	draw_actor_bodies(g, f, vp)
	// Collision-hitbox wireframe (K): green outlines of EXACTLY what Jolt collides.
	if g.show_hitboxes {
		world.build_collision_debug(drawn_scene(g), &g.db)
		world.draw_collision_debug(drawn_scene(g), &g.r, vp)
	}
}
