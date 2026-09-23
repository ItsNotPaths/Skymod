package main

// The main-menu 3D logo: Skyrim's menu logo is a real mesh (meshes/interface/logo/logo.nif +
// textures/interface/objects/logo02*), so we render it as a mesh behind the 2D UI rather than
// flattening it — read straight from the user's install via the VFS (no extraction). Mirrors the
// doortest harness: parse the NIF → upload each shape → draw with a camera framing its bounds, inside
// the menu's scene pass (the UI composites on top in end_frame).
//
// MODDABLE: the menu Lua owns whether/where the logo draws via the `ui.menu_logo` table (enabled +
// on-screen position + scale) — read each frame in menu.odin and folded into Menu_Logo_Cfg. A mod
// overriding main_menu.lua can disable or reposition it without touching the engine. The remaining
// look (camera framing, FOV, flat fullbright light) is baked into menu_logo_cfg_default.

import "core:math"

import lua "../../vendor/lua"

import "../assetdb"
import "../formats/nif"
import smath "../math"
import "../render"
import "../ui"
import "../vfs"

LOGO_NIF :: "meshes\\interface\\logo\\logo.nif"

// Menu_Logo_Cfg is the logo's draw config. enabled/pos/scale are LIVE — overwritten from the Lua
// `ui.menu_logo` table each frame (see menu.odin); the rest is the baked camera + light look.
Menu_Logo_Cfg :: struct {
	enabled:   bool,    // Lua: ui.menu_logo.enabled — skip the draw entirely when false
	pos:       [2]f32,  // Lua: ui.menu_logo.pos — on-screen offset in NDC (x = right, y = up)
	scale:     f32,     // Lua: ui.menu_logo.scale — uniform size multiplier about the logo centre
	lift:      f32,     // Lua: ui.menu_logo.lift — albedo gamma (pow); <1 FLATTENS the dark stone's
	                    //   range toward an even tone (1 = off). The "flat shade" knob.
	cam_dir:   [3]f32,  // eye offset direction from the logo centre (normalized internally)
	cam_dist:  f32,     // eye distance = radius × this
	fov:       f32,     // vertical FOV, degrees
	light_dir: [3]f32,  // direction toward the (now zero-intensity) sun — kept for shape, unused while flat
	ambient:   f32,     // flat fullbright level (no directional term — see menu_logo_light)
}

menu_logo_cfg_default :: proc() -> Menu_Logo_Cfg {
	return Menu_Logo_Cfg {
		enabled = true,
		pos = {0, 0},
		scale = 1.0,
		lift = 1.0, // gamma OFF → true fullbright (out = albedo × ambient), no lighting
		cam_dir = {0, -1, 0.18},
		cam_dist = 2.0,
		fov = 52,
		light_dir = {0.2, -1, 0.5},
		ambient = 8.0,
	}
}

// menu_logo_read_lua reads the Lua-owned `ui.menu_logo` table (the menu's 3D logo control surface)
// into cfg: `enabled` (draw or skip), `pos` ({x,y} NDC screen offset), `scale`, `bright` (flat-
// fullbright ambient → cfg.ambient), and `lift`. Returns present=false when the screen declares no
// table (mod with no logo concept) — the caller keeps its baked Menu_Logo_Cfg defaults. Each field
// is optional; absent fields leave the current value.
menu_logo_read_lua :: proc(vm: ^ui.VM, cfg: ^Menu_Logo_Cfg) -> (present: bool) {
	L := vm.L
	lua.getglobal(L, "ui") // [ui]
	defer lua.settop(L, -2) // pop ui
	if lua.type(L, -1) != .TABLE {
		return false
	}
	lua.getfield(L, -1, "menu_logo") // [ui, menu_logo]
	defer lua.settop(L, -2) // pop menu_logo
	if lua.type(L, -1) != .TABLE {
		return false
	}
	lua.getfield(L, -1, "enabled")
	if t := lua.type(L, -1); t != .NIL && t != .NONE {
		cfg.enabled = bool(lua.toboolean(L, -1))
	}
	lua.settop(L, -2)
	ui.read_num_field(L, "scale", &cfg.scale)
	ui.read_num_field(L, "bright", &cfg.ambient)
	ui.read_num_field(L, "lift", &cfg.lift)
	lua.getfield(L, -1, "pos") // pos = {x, y}
	if lua.type(L, -1) == .TABLE {
		ui.read_num_index(L, 0, &cfg.pos[0])
		ui.read_num_index(L, 1, &cfg.pos[1])
	}
	lua.settop(L, -2)
	return true
}

Menu_Logo :: struct {
	shapes: [dynamic]Logo_Shape,
	cache:  assetdb.Cache,
	center: smath.Vec3,
	radius: f32,
}

Logo_Shape :: struct {
	mesh:         render.Mesh,
	tex:          render.Texture,
	world:        smath.Mat4,
	alpha_cutoff: f32,
}

