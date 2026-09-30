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
import "converters"
import "core:time"

CONTENT_DIR    :: "content"      // <base>/content — the installed data root
SCRIPTS_MOD    :: "basescripts"  // <base>/content/basescripts — the content mod holding the base game's scripts
SCRIPTS_DIR    :: "scripts"      // a mod's scripts folder: <mod>/scripts/<name>.lua and <name>.patch.lua
AUDIO_MOD      :: "baseaudio"    // <base>/content/baseaudio — the content mod holding converted game audio
UI_MOD         :: "baseui"       // <base>/content/baseui — the content mod holding our UI and its vanilla art
BETHASSETS_DIR :: "bethassets"   // a content mod's VFS-mounted asset root
MANIFEST       :: "manifest.txt" // <base>/content/manifest.txt — the boot gate marker
Progress       :: converters.Progress
progress_read  :: converters.progress_read
// Bump a part's version when its converter's output changes, so an older install re-runs that part.
SCRIPTS_VERSION :: 4
AUDIO_VERSION   :: 4
MAGIC_VERSION   :: 7
UI_VERSION      :: 1

// Part is a converted piece of the install. Each has its own key in the manifest; a part whose key
// changed runs again alone, and the others keep their output.
Part :: enum {
	Scripts,
	Audio,
	Magic,
	UI,
}

// part_key is what a part's output depends on: its converter version, and for scripts and UI the
// shipped data.
@(private)
part_key :: proc(p: Part) -> string {
	switch p {
	case .Scripts:
		return fmt.tprintf("v%d %x", SCRIPTS_VERSION, converters.rewrites_hash())
	case .Audio:
		return fmt.tprintf("v%d", AUDIO_VERSION)
	case .Magic:
		return fmt.tprintf("v%d", MAGIC_VERSION)
	case .UI:
		return fmt.tprintf("v%d %x", UI_VERSION, converters.ui_hash())
	}
	return ""
}

// stale_parts are the parts whose manifest key differs from this build's: all of them when there
// is no manifest.
stale_parts :: proc(base: string) -> (stale: bit_set[Part]) {
	m := manifest_path(base)
	defer delete(m)
	data, err := os.read_entire_file(m, context.temp_allocator)
	text := string(data) if err == nil else ""
	for p in Part {
		line := fmt.tprintf("part.%v = %s\n", p, part_key(p))
		if !strings.contains(text, line) {stale += {p}}
	}
	return
}

