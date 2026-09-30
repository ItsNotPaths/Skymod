package converters

// SWF/GFX -> DDS, once, at install: the UI art of UI_ASSETS, the layout file of each SWF with
// instances, a bank of every shape and bitmap of BANK_SOURCES, and the reticle. The output is
// <content>/baseui/bethassets, a content mod; Lua screens read it through the VFS.

import "core:fmt"
import "core:hash"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../../formats/dds"
import "../../formats/swf"
import "../../ui"
import "../../vfs"

UI_Stats :: struct {
	written: int, // DDS files
	missing: int, // UI_ASSETS entries not found
	unlinked: int, // bank files with no id in UI_LINKS for this game version
}

// UI_LINKS names bank art across game versions: one id column per exe product version, the
// first column the name every version writes (generated: tools/uilink.py).
UI_LINKS :: #load("ui_links.tsv", string)

// BANK_SOURCES are the SWFs the bank dumps, each to bethassets/<name>/.
BANK_SOURCES := [?][2]string {
	{"interface/startmenu.swf", "startmenu"},
	{"interface/creditsmenu.swf", "creditsmenu"},
	{"interface/loadingmenu.swf", "loadingmenu"},
	{HUD_SWF, "hudmenu"},
}

// ui_hash identifies UI_ASSETS and UI_LINKS, so an install made with others runs again.
ui_hash :: proc() -> u64 {
	h := hash.fnv64a(transmute([]u8)fmt.tprint(UI_ASSETS))
	return hash.fnv64a(transmute([]u8)string(UI_LINKS), h)
}

// convert_ui reads the SWFs from `data` and `archives` (mount order, a later copy wins) and
// writes `out_dir` new. `version` is the exe product version ("1.9.32.0") that picks the
// UI_LINKS column.
convert_ui :: proc(data: string, archives: []string, version, out_dir: string, progress: ^Progress = nil) -> (st: UI_Stats, ok: bool) {
	os.remove_all(out_dir)
	os.make_directory_all(out_dir)
	if !os.is_dir(out_dir) {
		log.errorf("ui: could not create %q", out_dir)
		return st, false
	}
	v: vfs.VFS
	defer vfs.destroy(&v)
	vfs.mount_loose(&v, data)
	for a in archives {
		if !vfs.mount_archive(&v, a) {log.warnf("ui: skipping unreadable archive %q", a)}
	}

	progress_step(progress, "Extracting UI art", len(UI_ASSETS) + len(BANK_SOURCES))
	laid_out := make(map[string]bool, allocator = context.temp_allocator)
	for a in UI_ASSETS {
		progress_note(progress, a.dest)
		defer progress_done(progress)
		dest, _ := filepath.join({out_dir, a.dest}, context.temp_allocator)
		switch {
		case a.name != "":
			extract_bitmap(&v, a, dest, &st)
		case a.path != "" && !laid_out[a.swf]:
			write_layout(&v, out_dir, a.swf, &st) // with every instance of that SWF
			laid_out[a.swf] = true
		case a.path != "": // written with its SWF above
		case:
			extract_shape_by_look(&v, a, dest, &st)
		}
	}
	links := read_links(version)
	if len(links) == 0 {log.warnf("ui: no link column for game version %s; bank files keep their own ids", version)}
	for s in BANK_SOURCES {
		progress_note(progress, s[1])
		defer progress_done(progress)
		dump_bank(&v, out_dir, s[0], s[1], links, &st)
	}
	reticle, _ := filepath.join({out_dir, "interface", "reticle.dds"}, context.temp_allocator)
	make_reticle(reticle, &st)
	return st, true
}

// Link_Key is one bank file as this game version names it.
@(private = "file")
Link_Key :: struct {
	source, kind: string,
	id:           int,
}

// read_links maps this version's bank ids to the first column's. Empty when no column is `version`.
@(private = "file")
read_links :: proc(version: string) -> map[Link_Key]int {
	links := make(map[Link_Key]int, allocator = context.temp_allocator)
	lines := strings.split_lines(strings.trim_space(UI_LINKS), context.temp_allocator)
	header := strings.split(lines[0], "\t", context.temp_allocator)
	col := -1
	for h, i in header {
		if h == version {col = i}
	}
	if col < 0 {return links}
	for line in lines[1:] {
		f := strings.split(line, "\t", context.temp_allocator)
		id, _ := strconv.parse_int(f[col])
		to, _ := strconv.parse_int(f[2])
		if id != 0 {links[{f[0], f[1], id}] = to}
	}
	return links
}

// bank_name is <kind>_<first column id>.dds, or <kind>_x<own id>.dds for a file with no link,
// so it cannot take a linked name.
@(private = "file")
bank_name :: proc(links: map[Link_Key]int, source, kind: string, id: int, st: ^UI_Stats) -> string {
	if to, ok := links[{source, kind, id}]; ok {
		return fmt.tprintf("%s_%d.dds", kind, to)
	}
	st.unlinked += 1
	return fmt.tprintf("%s_x%d.dds", kind, id)
}

