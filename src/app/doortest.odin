package main

// Door test sandbox (open-interiors door integration). Run with `--doortest`. Loads a single
// load-door NIF (FarmhouseLDoor01), renders its shapes, and lets you swing the "Door" hinge
// subtree open about a chosen axis with a live angle slider — the place to dial in "opens
// fully and reasonable" before parsing the authored animation drives it. Highlights which
// shape is the "DoorBlack" aperture (the future stencil surface). Throwaway harness; no
// streaming/gamedb — mounts the meshes/textures archives directly (needs source_game).

import "core:log"
import "core:math"

import "../assetdb"
import "../formats/nif"
import smath "../math"
import "../platform"
import "../render"
import "../settings"
import "../tools"
import "../vfs"

when DEVTOOLS {
	DOORTEST_NIF :: "architecture\\farmhouse\\FarmhouseLDoor01.nif"
	DOORTEST_LIGHT :: smath.Vec3{0.4, 0.6, 1.0}

	// Door_Shape is one uploaded door sub-mesh + whether it swings (under the "Door" hinge node)
	// and whether it's the "DoorBlack" aperture (drawn highlighted).
	Door_Shape :: struct {
		mesh:        render.Mesh,
		tex:         render.Texture,
		local:       smath.Mat4, // NIF-internal world placement
		under_hinge: bool,
		is_black:    bool,
	}

	// run_door_test loads one door and shows it with a free-fly camera + an open-angle slider.
	run_door_test :: proc(cfg: ^settings.Config) {
		d: Dev_Boot
		defer dev_shutdown(&d)
		if !dev_boot(&d, "SkyMod — Door test", cfg, "--doortest") {
			return
		}
		p, r, v := &d.p, &d.r, &d.v

		cache := assetdb.cache_init(r, v) // for diffuse textures (get_texture)
		defer assetdb.cache_destroy(&cache)

		// Parse the door NIF directly (parse_scene tags under_hinge + shape names, which get_model
		// drops). Keep the header+bytes alive long enough to also resolve the hinge/aperture frames.
		full := "meshes\\" + DOORTEST_NIF
		data, dok := vfs.read(v, full, context.temp_allocator)
		if !dok {
			log.errorf("--doortest: could not read %s", full)
			return
		}
		h, hok := nif.parse_header(data, context.temp_allocator)
		if !hok {
			log.errorf("--doortest: header parse failed for %s", full)
			return
		}
		placed := nif.parse_scene(data, &h, context.temp_allocator)

		// Hinge frame = the "Door" node's world transform (pivot + local axes). The aperture frame
		// is "DoorBlack" (informational for now; Phase 3 uses it as the stencil quad).
		hinge, hinge_ok := nif.node_world_by_name(data, &h, nif.HINGE_NODE)
		_, black_ok := nif.node_world_by_name(data, &h, "DoorBlack")

		shapes: [dynamic]Door_Shape
		defer {
			for s in shapes {render.release_mesh(r, s.mesh)}
			delete(shapes)
		}
		for ps in placed {
			verts := make([]render.Mesh_Vertex, len(ps.geometry.vertices), context.temp_allocator)
			for i in 0 ..< len(ps.geometry.vertices) {
				n: [3]f32 = ps.geometry.normals[i] if i < len(ps.geometry.normals) else {0, 0, 1}
				uv: [2]f32 = ps.geometry.uvs[i] if i < len(ps.geometry.uvs) else {0, 0}
				verts[i] = render.mesh_vertex(ps.geometry.vertices[i], n, uv)
			}
			tex: render.Texture
			if ps.diffuse != "" {
				tex, _ = assetdb.get_texture(&cache, ps.diffuse)
			}
			append(
				&shapes,
				Door_Shape {
					mesh = render.upload_mesh(r, verts, ps.geometry.triangles),
					tex = tex,
					local = ps.world,
					under_hinge = ps.under_hinge,
					is_black = ps.name == "DoorBlack",
				},
			)
			log.infof(
				"--doortest: shape %q  under_hinge=%v  black=%v  tex=%q",
				ps.name,
				ps.under_hinge,
				ps.name == "DoorBlack",
				ps.diffuse,
			)
		}
		log.infof("--doortest: hinge(\"Door\")=%v  DoorBlack=%v  %d shapes", hinge_ok, black_ok, len(shapes))

		// Hinge pivot + the three candidate hinge axes (the Door node's local X/Y/Z in world).
		pivot := smath.Vec3{hinge[0, 3], hinge[1, 3], hinge[2, 3]}
		axes := [3]smath.Vec3 {
			{hinge[0, 0], hinge[1, 0], hinge[2, 0]},
			{hinge[0, 1], hinge[1, 1], hinge[2, 1]},
			{hinge[0, 2], hinge[1, 2], hinge[2, 2]},
		}

		open_deg: f32 = 90
		axis_idx: i32 = 2 // default: the Door node's local Z (vertical), the usual hinge
		highlight_black := true

		cam := Camera{pos = {120, -180, 70}, yaw = math.PI * 0.4, pitch = -0.15}
		log.info("--doortest: RMB look, WASD/QE fly. Slider swings the door. Esc to quit.")

		for platform.pump(p) {
			render.ui_new_frame(r)
			tools.door_test_panel(&open_deg, &axis_idx, &highlight_black, hinge_ok, black_ok)

			mouse_cap, kb_cap := render.ui_capturing(r)
			move, look := p.input.move, p.input.look
			if kb_cap {move = {}}
			if mouse_cap {look = {}}
			camera_update(&cam, move, look, p.input.fast, p.dt)

			// Hinge swing: rotate the door subtree about the chosen hinge axis through the pivot.
			ang := open_deg * math.PI / 180
			swing :=
				smath.translate(pivot) *
				smath.rotate_axis(axes[axis_idx], ang) *
				smath.translate(pivot * -1)

			if render.begin_frame(r, {0.10, 0.11, 0.13, 1.0}) {
				vp := camera_view_proj(cam, render.aspect(r))
				for s in shapes {
					world := s.local
					if s.under_hinge {
						world = swing * world
					}
					// (The old per-draw "unlit black aperture" cue is gone — lighting is now a
					// per-frame UBO, not a per-draw arg. Throwaway harness; default lit.)
					_ = highlight_black
					render.draw_mesh(r, s.mesh, vp, world, s.tex)
				}
				render.end_frame(r)
			}
			free_all(context.temp_allocator)
		}
	}
} // when DEVTOOLS