// content_ready reports whether <base>/content holds every part as this build makes it. The boot
// gate: true => launch the game, false => run the installer, which redoes only the stale parts.
content_ready :: proc(base: string) -> bool {
	return stale_parts(base) == {}
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
install :: proc(source, base: string, progress: ^Progress = nil) -> bool {
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
	// (hole load-order-files :tags mods :sev gap) the installer lists plugins and orders archives masters-then-plugins by name; plugins.txt and loadorder.txt are not read, so an existing install's order is not imported into the mod list.
	data := data_path(source)
	defer delete(data)
	archives := list_by_ext(data, ".bsa")
	esms := list_by_ext(data, ".esm")
	esps := list_by_ext(data, ".esp")
	esls := list_by_ext(data, ".esl")

	ordered := archive_order(data, archives, {esms, esls, esps})
	stale := stale_parts(base)
	if .Scripts in stale {
		scripts_dir, _ := filepath.join({content, SCRIPTS_MOD, SCRIPTS_DIR}, context.temp_allocator)
		sst, sok := converters.convert_scripts(ordered, scripts_dir, progress)
		if !sok {
			return false
		}
		log.infof("installer: converted %d script(s) to Lua, %d unreadable, %d rewrite(s)", sst.converted, sst.failed, sst.rewrites)
	}
	if .Audio in stale {
		audio_dir, _ := filepath.join({content, AUDIO_MOD, BETHASSETS_DIR}, context.temp_allocator)
		ast, aok := converters.convert_audio(ordered, audio_dir, progress)
		if !aok {
			return false
		}
		log.infof("installer: converted %d sound(s) to Ogg, %d unreadable", ast.converted, ast.failed)
	}
	if .Magic in stale {
		magic_dir, _ := filepath.join({content, SCRIPTS_MOD, SCRIPTS_DIR}, context.temp_allocator)
		for sub in ([]string{"effects", "spells", "powers", "items", "perks"}) { // the translator's alone
			old, _ := filepath.join({magic_dir, sub}, context.temp_allocator)
			os.remove_all(old)
		}
		plugins := make([dynamic]string, context.temp_allocator)
		append(&plugins, ..esms)
		append(&plugins, ..esls)
		append(&plugins, ..esps)
		mst, mok := converters.convert_magic(data, plugins[:], magic_dir, progress)
		if !mok {
			return false
		}
		log.infof("installer: translated %d effect(s), %d spell(s) and power(s), %d item(s) and %d perk(s) to Lua, %d record(s) not", mst.effects, mst.spells, mst.items, mst.perks, mst.skipped)
	}
	if .UI in stale {
		ui_dir, _ := filepath.join({content, UI_MOD, BETHASSETS_DIR}, context.temp_allocator)
		_, v := detect_edition(source)
		version := fmt.tprintf("%d.%d.%d.%d", v[0], v[1], v[2], v[3])
		ust, uok := converters.convert_ui(data, ordered, version, ui_dir, progress)
		if !uok {
			return false
		}
		log.infof("installer: extracted %d UI file(s) for game %s, %d asset(s) missing, %d bank file(s) unlinked", ust.written, version, ust.missing, ust.unlinked)
	}
	log.infof("installer: parts redone %v, kept %v", stale, ~stale)

	m := manifest_path(base)
	defer delete(m)
	b := strings.builder_make(context.temp_allocator)
	for p in Part {
		fmt.sbprintfln(&b, "part.%v = %s", p, part_key(p))
	}
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

// IMPLICIT_MASTERS load first, in this order, whatever else the load order says.
IMPLICIT_MASTERS :: [?]string{"skyrim", "update", "dawnguard", "hearthfires", "dragonborn"}

// archive_order lists the archives in mount order, later winning: those of no plugin name-sorted,
// then each plugin's ("<plugin>.bsa", "<plugin> - *.bsa") in plugin order, the implicit masters
// first. Plugin order carries the load-order HOLE above; on LE it hands HearthFires' copy of
// byohrelationshipadoptableaccessor the win over Dragonborn's, and Dragonborn's 14 voice lines
// the win over Skyrim - Voices.
@(private)
archive_order :: proc(data: string, archives: []string, plugin_groups: [][]string) -> []string {
	plugins := make([dynamic]string, 0, 16, context.temp_allocator)
	for m in IMPLICIT_MASTERS {append(&plugins, m)}
	for group in plugin_groups {
		for p in group {
			stem := strings.to_lower(filepath.stem(p), context.temp_allocator)
			if !slice.contains(plugins[:len(IMPLICIT_MASTERS)], stem) {append(&plugins, stem)}
		}
	}
	Ranked :: struct {rank: int, name: string}
	ranked := make([dynamic]Ranked, 0, len(archives), context.temp_allocator)
	for a in archives {
		name := strings.to_lower(filepath.stem(a), context.temp_allocator)
		rank := 0
		for p, i in plugins {
			if name == p || strings.has_prefix(name, strings.concatenate({p, " - "}, context.temp_allocator)) {rank = i + 1}
		}
		append(&ranked, Ranked{rank, a})
	}
	slice.sort_by(ranked[:], proc(x, y: Ranked) -> bool {
		return x.rank < y.rank if x.rank != y.rank else x.name < y.name
	})
	out := make([]string, len(ranked), context.temp_allocator)
	for r, i in ranked {
		out[i], _ = filepath.join({data, r.name}, context.temp_allocator)
	}
	return out
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
