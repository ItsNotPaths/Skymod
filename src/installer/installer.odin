package installer

// Installer / converter pipeline (ROADMAP Phase 1c): detect + validate a Skyrim
// install, run a data-driven converter registry, and produce a clean data root
// (verbatim assets VFS-served; converted assets in a versioned store) with a
// hash-based manifest for incremental, inspectable re-runs. Converters are one
// file each in installer/converters.
//
// This is the SAME executable as the game (console-recomp style): on boot main
// asks content_ready(); if false it runs install() and relaunches. The heavy
// conversion (BSA mounts, ESM parsing, the converter registry) is Phase 1 work —
// today install() validates the source and writes the manifest that flips the
// boot gate, so the end-to-end install -> relaunch -> play loop is wired.

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "../formats/pe"
import "core:time"

CONTENT_DIR    :: "content"      // <base>/content — the installed data root
MANIFEST       :: "manifest.txt" // <base>/content/manifest.txt — the boot gate marker
FORMAT_VERSION :: 1

// content_ready reports whether <base>/content holds a finished install. The
// boot gate: true => launch the game, false => run the installer. For now a
// present, non-empty manifest is enough; Phase 1 will validate FORMAT_VERSION and
// per-asset hashes here so a stale install triggers a re-run.
content_ready :: proc(base: string) -> bool {
	m := manifest_path(base)
	defer delete(m)
	data, err := os.read_entire_file(m, context.temp_allocator)
	return err == nil && len(data) > 0
}

// Edition is which Skyrim generation an install root holds, autodetected from the
// executable beside Data/. The parsers self-detect per FILE (BSA version, NIF BS
// version, form version), so this is for install selection + logging, not format
// branching.
Edition :: enum {
	Unknown,
	LE,
	SE,
}

// detect_edition identifies the edition AND the exact patch from the exe: the file
// name picks the product line (SkyrimSE.exe vs TESV.exe — their version ranges
// overlap, so the name disambiguates), and the PE version resource (the "File
// version" Windows shows in Properties) supplies the authoritative version —
// 1.6.x = Anniversary, 1.1–1.5.x = Special, 1.9.32 = LE final. version is
// {0,0,0,0} if the exe carries no version resource.
detect_edition :: proc(src: string) -> (ed: Edition, version: [4]u16) {
	se, _ := filepath.join({src, "SkyrimSE.exe"}, context.temp_allocator)
	if os.exists(se) {
		version, _ = pe.file_version(se)
		return .SE, version
	}
	le, _ := filepath.join({src, "TESV.exe"}, context.temp_allocator)
	if os.exists(le) {
		version, _ = pe.file_version(le)
		return .LE, version
	}
	return .Unknown, {}
}

// valid_source reports whether `path` looks like a real Skyrim install: a Data/
// folder holding the base master, Skyrim.esm. Cheap pre-check so we can reject a
// bad path before doing any work (and re-prompt for it).
valid_source :: proc(path: string) -> bool {
	if strings.trim_space(path) == "" {
		return false
	}
	esm, _ := filepath.join({path, "Data", "Skyrim.esm"}, context.temp_allocator)
	return os.exists(esm)
}

// install converts a validated Skyrim install at `source` into <base>/content,
// then writes the manifest that content_ready() looks for. Returns false (after
// logging) on a bad source or any IO failure.
install :: proc(source, base: string) -> bool {
	if !valid_source(source) {
		log.errorf("installer: %q is not a Skyrim install (no Data/Skyrim.esm)", source)
		return false
	}

	content, _ := filepath.join({base, CONTENT_DIR}, context.temp_allocator)
	os.make_directory(content) // ignore "already exists"; verified below
	if !os.is_dir(content) {
		log.errorf("installer: could not create content dir %q", content)
		return false
	}
	log.infof("installer: installing from %s -> %s", source, content)

	// Index, don't copy (ROADMAP §0.5): record the BSA set the VFS will mount and
	// the plugin list the gamedb will load. Textures/meshes/plugins are read live
	// through these — `content/` stays an index, not a copy of the game.
	//
	// HOLE(mods, gap): load order is masters-then-plugins, each name-sorted. plugins.txt and loadorder.txt are not read, so the user's real order is ignored.
	// TODO(Milestone C): true load order from plugins.txt/loadorder.txt; for now
	// masters (.esm) before plugins (.esp), each name-sorted. TODO(Milestone B+):
	// run the lazy audio/HKX converters into content/ here.
	data := data_path(source)
	defer delete(data)
	archives := list_by_ext(data, ".bsa")
	esms := list_by_ext(data, ".esm")
	esps := list_by_ext(data, ".esp")

	m := manifest_path(base)
	defer delete(m)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "format = %d", FORMAT_VERSION)
	fmt.sbprintfln(&b, "source = %s", source)
	fmt.sbprintfln(&b, "installed = %s", stamp())
	for a in archives {
		fmt.sbprintfln(&b, "archive = %s", a)
	}
	for p in esms {
		fmt.sbprintfln(&b, "plugin = %s", p)
	}
	for p in esps {
		fmt.sbprintfln(&b, "plugin = %s", p)
	}
	if err := os.write_entire_file(m, transmute([]byte)strings.to_string(b)); err != nil {
		log.errorf("installer: could not write manifest %q: %v", m, err)
		return false
	}

	log.infof("installer: done — indexed %d archive(s), %d plugin(s) -> %s", len(archives), len(esms) + len(esps), m)
	return true
}

@(private)
data_path :: proc(source: string) -> string {
	p, _ := filepath.join({source, "Data"})
	return p
}

// list_by_ext returns the names (not full paths) of files in `dir` whose name ends
// with `ext` (case-insensitive), name-sorted. Temp-allocated — valid for the frame.
@(private)
list_by_ext :: proc(dir: string, ext: string) -> []string {
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return {}
	}
	out := make([dynamic]string, 0, len(infos), context.temp_allocator)
	for fi in infos {
		lower := strings.to_lower(fi.name, context.temp_allocator)
		if strings.has_suffix(lower, ext) {
			append(&out, fi.name)
		}
	}
	slice.sort(out[:])
	return out[:]
}

@(private)
manifest_path :: proc(base: string) -> string {
	p, _ := filepath.join({base, CONTENT_DIR, MANIFEST})
	return p
}

@(private)
stamp :: proc() -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock_from_time(t)
	return fmt.tprintf("%4d-%02d-%02d %02d:%02d:%02d", y, int(mo), d, h, mi, s)
}
