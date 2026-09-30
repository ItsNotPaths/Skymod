package main

// --uiassetview: a browser for the extracted UI assets. Reads every DDS already under
// content/baseui/bethassets (written by the installer, converters/ui.odin) and shows them
// one at a time, centered on a neutral panel, with the asset's name/index/size. LEFT/RIGHT arrows cycle
// (hold to scrub), Esc quits. Invaluable for asset archaeology — finding which shape_<id> is which
// (the loading-bar track, the H/M/S meter end-cap, a glyph, …) when reimplementing menus + the HUD.
//
// NOT gated behind DEVTOOLS: it's a keeper utility (unlike the throwaway --*test harnesses), and it reads
// the SHIPPED content/ next to the executable — so it works in the release binary the user actually runs.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"
import imgui "../../vendor/odin-imgui"
import "../formats/dds"
import "../platform"
import "../render"
import "../settings"

// LEFT/RIGHT arrow edges, drained by the loop (set in the event hook — arrows aren't in platform.Input).
@(private = "file")
g_assetview_nav: int

@(private = "file")
assetview_hook :: proc(ev: ^sdl.Event) {
	render.ui_process_event(ev) // keep imgui fed
	#partial switch ev.type {
	case .KEY_DOWN:
		#partial switch ev.key.scancode {
		case .LEFT:
			g_assetview_nav = -1
		case .RIGHT:
			g_assetview_nav = 1
		}
	}
}

// run_ui_asset_view browses content/baseui/bethassets. Doesn't need source_game (reads the already-
// extracted DDS straight off disk), so it boots the window/renderer directly rather than via dev_boot.
run_ui_asset_view :: proc(cfg: ^settings.Config) {
	p, ok := platform.init("SkyMod — UI asset viewer", WINDOW_W, WINDOW_H)
	if !ok {
		return
	}
	defer platform.shutdown(&p)
	r, rok := render.init(p.window)
	if !rok {
		log.error("render init failed; exiting")
		return
	}
	defer render.shutdown(&r)
	render.ui_init(&r)
	defer render.ui_shutdown(&r) // before render.shutdown — device still alive

	base := platform.base_path()
	root := baseui_assets_dir(base, context.allocator)
	defer delete(root)
	assets := collect_assets(root)
	defer {
		for a in assets {delete(a.path);delete(a.name)}
		delete(assets)
	}
	if len(assets) == 0 {
		log.warnf("uiassetview: no DDS under %s (run the game once to extract them)", root)
		return
	}
	log.infof("uiassetview: %d assets under bethassets — left/right to cycle, Esc to quit", len(assets))

	p.on_event = assetview_hook
	idx := 0
	loaded := -1
	tex: render.Texture
	tw, th: int
	defer if tex.tex != nil {render.release_texture(&r, tex)}

	verts: [dynamic]render.UI_Vertex;defer delete(verts)
	indices: [dynamic]u32;defer delete(indices)
	batches: [dynamic]render.UI_Batch;defer delete(batches)

	for platform.pump(&p) {
		if g_assetview_nav != 0 {
			idx = (idx + g_assetview_nav + len(assets)) %% len(assets)
			g_assetview_nav = 0
		}
		if loaded != idx {
			if tex.tex != nil {render.release_texture(&r, tex)}
			tex, tw, th = load_dds_texture(&r, assets[idx].path)
			loaded = idx
		}

		render.ui_new_frame(&r)
		w, h := ui_screen_size()

		// Info panel (name / index / native size + controls).
		imgui.SetNextWindowPos({12, 12}, .Always)
		if imgui.Begin("uiassetview", nil, {.NoResize, .NoMove, .NoCollapse, .AlwaysAutoResize}) {
			imgui.TextUnformatted(strings.clone_to_cstring(assets[idx].name, context.temp_allocator))
			imgui.TextUnformatted(fmt.ctprintf("%d / %d    %d x %d", idx + 1, len(assets), tw, th))
			imgui.TextDisabledUnformatted("<-/-> cycle (hold to scrub) - Esc quit")
		}
		imgui.End()

		// Draw the sprite centered on a neutral panel (so both light and dark art read).
		clear(&verts);clear(&indices);clear(&batches)
		if tex.tex != nil && tw > 0 && th > 0 {
			fit := min(w * 0.72 / f32(tw), h * 0.72 / f32(th))
			scale := clamp(fit, 0.5, 12)
			qw, qh := f32(tw) * scale, f32(th) * scale
			x, y := (w - qw) / 2, (h - qh) / 2
			pad := f32(24)
			push_quad(&verts, &indices, x - pad, y - pad, qw + 2 * pad, qh + 2 * pad, {90, 90, 96, 255})
			batch_end(&batches, &indices, render.white_texture(&r))
			push_quad(&verts, &indices, x, y, qw, qh, {255, 255, 255, 255})
			batch_end(&batches, &indices, tex)
		}
		render.set_ui_drawlist(&r, verts[:], indices[:], batches[:], {w, h})

		if render.begin_frame(&r, {0.10, 0.10, 0.12, 1}) {
			render.end_frame(&r)
		}
		free_all(context.temp_allocator)
	}
}

