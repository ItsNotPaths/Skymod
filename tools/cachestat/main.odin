package main

// cachestat — headless asset-cache footprint probe (short-term-plan D1 scoping; no GPU,
// no window). Mounts the real install, builds gamedb from Skyrim.esm, then decodes every
// unique model a streaming window around Riverwood would cache and sums what each part of
// a cached assetdb entry would occupy:
//
//   mesh      — GPU vertex+index buffers (what draw needs)
//   pick      — the CPU positions+indices copy kept per Model for ray-picking
//   collision — the cloned bhk* geometry kept per Model for physics builds
//   textures  — unique diffuse+normal DDS payloads (BC data uploads as-is, so blob ≈ GPU size)
//
// Also sizes the whole-worldspace object-LOD bake set (band 1) — the models the bake pins
// for the session regardless of eviction. Output feeds the D1 eviction/slimming design.
//
//   odin build tools/cachestat -out:build/out/cachestat -extra-linker-flags:"$SDL_LINK"
//   ./build/out/cachestat /path/to/Skyrim [radius]

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../../src/assetdb"
import "../../src/gamedb"
import "../../src/render"
import "../../src/vfs"

RIVERWOOD_GX :: 5
RIVERWOOD_GY :: -11

Tally :: struct {
	models:    int,
	mesh:      int, // GPU verts + indices
	pick:      int, // CPU pick copy (pos + idx + shape map)
	collision: int, // CPU collision clone
	shapes:    int, // Shape struct array overhead
	tex:       int, // unique texture payload bytes
	tex1024:   int, // …if uploads dropped mips above 1024px (texture_max_dim=1024)
	tex512:    int, // …capped at 512px
	ntex:      int,
	failed:    int,
}

Offender :: struct {
	path:  string,
	bytes: int,
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: cachestat <skyrim_dir> [radius]")
		os.exit(1)
	}
	src := os.args[1]
	radius := 6
	if len(os.args) >= 3 {
		if n, ok := strconv.parse_int(os.args[2]); ok && n > 0 {radius = n}
	}

	// VFS: loose Data/ + the static-asset archives (mirrors the app's mount_game).
	v: vfs.VFS
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	vfs.mount_loose(&v, data_dir)
	for name in ([]string{"Skyrim - Meshes.bsa", "Skyrim - Textures.bsa"}) {
		p, _ := filepath.join({data_dir, name}, context.temp_allocator)
		if !vfs.mount_archive(&v, p) {
			fmt.eprintfln("could not mount %s", p)
			os.exit(1)
		}
	}
	defer vfs.destroy(&v)

	// gamedb from Skyrim.esm alone (MODL paths only — no strings needed, base game is
	// representative for sizing).
	esm_path, _ := filepath.join({data_dir, "Skyrim.esm"}, context.temp_allocator)
	esm, rerr := os.read_entire_file(esm_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("could not read %s", esm_path)
		os.exit(1)
	}
	defer delete(esm)
	inputs := []gamedb.Plugin_Input{{name = "Skyrim.esm", data = esm}}
	order := gamedb.resolve_load_order(inputs)
	defer delete(order)
	fmt.println("building gamedb from Skyrim.esm…")
	db := gamedb.build_plugins(order)
	defer gamedb.destroy(&db)
	free_all(context.temp_allocator)

	wfid, wok := gamedb.find_world(&db, "Tamriel")
	if !wok {
		fmt.eprintln("Tamriel not found")
		os.exit(1)
	}

	// --- The streaming window's full-detail model set ---
	window_paths := make([dynamic]string) // unique, insertion-ordered
	seen := make(map[string]bool)
	cells := 0
	for gy in i32(RIVERWOOD_GY - radius) ..= i32(RIVERWOOD_GY + radius) {
		for gx in i32(RIVERWOOD_GX - radius) ..= i32(RIVERWOOD_GX + radius) {
			cid, cok := gamedb.cell_at(&db, wfid, gx, gy)
			if !cok {continue}
			cells += 1
			for r in gamedb.refs_of(&db, cid) {
				if r.disabled {continue}
				modl, mok := gamedb.model_of(&db, r.base)
				if !mok || modl == "" {continue}
				low := strings.to_lower(modl, context.temp_allocator)
				if strings.contains(low, "marker") {continue} // never rendered/cached meaningfully
				if strings.contains(low, "sky\\") || strings.contains(low, "water\\") {continue}
				if seen[low] {continue}
				seen[strings.clone(low)] = true
				append(&window_paths, modl)
			}
		}
	}
	fmt.printfln("window r=%d around Riverwood: %d cells, %d unique models — decoding…", radius, cells, len(window_paths))
	win, win_off, win_texoff := tally_models(&v, window_paths[:], &seen_tex)

	// --- The object-LOD bake set: whole-worldspace band-1 meshes (session-pinned) ---
	lod_paths := make([dynamic]string)
	lod_seen := make(map[string]bool)
	for cid in gamedb.cells_of(&db, wfid) {
		for r in gamedb.refs_of(&db, cid) {
			if r.disabled {continue}
			if lp, ok := gamedb.lod_model_of(&db, r.base, 1); ok && lp != "" {
				low := strings.to_lower(lp, context.temp_allocator)
				if strings.contains(low, "marker") {continue}
				if lod_seen[low] {continue}
				lod_seen[strings.clone(low)] = true
				append(&lod_paths, lp)
			}
		}
		free_all(context.temp_allocator)
	}
	fmt.printfln("object-LOD bake set (whole Tamriel, band 1): %d unique meshes — decoding…", len(lod_paths))
	lod, lod_off, lod_texoff := tally_models(&v, lod_paths[:], &seen_tex_lod, extras = false)

	fmt.println()
	report("STREAMING WINDOW (full-detail models)", win)
	top("heaviest models", win_off)
	top("heaviest textures", win_texoff)
	fmt.println()
	report("OBJECT-LOD BAKE SET (pinned for the session)", lod)
	top("heaviest LOD meshes", lod_off)
	top("heaviest LOD textures", lod_texoff)
}

