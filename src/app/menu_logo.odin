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
// look (camera framing, FOV) is baked into menu_logo_cfg_default.

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
// `ui.menu_logo` table each frame (see menu.odin); the rest is the baked camera.
Menu_Logo_Cfg :: struct {
	enabled:   bool,    // Lua: ui.menu_logo.enabled — skip the draw entirely when false
	pos:       [2]f32,  // Lua: ui.menu_logo.pos — on-screen offset in NDC (x = right, y = up)
	scale:     f32,     // Lua: ui.menu_logo.scale — uniform size multiplier about the logo centre
	cam_dir:   [3]f32,  // eye offset direction from the logo centre (normalized internally)
	cam_dist:  f32,     // eye distance = radius × this
	fov:       f32,     // vertical FOV, degrees
}

menu_logo_cfg_default :: proc() -> Menu_Logo_Cfg {
	return Menu_Logo_Cfg {
		enabled = true,
		pos = {0, 0},
		scale = 1.0,
		cam_dir = {0, -1, 0.18},
		cam_dist = 2.0,
		fov = 52,
	}
}

// menu_logo_read_lua reads the Lua-owned `ui.menu_logo` table (the menu's 3D logo control surface)
// into cfg: `enabled` (draw or skip), `pos` ({x,y} NDC screen offset) and `scale`. Returns present=false when the screen declares no
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