// Asset_Entry is one browsable DDS: its full disk path + a bethassets-relative display name.
@(private = "file")
Asset_Entry :: struct {
	path: string,
	name: string,
}

// collect_assets walks `root` recursively for *.dds, returning them sorted by display name.
@(private = "file")
collect_assets :: proc(root: string) -> [dynamic]Asset_Entry {
	out := make([dynamic]Asset_Entry)
	walk_dds(root, root, &out)
	slice.sort_by(out[:], proc(a, b: Asset_Entry) -> bool {return a.name < b.name})
	return out
}

@(private = "file")
walk_dds :: proc(root, dir: string, out: ^[dynamic]Asset_Entry) {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in infos {
		if os.is_dir(fi.fullpath) {
			walk_dds(root, fi.fullpath, out)
			continue
		}
		if !strings.has_suffix(strings.to_lower(fi.name, context.temp_allocator), ".dds") {
			continue
		}
		rel, rerr := filepath.rel(root, fi.fullpath, context.temp_allocator)
		name := rel if rerr == nil else fi.name
		append(out, Asset_Entry{path = strings.clone(fi.fullpath), name = strings.clone(name)})
	}
}

// load_dds_texture reads + uploads a DDS file straight off disk (no VFS). Returns a zero Texture on
// failure. Mirrors ui_render's loader.
@(private = "file")
load_dds_texture :: proc(r: ^render.Renderer, path: string) -> (render.Texture, int, int) {
	raw, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return {}, 0, 0
	}
	img, pok := dds.parse(raw)
	if !pok {
		return {}, 0, 0
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
	case:
		return {}, 0, 0
	}
	chain := dds.mip_chain(img, context.temp_allocator)
	if len(chain) == 0 {
		return {}, 0, 0
	}
	mips := make([]render.Tex_Mip, len(chain), context.temp_allocator)
	for mp, i in chain {
		mips[i] = {width = mp.width, height = mp.height, data = mp.data}
	}
	return render.upload_texture(r, rfmt, false, mips), int(img.width), int(img.height)
}

// push_quad appends a screen-space quad (4 verts + 6 indices, uv 0..1) in colour `col`.
@(private = "file")
push_quad :: proc(verts: ^[dynamic]render.UI_Vertex, indices: ^[dynamic]u32, x, y, w, h: f32, col: [4]u8) {
	base := u32(len(verts))
	append(verts, render.UI_Vertex{pos = {x, y}, uv = {0, 0}, col = col})
	append(verts, render.UI_Vertex{pos = {x + w, y}, uv = {1, 0}, col = col})
	append(verts, render.UI_Vertex{pos = {x + w, y + h}, uv = {1, 1}, col = col})
	append(verts, render.UI_Vertex{pos = {x, y + h}, uv = {0, 1}, col = col})
	append(indices, base, base + 1, base + 2, base, base + 2, base + 3)
}

// batch_end closes a batch covering the indices appended since the last batch, bound to `tex`.
@(private = "file")
batch_end :: proc(batches: ^[dynamic]render.UI_Batch, indices: ^[dynamic]u32, tex: render.Texture) {
	start := u32(0)
	for b in batches {start += b.index_count}
	append(batches, render.UI_Batch{tex = tex, first_index = start, index_count = u32(len(indices)) - start})
}