seen_tex: map[string]bool // unique-texture dedup across the window set
seen_tex_lod: map[string]bool // …and separately for the LOD set

// tally_models decodes each path and sums what caching it would cost, per category.
// extras=false mirrors the engine's draw-only decodes (LOD bake/billboards/grass): no
// pick copy, no collision clone.
tally_models :: proc(v: ^vfs.VFS, paths: []string, texseen: ^map[string]bool, extras := true) -> (t: Tally, offenders: [dynamic]Offender, texoff: [dynamic]Offender) {
	for path, n in paths {
		cpu := assetdb.decode_model(v, path, 0, want_extras = extras)
		if !cpu.ok {
			t.failed += 1
			free_all(context.temp_allocator)
			continue
		}
		mesh, pick, col := 0, 0, 0
		nverts, nidx := 0, 0
		for cs in cpu.shapes {
			mesh += len(cs.verts) * size_of(render.Mesh_Vertex) + len(cs.indices) * size_of(u16)
			nverts += len(cs.verts)
			nidx += len(cs.indices)
			// unique texture payloads (BC blob ≈ GPU size); key = path + colorspace like tex_key
			track_tex(texseen, cs.diffuse_path, true, cs.diffuse, &t, &texoff)
			track_tex(texseen, cs.normal_path, false, cs.normal, &t, &texoff)
		}
		// Compact pick copy (D1 slimming): u16-quantized positions + u16 indices when the
		// model fits (u32 past 65536 verts) + u16 per-tri shape map. Draw-only decodes
		// (extras=false) build none of it.
		if extras {
			idx_sz := size_of(u16) if nverts <= 1 << 16 else size_of(u32)
			pick = nverts * size_of([3]u16) + nidx * idx_sz + (nidx / 3) * size_of(u16)
		}
		for sh in cpu.collision.shapes {
			col += len(sh.vertices) * size_of([3]f32) + len(sh.indices) * size_of(u32) + size_of(sh)
		}
		t.models += 1
		t.mesh += mesh
		t.pick += pick
		t.collision += col
		t.shapes += len(cpu.shapes) * size_of(assetdb.Shape)
		append(&offenders, Offender{path = strings.clone(path), bytes = mesh + pick + col})
		assetdb.free_cpu_model(cpu)
		free_all(context.temp_allocator)
		if (n + 1) % 250 == 0 {
			fmt.printfln("  … %d/%d", n + 1, len(paths))
		}
	}
	slice.sort_by(offenders[:], proc(a, b: Offender) -> bool {return a.bytes > b.bytes})
	slice.sort_by(texoff[:], proc(a, b: Offender) -> bool {return a.bytes > b.bytes})
	return
}

track_tex :: proc(texseen: ^map[string]bool, path: string, srgb: bool, cpu: assetdb.Cpu_Tex, t: ^Tally, off: ^[dynamic]Offender) {
	if path == "" || !cpu.ok {
		return // un-ok = either missing or a within-model duplicate (pixels live on the first use)
	}
	key := strings.concatenate({strings.to_lower(path, context.temp_allocator), "|s" if srgb else "|l"}, context.temp_allocator)
	if texseen[key] {
		return
	}
	texseen[strings.clone(key)] = true
	t.tex += len(cpu.pixels)
	for m in cpu.mips {
		if m.width <= 1024 && m.height <= 1024 {t.tex1024 += len(m.data)}
		if m.width <= 512 && m.height <= 512 {t.tex512 += len(m.data)}
	}
	t.ntex += 1
	append(off, Offender{path = strings.clone(path), bytes = len(cpu.pixels)})
}

report :: proc(label: string, t: Tally) {
	mb :: proc(b: int) -> f64 {return f64(b) / (1024 * 1024)}
	total := t.mesh + t.pick + t.collision + t.shapes + t.tex
	fmt.printfln("== %s ==", label)
	fmt.printfln("  models: %d decoded (%d failed), unique textures: %d", t.models, t.failed, t.ntex)
	fmt.printfln("  mesh GPU (verts+idx):   %8.1f MB", mb(t.mesh))
	fmt.printfln("  pick CPU copy:          %8.1f MB", mb(t.pick))
	fmt.printfln("  collision clone CPU:    %8.1f MB", mb(t.collision))
	fmt.printfln("  shape structs:          %8.1f MB", mb(t.shapes))
	fmt.printfln("  textures (unique, BC):  %8.1f MB   (capped@1024: %.1f MB, @512: %.1f MB)", mb(t.tex), mb(t.tex1024), mb(t.tex512))
	fmt.printfln("  TOTAL cached:           %8.1f MB", mb(total))
}

top :: proc(label: string, off: [dynamic]Offender) {
	fmt.printfln("  -- top %s --", label)
	for o, i in off {
		if i >= 8 {break}
		fmt.printfln("     %6.1f MB  %s", f64(o.bytes) / (1024 * 1024), o.path)
	}
}
