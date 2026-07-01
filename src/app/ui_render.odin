package main

// Player-UI draw translation (SDL3_gpu path). Turns the `ui` package's backend-agnostic draw
// commands into render.UI_Vertex quads, resolving the texture per command — the 1×1 white fallback
// for solid rects, the font atlas for glyphs, the image registry for art — and batching consecutive
// commands that share a texture into one draw. The GPU pipeline itself lives in render/ui_draw.odin;
// this is the app-side glue (it owns the atlas + image GPU textures). The imgui DrawList backend in
// ui_backend.odin stays only as the --uitest/dev fallback (no atlas).

import "core:log"
import "../font"
import "../formats/dds"
import "../render"
import "../ui"
import "../vfs"

// UI_Render owns the GPU font atlas + art textures and the per-frame geometry scratch buffers. It
// holds the LIVE ^font.Atlas (glyphs bake lazily at display size) and re-uploads it whenever the
// atlas reports new glyphs (`atlas.dirty`) — usually once when a screen first appears, then never.
UI_Render :: struct {
	r:         ^render.Renderer,
	atlas:     ^font.Atlas, // live, lazily-baked; (re)uploaded on dirty in ui_render_draw
	atlas_tex: render.Texture,
	vf:        ^vfs.VFS,                   // for lazy-loading `image{source=...}` DDS art via the VFS
	images:    map[string]render.Texture, // VFS path → texture, lazily loaded + cached (nil tex = failed)
	verts:     [dynamic]render.UI_Vertex,
	indices:   [dynamic]u32,
	batches:   [dynamic]render.UI_Batch,
}

// ui_render_init records the live atlas + the VFS (for art); nothing is uploaded yet. ui_render_draw
// syncs the atlas, and image textures load lazily the first time a node references them.
ui_render_init :: proc(r: ^render.Renderer, atlas: ^font.Atlas, vf: ^vfs.VFS) -> UI_Render {
	return UI_Render{r = r, atlas = atlas, vf = vf, images = make(map[string]render.Texture)}
}

// ui_image_texture resolves an `image{source=path}` to a GPU texture, loading + uploading the DDS from
// the VFS on first use (so a mod's override of that path wins) and caching the result — a failed load
// caches a nil texture so it isn't retried every frame. ok=false → the command draws nothing.
@(private = "file")
ui_image_texture :: proc(ur: ^UI_Render, path: string) -> (render.Texture, bool) {
	if path == "" {
		return {}, false
	}
	if t, seen := ur.images[path]; seen {
		return t, t.tex != nil
	}
	t := ui_load_dds(ur, path)
	ur.images[path] = t
	if t.tex == nil {
		log.warnf("ui: image %q did not load", path)
	}
	return t, t.tex != nil
}

@(private = "file")
ui_load_dds :: proc(ur: ^UI_Render, path: string) -> render.Texture {
	if ur.vf == nil {
		return {}
	}
	raw, ok := vfs.read(ur.vf, path, context.temp_allocator)
	if !ok {
		return {}
	}
	img, pok := dds.parse(raw)
	if !pok {
		return {}
	}
	rfmt: render.Tex_Format
	#partial switch img.format {
	case .BC1: rfmt = .BC1
	case .BC2: rfmt = .BC2
	case .BC3: rfmt = .BC3
	case .BC4: rfmt = .BC4
	case .BC5: rfmt = .BC5
	case .BC7: rfmt = .BC7
	case .RGBA8: rfmt = .BGRA8 if img.bgra else .RGBA8
	case: return {}
	}
	chain := dds.mip_chain(img, context.temp_allocator)
	if len(chain) == 0 {
		return {}
	}
	mips := make([]render.Tex_Mip, len(chain), context.temp_allocator)
	for mp, i in chain {
		mips[i] = {width = mp.width, height = mp.height, data = mp.data}
	}
	return render.upload_texture(ur.r, rfmt, false, mips)
}

// ui_render_sync_atlas (re)uploads the atlas bitmap as a single-mip RGBA8 texture (rgb=255, a=coverage)
// when it has baked new glyphs since the last upload. No mips: glyphs are baked at their display size,
// so the texture samples ~1:1 — the LINEAR/clamp ui sampler keeps it crisp without a (wobble-prone)
// minifying mip chain. Lazy baking means this fires only when new glyphs/sizes appear.
@(private = "file")
ui_render_sync_atlas :: proc(ur: ^UI_Render) {
	if ur.atlas == nil {
		return
	}
	if ur.atlas_tex.tex != nil && !ur.atlas.dirty {
		return
	}
	if ur.atlas_tex.tex != nil {
		render.release_texture(ur.r, ur.atlas_tex)
	}
	mip := render.Tex_Mip{width = u32(ur.atlas.w), height = u32(ur.atlas.h), data = ur.atlas.pixels}
	ur.atlas_tex = render.upload_texture(ur.r, .RGBA8, false, []render.Tex_Mip{mip})
	ur.atlas.dirty = false
}