// dump_bank writes every shape (its silhouette in its fill colour) and every lossless bitmap of
// `swf_path` to bethassets/<name>/, so a screen can use one without a new install.
@(private = "file")
dump_bank :: proc(v: ^vfs.VFS, out_dir, swf_path, name: string, links: map[Link_Key]int, st: ^UI_Stats) {
	raw, ok := vfs.read(v, swf_path, context.temp_allocator)
	if !ok {
		log.warnf("ui: no %s", swf_path)
		return
	}
	mv, mok := swf.parse_movie(raw, context.temp_allocator)
	if !mok {
		return
	}
	dir, _ := filepath.join({out_dir, name}, context.temp_allocator)
	for id, c in mv.chars {
		_ = c.(swf.Shape_Def) or_continue
		img := swf.render_shape_image(&mv, id, 1, context.temp_allocator) or_continue
		dest, _ := filepath.join({dir, bank_name(links, name, "shape", int(id), st)}, context.temp_allocator)
		write_dds(dest, img.rgba, img.w, img.h, st)
	}
	for bm in swf.extract_all_bitmaps(raw, context.temp_allocator) {
		dest, _ := filepath.join({dir, bank_name(links, name, "bitmap", int(bm.id), st)}, context.temp_allocator)
		write_dds(dest, bm.bmp.rgba, bm.bmp.w, bm.bmp.h, st)
	}
}

// make_reticle writes a small white antialiased dot, white so hud.lua can tint it.
@(private = "file")
make_reticle :: proc(dest: string, st: ^UI_Stats) {
	N :: 32 // texture side
	R :: f32(6) // dot radius in texels
	AA :: f32(1.5) // texels the alpha ramps across at the rim
	rgba := make([]u8, N * N * 4, context.temp_allocator)
	c := f32(N - 1) * 0.5
	for y in 0 ..< N {
		for x in 0 ..< N {
			dx, dy := f32(x) - c, f32(y) - c
			a := clamp((R - math.sqrt(dx * dx + dy * dy)) / AA + 0.5, 0, 1)
			i := (y * N + x) * 4
			rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3] = 255, 255, 255, u8(a * 255)
		}
	}
	write_dds(dest, rgba, N, N, st)
}

// extract_shape_by_look draws the shape of `a.swf` whose first solid fill and native px size match `a`.
@(private = "file")
extract_shape_by_look :: proc(v: ^vfs.VFS, a: UI_Asset, dest: string, st: ^UI_Stats) {
	mv, ok := read_movie(v, a.swf)
	if !ok {
		st.missing += 1
		return
	}
	for id, c in mv.chars {
		sh := c.(swf.Shape_Def) or_continue
		if swf.shape_color(sh) != a.fill {
			continue
		}
		img := swf.render_shape_image(&mv, id, 1, context.temp_allocator) or_continue
		if img.w != a.size.x || img.h != a.size.y {
			continue
		}
		if a.recolor[3] != 0 {
			for i := 0; i < len(img.rgba); i += 4 {
				img.rgba[i], img.rgba[i + 1], img.rgba[i + 2] = a.recolor[0], a.recolor[1], a.recolor[2]
			}
		}
		write_dds(dest, img.rgba, img.w, img.h, st)
		return
	}
	log.warnf("ui: no %dx%d shape with fill %v in %s", a.size.x, a.size.y, a.fill, a.swf)
	st.missing += 1
}

// extract_bitmap writes the bitmap `a.swf` exports as `a.name`.
@(private = "file")
extract_bitmap :: proc(v: ^vfs.VFS, a: UI_Asset, dest: string, st: ^UI_Stats) {
	raw, ok := vfs.read(v, a.swf, context.temp_allocator)
	bmp: swf.Bitmap
	if ok {bmp, ok = swf.extract_bitmap(raw, a.name, context.temp_allocator)}
	if !ok {
		log.warnf("ui: could not extract %q from %s", a.name, a.swf)
		st.missing += 1
		return
	}
	write_dds(dest, bmp.rgba, bmp.w, bmp.h, st)
}

// write_layout draws every INSTANCE row of `swf_path` and writes interface/<name>_layout.lua: the
// stage size, each art file's stage rect, and every named instance's rect (with its animated box per
// frame label).
@(private = "file")
write_layout :: proc(v: ^vfs.VFS, out_dir, swf_path: string, st: ^UI_Stats) {
	mv, ok := read_movie(v, swf_path)
	if !ok {
		st.missing += 1
		return
	}
	art := make([dynamic]ui.Art_Rect, context.temp_allocator)
	for a in UI_ASSETS {
		if a.swf != swf_path || a.path == "" {
			continue
		}
		img, rok := swf.render_instance(&mv, a.path, a.label, ART_SCALE, a.hide, a.still, context.temp_allocator)
		if !rok {
			log.warnf("ui: no instance %q in %s", a.path, swf_path)
			st.missing += 1
			continue
		}
		dest, _ := filepath.join({out_dir, a.dest}, context.temp_allocator)
		write_dds(dest, img.rgba, img.w, img.h, st)
		append(&art, ui.Art_Rect{a.dest, img.rect})
	}
	src := ui.layout_source(&mv, swf_path, art[:], context.temp_allocator)
	out, _ := filepath.join({out_dir, "interface", fmt.tprintf("%s_layout.lua", filepath.stem(swf_path))}, context.temp_allocator)
	write_file(out, transmute([]u8)src)
}

@(private = "file")
read_movie :: proc(v: ^vfs.VFS, swf_path: string) -> (swf.Movie, bool) {
	raw, ok := vfs.read(v, swf_path, context.temp_allocator)
	if !ok {
		log.warnf("ui: no %s", swf_path)
		return {}, false
	}
	return swf.parse_movie(raw, context.temp_allocator)
}

@(private = "file")
write_dds :: proc(dest: string, rgba: []u8, w, h: int, st: ^UI_Stats) {
	if write_file(dest, dds.write_rgba(rgba, u32(w), u32(h), context.temp_allocator)) {st.written += 1}
}

@(private = "file")
write_file :: proc(dest: string, data: []u8) -> bool {
	os.make_directory_all(filepath.dir(dest))
	if os.write_entire_file(dest, data) != nil {
		log.errorf("ui: could not write %q", dest)
		return false
	}
	return true
}