menu_logo_load :: proc(r: ^render.Renderer, v: ^vfs.VFS) -> (logo: Menu_Logo, ok: bool) {
	data, dok := vfs.read(v, LOGO_NIF, context.temp_allocator)
	if !dok {
		return {}, false
	}
	h, hok := nif.parse_header(data, context.temp_allocator)
	if !hok {
		return {}, false
	}
	placed := nif.parse_scene(data, &h, context.temp_allocator)
	if len(placed) == 0 {
		return {}, false
	}
	logo.cache = assetdb.cache_init(r, v)

	lo := smath.Vec3{1e30, 1e30, 1e30}
	hi := smath.Vec3{-1e30, -1e30, -1e30}
	for ps in placed {
		verts := make([]render.Mesh_Vertex, len(ps.geometry.vertices), context.temp_allocator)
		for i in 0 ..< len(ps.geometry.vertices) {
			vtx := ps.geometry.vertices[i]
			n: [3]f32 = ps.geometry.normals[i] if i < len(ps.geometry.normals) else {0, 0, 1}
			uv: [2]f32 = ps.geometry.uvs[i] if i < len(ps.geometry.uvs) else {0, 0}
			verts[i] = render.mesh_vertex(vtx, n, uv)
			wp := ps.world * [4]f32{vtx[0], vtx[1], vtx[2], 1}
			lo = {min(lo[0], wp[0]), min(lo[1], wp[1]), min(lo[2], wp[2])}
			hi = {max(hi[0], wp[0]), max(hi[1], wp[1]), max(hi[2], wp[2])}
		}
		tex: render.Texture
		if ps.diffuse != "" {
			tex, _ = assetdb.get_texture(&logo.cache, ps.diffuse)
		}
		append(&logo.shapes, Logo_Shape{mesh = render.upload_mesh(r, verts, ps.geometry.triangles), tex = tex, world = ps.world, alpha_cutoff = ps.alpha_cutoff})
	}
	logo.center = (lo + hi) * 0.5
	dd := hi - lo
	logo.radius = math.sqrt(dd[0] * dd[0] + dd[1] * dd[1] + dd[2] * dd[2]) * 0.5
	if logo.radius <= 0 {
		logo.radius = 1
	}
	return logo, len(logo.shapes) > 0
}

menu_logo_destroy :: proc(r: ^render.Renderer, logo: ^Menu_Logo) {
	for s in logo.shapes {
		render.release_mesh(r, s.mesh)
	}
	delete(logo.shapes)
	assetdb.cache_destroy(&logo.cache)
}

// menu_logo_light builds the scene light env for a TRUE FULLBRIGHT, UNLIT logo. The mesh.frag reduces
// to `out = albedo × amb` when: sun intensity (sun_color.w) = 0 (no directional term / specular), the
// per-shape material is default (menu_logo_draw passes none → spec/emissive 0), and the ambient is
// forced UNIFORM regardless of normal — ambient_sky.rgb == ambient_ground.rgb == a, intensity
// (ground.w) = 1, floor (sky.w) = a. So every texel is just its own colour × a: no lighting, no
// normal/view dependence, no shine. `a` (cfg.ambient) is the fullbright multiplier — the diffuse is
// dark carved stone, so it needs ~8×. sun_dir.w = cfg.lift is an OPTIONAL albedo gamma (1 = off / raw
// texture); values <1 flatten the range but read metallic on this stone, so it's left at 1. Set
// BEFORE begin_frame (scene_begin pushes it).
menu_logo_light :: proc(d: ^Menu_Logo_Cfg) -> render.Light_Env {
	a := d.ambient
	return render.Light_Env {
		sun_dir = {d.light_dir[0], d.light_dir[1], d.light_dir[2], d.lift},
		sun_color = {1.0, 0.97, 0.92, 0.0}, // w = intensity 0 → no directional contribution (fullbright)
		ambient_sky = {a, a, a, a}, // sky.w = floor = a → amb clamps to a everywhere (uniform, normal-independent)
		ambient_ground = {a, a, a, 1.0},
		fog_color = {0, 0, 0, 0},
		fog_params = {0, 1.0e9, 0, 0},
		material = {1.5, 1, 0.3, 1},
	}
}

// menu_logo_post is the menu scene's tonemap: NONE (mode 3, passthrough = exposure + clamp, no
// compressive curve). The default Reinhard curve rolls highlights off toward the white point, which
// caps how bright the logo can get no matter how high the ambient — a flat tonemap lets the
// fullbright ambient scale the logo linearly (clamped at white). Set BEFORE begin_frame. Only the 3D
// scene is tonemapped; the UI composites on top afterward, so the menu text is unaffected.
menu_logo_post :: proc() -> render.Post_Params {
	return render.Post_Params {
		params = {1, 3, 1, 1}, // exposure 1, tonemap NONE, white 1, contrast 1
		grade = {1, 1, 1, 1},
	}
}

// menu_logo_draw renders the logo shapes inside the open scene pass (between begin_frame/end_frame).
// cfg.pos shifts the logo on screen via an NDC clip-space translation (T · proj · view): a constant
// screen-space offset independent of depth, so Lua positions it in plain screen fractions. cfg.scale
// resizes it about the logo centre.
menu_logo_draw :: proc(r: ^render.Renderer, logo: ^Menu_Logo, d: ^Menu_Logo_Cfg) {
	if !d.enabled {
		return
	}
	dir := smath.normalize3(d.cam_dir)
	dist := logo.radius * d.cam_dist
	eye := logo.center + dir * dist
	view := smath.look_at_rh(eye, logo.center, {0, 0, 1})
	near := max(dist * 0.02, 0.05)
	proj := smath.perspective_rh_zo_rev(d.fov * math.PI / 180, render.aspect(r), near, dist + logo.radius * 4) // reversed-Z (shares the scene depth pass)
	// Clip-space (NDC) screen offset: translate adds (pos.x·w, pos.y·w) to clip xy, so after the
	// perspective divide the logo shifts by (pos.x, pos.y) in NDC at every depth.
	vp := smath.translate({d.pos[0], d.pos[1], 0}) * proj * view

	extra :=
		smath.translate(logo.center) *
		smath.scale_uniform(d.scale) *
		smath.translate(logo.center * -1)

	for s in logo.shapes {
		render.draw_mesh(r, s.mesh, vp, extra * s.world, s.tex, s.alpha_cutoff)
	}
}