ui_render_destroy :: proc(ur: ^UI_Render) {
	if ur.atlas_tex.tex != nil {render.release_texture(ur.r, ur.atlas_tex)}
	for _, t in ur.images {
		if t.tex != nil {render.release_texture(ur.r, t)} // nil = a cached failed load
	}
	delete(ur.images)
	delete(ur.verts)
	delete(ur.indices)
	delete(ur.batches)
}

// ui_render_register_image adds an art texture under `name` (resolved by `image{source=name}`).
ui_render_register_image :: proc(ur: ^UI_Render, name: string, tex: render.Texture) {
	ur.images[name] = tex
}

// ui_render_draw builds the frame's vertex/index/batch buffers from `cmds` and hands them to the
// renderer (drawn in end_frame). `screen` is the px space the cmds were laid out in (so the shader's
// pixel→NDC map matches). Consecutive commands sharing a texture coalesce into one batch.
ui_render_draw :: proc(ur: ^UI_Render, cmds: []ui.Draw_Cmd, screen: [2]f32) {
	ui_render_sync_atlas(ur) // upload any glyphs baked this frame before they're sampled
	clear(&ur.verts)
	clear(&ur.indices)
	clear(&ur.batches)

	have_batch := false
	cur: render.Texture
	batch_start: u32

	flush :: proc(ur: ^UI_Render, tex: render.Texture, start: u32) {
		count := u32(len(ur.indices)) - start
		if count > 0 {
			append(&ur.batches, render.UI_Batch{tex = tex, first_index = start, index_count = count})
		}
	}

	for c in cmds {
		tex, ok := ui_cmd_texture(ur, c)
		if !ok {
			continue // unresolved image / nothing to draw
		}
		// Open a new batch when the texture changes (different GPU texture handle).
		if !have_batch || tex.tex != cur.tex {
			if have_batch {
				flush(ur, cur, batch_start)
			}
			cur = tex
			have_batch = true
			batch_start = u32(len(ur.indices))
		}
		ui_push_quad(ur, c)
	}
	if have_batch {
		flush(ur, cur, batch_start)
	}
	render.set_ui_drawlist(ur.r, ur.verts[:], ur.indices[:], ur.batches[:], screen)
}

// ui_cmd_texture resolves the texture a command samples (and whether it draws at all).
@(private = "file")
ui_cmd_texture :: proc(ur: ^UI_Render, c: ui.Draw_Cmd) -> (render.Texture, bool) {
	#partial switch c.kind {
	case .Glyph:
		return ur.atlas_tex, true
	case .Image:
		return ui_image_texture(ur, c.image) // lazily load the DDS from the VFS; draws nothing on miss
	case .Rect:
		return render.white_texture(ur.r), true
	}
	return {}, false // .Text is the legacy imgui backend's concern
}

// ui_push_quad appends one command's two-triangle quad (4 verts + 6 indices) to the scratch buffers.
@(private = "file")
ui_push_quad :: proc(ur: ^UI_Render, c: ui.Draw_Cmd) {
	col := pack_rgba(c.color)
	u0, v0, u1, v1: f32 = 0, 0, 1, 1
	if c.kind == .Glyph {
		u0 = c.uv.x
		v0 = c.uv.y
		u1 = c.uv.x + c.uv.w
		v1 = c.uv.y + c.uv.h
	}
	r := c.rect
	base := u32(len(ur.verts))
	append(&ur.verts, render.UI_Vertex{pos = {r.x, r.y}, uv = {u0, v0}, col = col})
	append(&ur.verts, render.UI_Vertex{pos = {r.x + r.w, r.y}, uv = {u1, v0}, col = col})
	append(&ur.verts, render.UI_Vertex{pos = {r.x + r.w, r.y + r.h}, uv = {u1, v1}, col = col})
	append(&ur.verts, render.UI_Vertex{pos = {r.x, r.y + r.h}, uv = {u0, v1}, col = col})
	append(&ur.indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

@(private = "file")
pack_rgba :: proc(c: ui.Color) -> [4]u8 {
	return {
		u8(clamp(c[0], 0, 1) * 255 + 0.5),
		u8(clamp(c[1], 0, 1) * 255 + 0.5),
		u8(clamp(c[2], 0, 1) * 255 + 0.5),
		u8(clamp(c[3], 0, 1) * 255 + 0.5),
	}
}
