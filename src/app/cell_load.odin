package main

// Cell-load setup (ROADMAP Iteration 1, Milestone C): mount the install's archives
// into a VFS and build the gamedb from Skyrim.esm, so run_game can place a real
// interior cell. Thin glue — no SDL; the VFS/gamedb/world packages do the work.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"

import "../formats/esm"
import "../formats/nif"
import "../formid"
import "../gamedb"
import "../installer"
import smath "../math"
import "../mods"
import "../physics"
import "../render"
import "../settings"
import "../vfs"
import "../world"
import "../worldstate"

// Form_ID is the global form handle (= gamedb.Form_ID = u64): (slot<<32)|local.
Form_ID :: gamedb.Form_ID

// sort_names sorts file/dir names case-insensitively, in place — the one comparator every
// discover_*/files_with_suffix helper below shares (Bethesda listings are case-insensitive).
@(private = "file")
sort_names :: proc(names: []string) {
	slice.sort_by(names, proc(a, b: string) -> bool {
		return strings.compare(strings.to_lower(a, context.temp_allocator), strings.to_lower(b, context.temp_allocator)) < 0
	})
}

// Archives we mount into the VFS: the static-world assets an interior needs (meshes +
// diffuse textures) PLUS Interface (the menu's fonts/credits/SWFs + UI textures + the base
// game's localized STRINGS tables). LE ships single files ("Skyrim - Meshes.bsa"); SSE splits
// the same families ("Skyrim - Meshes0/1.bsa", "Skyrim - Textures0..8.bsa") — so match by
// family prefix against what's actually in Data instead of hardcoding an edition's names.
// PLUS plugin-associated archives (the SSE auto-load rule): for every plugin "X.es[mpl]" in
// Data, "X.bsa" and "X - Textures.bsa" load with it — that's where Creation Club content
// (cc*.esl + cc*.bsa, _ResourcePack) keeps its meshes/textures AND its STRINGS; without
// these, all CC records stay nameless and its assets invisible. Families sort first (base
// precedence), then plugin archives — later mounts win, matching the real engine.
// Sounds holds the WAVs; the voices and music it and Voices held in xWMA are converted into the
// content/baseaudio archives. Deliberately still excluded: Voices/Animations/Misc/Shaders.
game_archive_names :: proc(data_dir: string, allocator := context.allocator) -> []string {
	bsas := files_with_suffix(data_dir, {".bsa"}, context.temp_allocator)
	by_lower := make(map[string]string, len(bsas), context.temp_allocator) // lower name -> on-disk name
	for b in bsas {by_lower[strings.to_lower(b, context.temp_allocator)] = b}

	added := make(map[string]bool, 64, context.temp_allocator) // lower names already in out
	out := make([dynamic]string, 0, 16, allocator)

	fams := make([dynamic]string, 0, 16, context.temp_allocator)
	for b in bsas {
		lower := strings.to_lower(b, context.temp_allocator)
		if strings.has_prefix(lower, "skyrim - meshes") ||
		   strings.has_prefix(lower, "skyrim - textures") ||
		   strings.has_prefix(lower, "skyrim - interface") ||
		   strings.has_prefix(lower, "skyrim - sounds") {
			append(&fams, b)
			added[lower] = true
		}
	}
	sort_names(fams[:])
	for f in fams {append(&out, strings.clone(f, allocator))}

	assoc := make([dynamic]string, 0, 64, context.temp_allocator)
	for pl in files_with_suffix(data_dir, {".esm", ".esp", ".esl"}, context.temp_allocator) {
		stem := strings.to_lower(filepath.stem(pl), context.temp_allocator)
		for suffix in ([]string{".bsa", " - textures.bsa"}) {
			key := strings.concatenate({stem, suffix}, context.temp_allocator)
			if actual, ok := by_lower[key]; ok && !added[key] {
				append(&assoc, actual)
				added[key] = true
			}
		}
	}
	sort_names(assoc[:])
	for a in assoc {append(&out, strings.clone(a, allocator))}
	return out[:]
}

// mount_game builds a VFS over <src>/Data: the loose folder (highest precedence) plus
// the static-asset archives. Caller frees with vfs.destroy.
mount_game :: proc(src: string) -> vfs.VFS {
	v: vfs.VFS
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	vfs.mount_loose(&v, data_dir)
	for name in game_archive_names(data_dir, context.temp_allocator) {
		p, _ := filepath.join({data_dir, name}, context.temp_allocator)
		if !vfs.mount_archive(&v, p) {
			log.warnf("could not mount %s", p)
		}
	}
	return v
}

// discover_plugins lists the plugin files (.esm/.esp/.esl) present in <src>/Data, sorted
// case-insensitively. The mod Profile reconciles against this set (enable/disable). Returns the
// names allocated in `allocator` (caller frees the slice + each name).
discover_plugins :: proc(src: string, allocator := context.allocator) -> ([]string, bool) {
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	infos, derr := os.read_all_directory_by_path(data_dir, context.temp_allocator)
	if derr != nil {
		log.errorf("could not read %s", data_dir)
		return {}, false
	}
	out := make([dynamic]string, 0, 16, allocator)
	for fi in infos {
		lower := strings.to_lower(fi.name, context.temp_allocator)
		if strings.has_suffix(lower, ".esm") || strings.has_suffix(lower, ".esp") || strings.has_suffix(lower, ".esl") {
			append(&out, strings.clone(fi.name, allocator))
		}
	}
	sort_names(out[:])
	return out[:], true
}

// load_gamedb reads every plugin in <src>/Data, resolves the load order, and builds one DB with
// FormIDs remapped into global load-order space (later plugins override earlier). Used by the dev
// tools; the full game uses load_gamedb_mods with the active profile. Plugin bytes are freed after
// the build — the DB clones what it keeps.
load_gamedb :: proc(src: string) -> (gamedb.DB, bool) {
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	names, ok := discover_plugins(src, context.temp_allocator)
	if !ok || len(names) == 0 {
		log.errorf("no plugins (.esm/.esp/.esl) found in %s", data_dir)
		return {}, false
	}
	// Strings resolve through a VFS (base tables live inside BSAs on SSE); a throwaway
	// mount is cheap (headers only) and freed once the tables are copied out.
	v := mount_game(src)
	defer vfs.destroy(&v)
	inputs := make([dynamic]gamedb.Plugin_Input, 0, 16, context.allocator)
	defer {
		for inp in inputs {delete(inp.name);delete(inp.data);delete(inp.strings_data);delete(inp.dlstrings_data);delete(inp.ilstrings_data)}
		delete(inputs)
	}
	for name in names {read_plugin_into(&inputs, &v, data_dir, name)}
	if len(inputs) == 0 {
		return {}, false
	}
	order := gamedb.resolve_load_order(inputs[:], context.allocator)
	defer delete(order, context.allocator)
	log.infof("loading gamedb from %d plugin(s)…", len(order))
	db := gamedb.build_plugins(order, context.allocator)
	load_race_bounds(&db, &v)
	return db, true
}

// load_race_bounds sizes each race from its skeleton's BBX (gamedb.actor_bounds): the male
// skeleton, else the female one.
load_race_bounds :: proc(db: ^gamedb.DB, v: ^vfs.VFS) {
	for id, r in db.races {
		for path in r.skeletons {
			if path == "" {continue}
			data, ok := vfs.read(v, strings.concatenate({"meshes\\", path}, context.temp_allocator), context.temp_allocator)
			if !ok {continue}
			if center, half, found := nif.bound(data); found {
				gamedb.set_race_bounds(db, id, center, half)
				break
			}
		}
	}
}

// MODS_DIRNAME is the folder under the exe dir (base) that holds installed mod folders (MO2-style).
MODS_DIRNAME :: "mods"

// FORM_TABLE_FILE is the persisted, cross-profile mod-identity → stable-slot map (docs/mods.md), kept
// beside the exe. Global (shared across profiles), atomic-written by the form-table.
FORM_TABLE_FILE :: "form_table.txt"

// OFFICIAL_SLOTS pins the base game + DLC masters to fixed low slots. Skyrim.esm MUST be 0 (raw refs
// like the persistent cell 0x00000D74 and the player 0x14 assume a high word of 0); the rest keep
// Bethesda's canonical order for readability. Any other vanilla-Data plugin interns as base content.
@(private = "file")
OFFICIAL_SLOTS := [?]struct {
	name: string,
	slot: u32,
}{{"Skyrim.esm", 0}, {"Update.esm", 1}, {"Dawnguard.esm", 2}, {"HearthFires.esm", 3}, {"Dragonborn.esm", 4}}

// load_form_table reads the persisted global form-table (<base>/form_table.txt) with the official
// masters re-pinned — the identity source for the save-bridge remap. Caller destroys it; empty on a
// first run (before any gamedb build has populated it).
load_form_table :: proc(base: string, allocator := context.allocator) -> mods.Form_Table {
	ft: mods.Form_Table
	mods.formtable_init(&ft, allocator)
	p, _ := filepath.join({base, FORM_TABLE_FILE}, context.temp_allocator)
	mods.formtable_load(&ft, p)
	for o in OFFICIAL_SLOTS {mods.formtable_assign_official(&ft, o.name, o.slot)}
	return ft
}

// form_bridge builds a worldstate.Form_Bridge over a form-table: the save uses `identify` to name the
// stable slots it references and `resolve` to map a saved identity back to this install's slot on load
// (docs/saves.md §4.4). `ft` must outlive every save/load call that uses the returned bridge.
form_bridge :: proc(ft: ^mods.Form_Table) -> worldstate.Form_Bridge {
	return {
		user = ft,
		identify = proc(user: rawptr, slot: u32) -> (uuid: string, filename: string, ok: bool) {
			if e, has := mods.formtable_entry_by_slot((^mods.Form_Table)(user), slot); has {
				return e.uuid, e.filename, true
			}
			return "", "", false
		},
		resolve = proc(user: rawptr, uuid: string, filename: string) -> (slot: u32, ok: bool) {
			return mods.formtable_resolve((^mods.Form_Table)(user), uuid, filename)
		},
	}
}

// mod_identity_uuid returns a mod's stable identity: its sidecar uuid (mods/<name>/skymod/mod.txt) if
// present, else a content hash of the plugin bytes it actually shipped (the legacy fallback). Temp-
// allocated — the caller interns it (which clones into the form-table's ownership).
@(private = "file")
mod_identity_uuid :: proc(mdir: string, plugins: []gamedb.Plugin_Input) -> string {
	if id, ok := mods.read_sidecar(mdir, context.temp_allocator); ok {
		return id.uuid
	}
	bytes := make([][]u8, len(plugins), context.temp_allocator)
	for p, i in plugins {bytes[i] = p.data}
	return mods.content_hash_identity(bytes, context.temp_allocator)
}

// mods_root is <base>/mods (temp-allocated by default).
mods_root :: proc(base: string, allocator := context.temp_allocator) -> string {
	r, _ := filepath.join({base, MODS_DIRNAME}, allocator)
	return r
}

// PROFILES_DIRNAME holds the per-profile mod lists (the mods/ folder itself is shared across all
// profiles, MO2-style). This is now the ONLY "profiles" concept — the old lighting "profiles/" dir
// became the pinned content/baselighting mod (see baselighting.odin), so this reclaimed the clean
// name via migrate_profiles_layout. DEFAULT_PROFILE is the always-present "vanilla" baseline:
// unmoddable (system plugins only) and the settings ROOT that every other profile inherits from (see
// settings.load_child + the input-system notes). Other profiles carry only sparse overrides.
PROFILES_DIRNAME :: "profiles"
DEFAULT_PROFILE :: "vanilla"

// migrate_profiles_layout performs the one-time move of mod profiles from the legacy <base>/modprofiles/
// to <base>/profiles/, now that lighting no longer owns "profiles/". If a stale lighting sidecar dir
// (a folder holding profile.txt, from the old lighting system) sits in profiles/, it's removed first
// so it isn't mistaken for a mod profile. Best-effort + idempotent (no-op once modprofiles/ is gone).
migrate_profiles_layout :: proc(base: string) {
	old, _ := filepath.join({base, "modprofiles"}, context.temp_allocator)
	if !os.is_dir(old) {
		return // already migrated (or fresh install)
	}
	newp := profiles_root(base, context.temp_allocator)
	// Purge stale lighting sidecars (folder with profile.txt, no modlist.txt) squatting in profiles/.
	if infos, err := os.read_all_directory_by_path(newp, context.temp_allocator); err == nil {
		for fi in infos {
			if fi.type != .Directory {continue}
			d, _ := filepath.join({newp, fi.name}, context.temp_allocator)
			pf, _ := filepath.join({d, "profile.txt"}, context.temp_allocator)
			ml, _ := filepath.join({d, "modlist.txt"}, context.temp_allocator)
			if os.exists(pf) && !os.exists(ml) {
				remove_tree(d)
			}
		}
	}
	_ = os.make_directory(newp)
	// Move each mod-profile folder from modprofiles/ into profiles/ (skip any name that already exists).
	if infos, err := os.read_all_directory_by_path(old, context.temp_allocator); err == nil {
		for fi in infos {
			if fi.type != .Directory {continue}
			from, _ := filepath.join({old, fi.name}, context.temp_allocator)
			to, _ := filepath.join({newp, fi.name}, context.temp_allocator)
			if !os.exists(to) {
				_ = os.rename(from, to)
			}
		}
	}
	remove_tree(old) // drop the now-empty (or leftover) legacy dir
	log.info("profiles: migrated modprofiles/ -> profiles/")
}

// remove_tree recursively deletes `path` (children first, then the now-empty dir; os.remove handles
// both files and empty dirs). Best-effort — a failure just leaves the remnant in place.
remove_tree :: proc(path: string) {
	if infos, err := os.read_all_directory_by_path(path, context.temp_allocator); err == nil {
		for fi in infos {
			child, _ := filepath.join({path, fi.name}, context.temp_allocator)
			if fi.type == .Directory {
				remove_tree(child)
			} else {
				_ = os.remove(child)
			}
		}
	}
	_ = os.remove(path)
}

// modlist_path_for returns <base>/profiles/<name>/modlist.txt (temp-allocated by default).
modlist_path_for :: proc(base, name: string, allocator := context.temp_allocator) -> string {
	r, _ := filepath.join({base, PROFILES_DIRNAME, name, "modlist.txt"}, allocator)
	return r
}

// ensure_profile_dir creates <base>/profiles/<name>/ (idempotent).
ensure_profile_dir :: proc(base, name: string) {
	_ = os.make_directory(profiles_root(base))
	dir, _ := filepath.join({base, PROFILES_DIRNAME, name}, context.temp_allocator)
	_ = os.make_directory(dir)
}

// load_root_settings loads the ROOT settings — the vanilla baseline every profile
// inherits — from <base>/profiles/vanilla/settings.txt. The EXECUTABLE owns this file
// (not the release script): it ensures the dir, migrates any legacy <base>/settings.txt
// left by an older build into vanilla (one-time), backfills the DEFAULTS embedded in the
// binary, and writes the file on first run so a fresh install ships as just the exe.
load_root_settings :: proc(base: string) -> settings.Config {
	ensure_profile_dir(base, DEFAULT_PROFILE)
	dir, _ := filepath.join({base, PROFILES_DIRNAME, DEFAULT_PROFILE}, context.temp_allocator)
	dest, _ := filepath.join({dir, settings.FILE_NAME}, context.temp_allocator)
	legacy, _ := filepath.join({base, settings.FILE_NAME}, context.temp_allocator)
	if os.exists(legacy) {
		if !os.exists(dest) {
			_ = os.rename(legacy, dest) // relocate the user's existing settings into vanilla
			log.infof("settings: migrated %s -> %s", legacy, dest)
		} else {
			_ = os.remove(legacy) // vanilla is authoritative; drop the stale base copy
		}
	}
	cfg := settings.load(dir)
	if !os.exists(cfg.path) {
		_ = settings.save(&cfg) // first run: materialize the embedded defaults
	}
	return cfg
}

// profiles_root is <base>/profiles (temp-allocated by default).
profiles_root :: proc(base: string, allocator := context.temp_allocator) -> string {
	r, _ := filepath.join({base, PROFILES_DIRNAME}, allocator)
	return r
}

// discover_profiles lists the profile names (subdirs of <base>/profiles), always including the
// vanilla baseline profile, sorted case-insensitively. Allocated in `allocator`.
discover_profiles :: proc(base: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	append(&out, strings.clone(DEFAULT_PROFILE, allocator))
	if infos, derr := os.read_all_directory_by_path(profiles_root(base), context.temp_allocator); derr == nil {
		for fi in infos {
			if fi.type == .Directory && !strings.equal_fold(fi.name, DEFAULT_PROFILE) {
				append(&out, strings.clone(fi.name, allocator))
			}
		}
	}
	sort_names(out[:])
	return out[:]
}

// discover_mod_folders lists the immediate subdirectories of <base>/mods (each = one installed
// mod), sorted case-insensitively. A missing mods/ dir is not an error (returns empty).
discover_mod_folders :: proc(base: string, allocator := context.allocator) -> []string {
	infos, derr := os.read_all_directory_by_path(mods_root(base), context.temp_allocator)
	if derr != nil {
		return {}
	}
	out := make([dynamic]string, 0, 8, allocator)
	for fi in infos {
		if fi.type == .Directory {append(&out, strings.clone(fi.name, allocator))}
	}
	sort_names(out[:])
	return out[:]
}

// system_mod_names returns the locked "system" rows the mod manager shows above user mods, in load-
// priority order: the vanilla base ("Skyrim"), each official DLC actually present in <src>/Data, then
// the forced UI baseline ("SkyMod UI") if content/baseui is installed. These are provided by the
// loader outside the mods/ folder mechanism (vanilla/DLC from Data, UI from content/), so they're
// display + ordering only — `mods.profile_set_system` marks them locked and `profile_enabled_mods`
// skips them. Call after profile_reconcile. Temp-allocated by default (set_system clones what it keeps).
system_mod_names :: proc(src, base: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	append(&out, strings.clone(mods.BASE_MOD, allocator)) // "Skyrim" (the vanilla base)
	// Official DLC masters, shown in official order, only if present in Data.
	DLCS := [?][2]string {
		{"update.esm", "Update"},
		{"dawnguard.esm", "Dawnguard"},
		{"hearthfires.esm", "Hearthfires"},
		{"dragonborn.esm", "Dragonborn"},
	}
	if names, ok := discover_plugins(src, context.temp_allocator); ok {
		for dlc in DLCS {
			for n in names {
				if strings.equal_fold(n, dlc[0]) {
					append(&out, strings.clone(dlc[1], allocator))
					break
				}
			}
		}
	}
	// The forced UI baseline (content/baseui), our reimplementation of Skyrim's UI.
	baseui_dir, _ := filepath.join({base, "content", "baseui"}, context.temp_allocator)
	if os.is_dir(baseui_dir) {
		append(&out, strings.clone("SkyMod UI", allocator))
	}
	// The forced lighting baseline (content/baselighting): the pinned lighting presets.
	if os.is_dir(baselighting_dir(base, context.temp_allocator)) {
		append(&out, strings.clone("SkyMod Lighting", allocator))
	}
	return out[:]
}

// load_gamedb_mods builds the DB from the active mod profile: vanilla Data plugins (the base) plus
// each ENABLED mod folder's plugins, gathered in mod-list order so resolve_load_order's input-rank
// makes the derived load order follow the mod order. `base` is the exe dir (mods/ lives there).
// Load_Progress is the byte counter the threaded gamedb build publishes for the loading bar:
// `done` bytes parsed (updated continuously during the build), out of `total` (set once up front).
Load_Progress :: struct {
	done:  int,
	total: int,
}

load_gamedb_mods :: proc(src, base: string, profile: ^mods.Profile, v: ^vfs.VFS, progress: ^Load_Progress = nil) -> (gamedb.DB, bool) {
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	inputs := make([dynamic]gamedb.Plugin_Input, 0, 16, context.allocator)
	defer {
		for inp in inputs {delete(inp.name);delete(inp.data);delete(inp.strings_data);delete(inp.dlstrings_data);delete(inp.ilstrings_data)}
		delete(inputs)
	}

	// The form-table interns each plugin's STABLE slot (identity ≠ load order — docs/mods.md). Load
	// the persisted global table, pin the official masters (Skyrim.esm==0), intern every plugin below,
	// then save it back so a plugin keeps its slot across runs/reorders (the reorder-breaks-saves fix).
	ft: mods.Form_Table
	mods.formtable_init(&ft, context.allocator)
	defer mods.formtable_destroy(&ft)
	ft_path, _ := filepath.join({base, FORM_TABLE_FILE}, context.temp_allocator)
	mods.formtable_load(&ft, ft_path) // ok=false on first run → empty table
	for o in OFFICIAL_SLOTS {mods.formtable_assign_official(&ft, o.name, o.slot)}

	// Base: vanilla Data plugins (core masters pinned above; other vanilla content interned as base).
	if names, ok := discover_plugins(src, context.temp_allocator); ok {
		for name in names {
			read_plugin_into(&inputs, v, data_dir, name)
			if _, pinned := mods.formtable_slot(&ft, name); !pinned {
				mods.formtable_intern(&ft, name, mods.OFFICIAL_UUID)
			}
		}
	}
	// Enabled user mods, in mod-list order (drives the derived plugin order via the input rank).
	root := mods_root(base)
	enabled := mods.profile_enabled_mods(profile, context.temp_allocator)
	nmods := 0
	for mod in enabled {
		if mod == mods.BASE_MOD {continue}
		nmods += 1
		mdir, _ := filepath.join({root, mod}, context.temp_allocator)
		pls := files_with_suffix(mdir, {".esp", ".esm", ".esl"}, context.temp_allocator)
		start := len(inputs)
		for pl in pls {read_plugin_into(&inputs, v, mdir, pl)}
		// The whole mod shares one identity (sidecar uuid, else a content hash of the plugins actually
		// read); every plugin it ships interns under it.
		uuid := mod_identity_uuid(mdir, inputs[start:])
		for i in start ..< len(inputs) {mods.formtable_intern(&ft, inputs[i].name, uuid)}
	}
	if len(inputs) == 0 {
		log.errorf("no plugins to load")
		return {}, false
	}
	mods.formtable_save(&ft, ft_path)

	// Publish the total byte count up front so the loading bar has a denominator.
	if progress != nil {
		total := 0
		for inp in inputs {total += len(inp.data)}
		sync.atomic_store(&progress.total, total)
	}

	// slot_of: case-folded plugin filename → stable slot, so resolve_load_order stamps identity slots.
	slot_of := make(map[string]u32, len(inputs), context.temp_allocator)
	for inp in inputs {
		if s, ok := mods.formtable_slot(&ft, inp.name); ok {
			slot_of[strings.to_lower(inp.name, context.temp_allocator)] = s
		}
	}
	order := gamedb.resolve_load_order(inputs[:], context.allocator, slot_of)
	defer delete(order, context.allocator)
	log.infof("gamedb: %d plugin(s) (vanilla base + %d enabled mod[s])", len(order), nmods)
	done: ^int = &progress.done if progress != nil else nil
	db := gamedb.build_plugins(order, context.allocator, done)
	load_race_bounds(&db, v)
	if progress != nil {sync.atomic_store(&progress.done, sync.atomic_load(&progress.total))} // 100%
	return db, true
}

// mount_game_mods builds the VFS for the active profile: enabled mod folders (loose) over vanilla
// Data + the base archives, plus any BSAs shipped inside mod folders. read() returns the first
// loose root that has the file, so the highest-priority source mounts first — MO2 convention is
// lower-in-the-list wins, so mods mount bottom→top, then vanilla Data last. `base` is the exe dir.
mount_game_mods :: proc(src, base: string, profile: ^mods.Profile) -> vfs.VFS {
	v: vfs.VFS
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	root := mods_root(base)
	enabled := mods.profile_enabled_mods(profile, context.temp_allocator)
	// Forced "content mods": <base>/content/* are packaged exactly like a mods/ mod but enabled across
	// ALL profiles as the BASELINE — above vanilla, below every user mod (so user mods override them,
	// uniform pipeline). E.g. content/bethassets = UI assets converted from the user's install. Pull a
	// content mod into mods/ and it behaves identically; it lives in content/ only to be forced.
	cmods := content_mod_dirs(base, context.temp_allocator)

	// Loose precedence (first mounted wins): user mods bottom→top, then the content baseline, then vanilla.
	#reverse for mod in enabled {
		if mod == mods.BASE_MOD {continue}
		mdir, _ := filepath.join({root, mod}, context.temp_allocator)
		vfs.mount_loose(&v, mdir)
	}
	for cm in cmods {
		vfs.mount_loose(&v, cm)
	}
	vfs.mount_loose(&v, data_dir)

	// Archives (later mount wins): vanilla base, then content-baseline .bsa, then user-mod .bsa.
	for name in game_archive_names(data_dir, context.temp_allocator) {
		p, _ := filepath.join({data_dir, name}, context.temp_allocator)
		if !vfs.mount_archive(&v, p) {log.warnf("could not mount %s", p)}
	}
	for cm in cmods {
		for b in files_with_suffix(cm, {".bsa"}, context.temp_allocator) {
			bp, _ := filepath.join({cm, b}, context.temp_allocator)
			_ = vfs.mount_archive(&v, bp)
		}
	}
	for mod in enabled {
		if mod == mods.BASE_MOD {continue}
		mdir, _ := filepath.join({root, mod}, context.temp_allocator)
		for b in files_with_suffix(mdir, {".bsa"}, context.temp_allocator) {
			bp, _ := filepath.join({mdir, b}, context.temp_allocator)
			_ = vfs.mount_archive(&v, bp)
		}
	}
	return v
}

// content_mod_dirs lists the VFS-asset root of each <base>/content/<mod> content mod — its
// `bethassets/` subfolder, which holds assets at Bethesda-relative paths (the mod's `lua/` etc. stay
// out of the VFS namespace). Each is mounted as the forced baseline (see mount_game_mods). Paths
// temp-allocated; only existing bethassets/ dirs are returned.
content_mod_dirs :: proc(base: string, alloc := context.temp_allocator) -> []string {
	content, _ := filepath.join({base, "content"}, alloc)
	infos, err := os.read_all_directory_by_path(content, alloc)
	if err != nil {
		return {}
	}
	out := make([dynamic]string, 0, len(infos), alloc)
	for fi in infos {
		assets, _ := filepath.join({content, fi.name, "bethassets"}, alloc)
		if os.is_dir(assets) {
			append(&out, assets)
		}
	}
	return out[:]
}

// script_dirs lists every mod's scripts/ folder, lowest priority first: the content mods (the
// converted base game's content/basescripts among them) by name, then each enabled user mod in
// profile order. The script loader layers a script's files in this order. Temp-allocated.
script_dirs :: proc(base: string, profile: ^mods.Profile) -> []string {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	content, _ := filepath.join({base, installer.CONTENT_DIR}, context.temp_allocator)
	if infos, err := os.read_all_directory_by_path(content, context.temp_allocator); err == nil {
		slice.sort_by(infos, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
		for fi in infos {
			d, _ := filepath.join({content, fi.name, installer.SCRIPTS_DIR}, context.temp_allocator)
			append(&out, d)
		}
	}
	root := mods_root(base)
	for mod in mods.profile_enabled_mods(profile, context.temp_allocator) {
		if mod == mods.BASE_MOD {continue}
		d, _ := filepath.join({root, mod, installer.SCRIPTS_DIR}, context.temp_allocator)
		append(&out, d)
	}
	return out[:]
}

// Derived_Plugin is one row of the derived plugin load order for the mod-manager's right panel: the
// plugin filename, the mod that provides it, and whether it's a master (esm/esl). Read-only — the
// order follows the mod list (resolve with the mod-list rank).
Derived_Plugin :: struct {
	name:   string,
	source: string, // providing mod (mods.BASE_MOD for vanilla Data)
	master: bool,
}

// derive_plugin_order resolves the active profile's plugin load order WITHOUT building the DB — it
// reads only each plugin's header bytes (for masters) and runs esm.load_order with the mod-list
// rank. Also returns any missing-master dependency failures (the footgun the manager surfaces at
// apply). For the mod-manager display; recomputed when the mod list changes. Both allocated in
// `allocator` (free with free_derived).
derive_plugin_order :: proc(src, base: string, profile: ^mods.Profile, allocator := context.allocator) -> (order: []Derived_Plugin, missing: []gamedb.Missing_Master) {
	data_dir, _ := filepath.join({src, "Data"}, context.temp_allocator)
	root := mods_root(base)

	names := make([dynamic]string, 0, 16, context.temp_allocator)
	mod_of := make([dynamic]string, 0, 16, context.temp_allocator)
	masters := make([dynamic][]string, 0, 16, context.temp_allocator)

	if disc, ok := discover_plugins(src, context.temp_allocator); ok {
		for n in disc {gather_plugin_header(&names, &mod_of, &masters, data_dir, n, mods.BASE_MOD)}
	}
	for mod in mods.profile_enabled_mods(profile, context.temp_allocator) {
		if mod == mods.BASE_MOD {continue}
		mdir, _ := filepath.join({root, mod}, context.temp_allocator)
		for pl in files_with_suffix(mdir, {".esp", ".esm", ".esl"}, context.temp_allocator) {
			gather_plugin_header(&names, &mod_of, &masters, mdir, pl, mod)
		}
	}
	if len(names) == 0 {
		return {}, {}
	}

	missing = gamedb.validate_masters(names[:], masters[:], allocator)

	rank := make(map[string]int, len(names), context.temp_allocator)
	for nm, i in names {rank[strings.to_lower(nm, context.temp_allocator)] = i}
	perm := esm.load_order(names[:], masters[:], context.temp_allocator, rank)

	order = make([]Derived_Plugin, len(perm), allocator)
	for pidx, i in perm {
		lower := strings.to_lower(names[pidx], context.temp_allocator)
		order[i] = Derived_Plugin {
			name   = strings.clone(names[pidx], allocator),
			source = strings.clone(mod_of[pidx], allocator),
			master = strings.has_suffix(lower, ".esm") || strings.has_suffix(lower, ".esl"),
		}
	}
	return order, missing
}

// gather_plugin_header reads <dir>/<fname>'s header and appends its name, providing mod, and master
// list to the parallel slices. Silently skips files that don't open or whose header won't parse.
@(private = "file")
gather_plugin_header :: proc(names, mod_of: ^[dynamic]string, masters: ^[dynamic][]string, dir, fname, mod: string) {
	p, _ := filepath.join({dir, fname}, context.temp_allocator)
	hdr := read_header_chunk(p)
	if hdr == nil {
		return
	}
	h, ok := esm.parse_header(hdr, context.temp_allocator)
	if !ok {
		return
	}
	append(names, fname)
	append(mod_of, mod)
	append(masters, h.masters)
}

// read_header_chunk reads the first 256 KiB of `path` — far more than any plugin's TES4 header
// needs, and avoids loading a 250 MB master just to learn its masters. Temp-allocated; nil on error.
@(private = "file")
read_header_chunk :: proc(path: string) -> []u8 {
	h, err := os.open(path)
	if err != nil {
		return nil
	}
	defer os.close(h)
	buf := make([]u8, 256 * 1024, context.temp_allocator)
	n, rerr := os.read(h, buf)
	if rerr != nil || n <= 0 {
		return nil
	}
	return buf[:n]
}

// read_plugin_into reads <dir>/<fname> and appends it as a Plugin_Input (bytes owned by the
// caller's allocator; freed after build). A read failure is logged and skipped.
//
// The plugin's localized tables (Strings/<Plugin>_<Lang>.STRINGS + .DLSTRINGS) resolve through
// the VFS `v`, so every shipping layout works uniformly: loose Data/Strings (LE-era + mods,
// loose wins), the base game's tables inside "Skyrim - Interface.bsa" (both editions), and each
// Creation Club plugin's tables inside its own cc*.bsa (mounted by game_archive_names). Loaded
// unconditionally — build_plugins only consults them when the plugin's TES4 localized flag is
// set (nil = names come from inline FULL). English only for now.
@(private = "file")
read_plugin_into :: proc(inputs: ^[dynamic]gamedb.Plugin_Input, v: ^vfs.VFS, dir, fname: string) {
	p, _ := filepath.join({dir, fname}, context.temp_allocator)
	bytes, rerr := os.read_entire_file(p, context.allocator)
	if rerr != nil {
		log.warnf("could not read plugin %s — skipping", p)
		return
	}
	stem := filepath.stem(fname)
	spath := strings.concatenate({"Strings/", stem, "_English.STRINGS"}, context.temp_allocator)
	sbytes, _ := vfs.read(v, spath, context.allocator) // nil on absence (non-localized plugin)
	// Long-text table (.DLSTRINGS): quest-log CNAM + book DESC.
	dlpath := strings.concatenate({"Strings/", stem, "_English.DLSTRINGS"}, context.temp_allocator)
	dlbytes, _ := vfs.read(v, dlpath, context.allocator) // nil on absence
	ilpath := strings.concatenate({"Strings/", stem, "_English.ILSTRINGS"}, context.temp_allocator)
	ilbytes, _ := vfs.read(v, ilpath, context.allocator) // dialogue text; nil on absence
	append(
		inputs,
		gamedb.Plugin_Input {
			name = strings.clone(fname),
			data = bytes,
			strings_data = sbytes,
			dlstrings_data = dlbytes,
			ilstrings_data = ilbytes,
		},
	)
}

// files_with_suffix lists files in `dir` whose lower-cased name ends with any of `suffixes`. Names
// are allocated in `allocator`. A missing/unreadable dir → empty.
@(private = "file")
files_with_suffix :: proc(dir: string, suffixes: []string, allocator := context.allocator) -> []string {
	infos, derr := os.read_all_directory_by_path(dir, context.temp_allocator)
	if derr != nil {
		return {}
	}
	out := make([dynamic]string, 0, 4, allocator)
	for fi in infos {
		lower := strings.to_lower(fi.name, context.temp_allocator)
		for s in suffixes {
			if strings.has_suffix(lower, s) {
				append(&out, strings.clone(fi.name, allocator))
				break
			}
		}
	}
	return out[:]
}

// stream_spawn picks a camera start over an exterior grid cell: centred on the cell
// in XY, raised above its statics' mean height. Used to drop the player into a
// streamed worldspace (e.g. Riverwood in Tamriel) before terrain exists to stand on.
stream_spawn :: proc(db: ^gamedb.DB, world_fid: Form_ID, gx, gy: i32) -> (pos: smath.Vec3, ok: bool) {
	cid, cok := gamedb.cell_at(db, world_fid, gx, gy)
	if !cok {
		return {}, false
	}
	sum_z, n := f32(0), 0
	for r in gamedb.refs_of(db, cid) {
		if !r.disabled {
			sum_z += r.pos.z
			n += 1
		}
	}
	ground := sum_z / f32(max(n, 1))
	return {(f32(gx) + 0.5) * 4096, (f32(gy) + 0.5) * 4096, ground + 900}, true
}

// --- Inter-cell traversal (base game locomotion via NORMAL load doors) ---
//
// One reusable, mode-aware core for full game traversal: walk the streamed exterior,
// cross a load door → its interior (the exterior stays loaded but shrinks to a small
// fixed window), interior→interior, and return → the exterior at the correct spot.
// This is plain Skyrim door traversal — NOT the open-interiors portal experiment.
//
// A load door is symmetric (its XTEL names a partner door), so traversal collapses to
// ONE op — go_through — that resolves the destination cell and swaps the active scene
// to match, branching on interior vs exterior. The streamer is the one piece that must
// be managed: its worker thread holds the exterior ^Scene, so scene_destroy would fight
// it. We never destroy the exterior scene; we PAUSE the streamer (+ collapse its window)
// on interior entry and resume it on return.

// Door activation ranges. A manual door (real mesh) arms a "Go Through" prompt within DOOR_RANGE (press E). An auto-
// load door (an invisible AutoLoadMarker — cave/dungeon entrances) fires on PROXIMITY within
// the tighter AUTO_DOOR_RANGE, no key. After any transition, auto-firing is suppressed until
// the player walks AUTO_REARM away from the arrival spot — else the partner door (right where
// you land) would instantly teleport you back in a loop.
DOOR_RANGE :: f32(600)
AUTO_DOOR_RANGE :: f32(300)
AUTO_REARM :: f32(500)

Traversal_Mode :: enum {
	Exterior, // living in the streamed exterior scene
	Interior, // living in a synchronously-loaded interior cell
}

// Door_Ref is one load door, indexed from gamedb (NOT from renderable instances — so it
// includes invisible AutoLoadMarker doors, which build_chunk skips as markers). `pos` is the
// door's world position (proximity prompt + range); the rest is its XTEL (destination door +
// the arrival marker on the far side). `auto` = an auto-load (proximity-entered) door.
Door_Ref :: struct {
	self:    Form_ID, // this door's own formID (arrival re-trigger guard)
	pos:     smath.Vec3,
	tp_door: Form_ID,
	tp_pos:  smath.Vec3,
	tp_rot:  smath.Vec3,
	auto:    bool,
}

// Door_Hit is the nearest activatable load door to the player this frame. ok=false when none
// is within DOOR_RANGE.
Door_Hit :: struct {
	door_pos: smath.Vec3, // for the prompt + range test
	tp_door:  Form_ID,
	tp_pos:   smath.Vec3,
	tp_rot:   smath.Vec3,
	auto:     bool,
	dist:     f32,
	ok:       bool,
}

// Traversal owns which scene the player currently inhabits and manages the exterior
// streamer's lifecycle across door transitions (interior load, interior↔interior, return to
// the exterior, and cross-worldspace city gates). It borrows the exterior scene + streamer
// (always alive) and holds the interior scene when one is loaded.
Traversal :: struct {
	mode:        Traversal_Mode,
	ext_scene:   ^world.Scene, // streamed exterior (borrowed; never destroyed here)
	// (hole traversal-stream-control :tags (threading world) :sev gap) traversal holds the streamer and both scenes: it retargets the streamer, points the sim's space at a new worldspace and loads interiors on main with get_model. Wanted: the sim sends a stream request and gets a 'bubble ready' reply.
	st:          ^world.Streamer, // exterior streamer (borrowed)
	db:          ^gamedb.DB,
	v:           ^vfs.VFS,
	r:           ^render.Renderer,
	ws:          ^worldstate.World_State, // world-state overlay (borrowed); applied to interiors (Phase 3c)
	interior:    world.Scene, // valid only while mode == .Interior
	int_phys:    physics.World, // the active interior's collision world (reused across interiors)
	int_space:   world.Space, // the active interior's live cells and bodies, in int_phys (reused too)
	int_phys_ok: bool, // false if Jolt failed to make the interior world (interiors then have no collision)
	ext_doors:   [dynamic]Door_Ref, // current exterior worldspace's load doors (rebuilt on retarget)
	int_doors:   [dynamic]Door_Ref, // current interior cell's load doors (rebuilt on entry)
	arrival_pos: smath.Vec3, // where the last transition landed (auto-fire suppression anchor)
	has_arrival: bool, // suppress auto-firing until the player walks AUTO_REARM from arrival_pos
	cur_int_cell: Form_ID, // the interior cell currently loaded (mode == .Interior) — for in-place reload
	// Load-screen hook: a synchronous interior load reports its per-instance decode fraction here so the
	// load screen shows real progress instead of a frame-long freeze (wired by the app after loadui exists;
	// nil = load silently, as before). `progress_user` is the opaque app pointer (the ^Game).
	progress:      world.Cell_Load_Progress,
	progress_user: rawptr,
}

// Traversal_Kind is what a go_through transition did — so the caller (frame_traversal) knows whether to
// run a streamer-driven load screen (a city gate) after the camera moves. Interior loads block + show
// their own load screen inside go_through; exterior returns are instant (kept-warm window).
Traversal_Kind :: enum {
	None,     // no transition (unresolved destination)
	Stay,     // already in the destination interior (instant)
	Interior, // entered an interior cell (load screen ran inside go_through)
	City,     // crossed to a different worldspace (caller runs the streamer load screen)
	Jump,     // moved far within the exterior (caller runs the streamer load screen)
	Exit,     // returned to the same-worldspace exterior (instant)
}

traversal_init :: proc(
	t: ^Traversal,
	ext_scene: ^world.Scene,
	st: ^world.Streamer,
	db: ^gamedb.DB,
	v: ^vfs.VFS,
	r: ^render.Renderer,
	ws: ^worldstate.World_State,
) {
	t^ = Traversal {
		mode      = .Exterior,
		ext_scene = ext_scene,
		st        = st,
		db        = db,
		v         = v,
		r         = r,
		ws        = ws,
		ext_doors = make([dynamic]Door_Ref),
		int_doors = make([dynamic]Door_Ref),
	}
	// One reusable interior collision world: each interior's bodies are built into it on entry and
	// removed (scene_destroy) on exit, so we don't leak a Jolt filter-table set per door (see
	// physics.world_destroy). nil-safe — a creation failure just leaves interiors collision-free.
	t.int_phys, t.int_phys_ok = physics.world_create()
	if t.int_phys_ok {world.space_init(&t.int_space, &t.int_phys, ext_scene.collisions, ws, dynamic_clutter = true)}
	if !t.int_phys_ok {
		log.warn("traversal: interior physics world creation failed — interiors will have no collision")
	}
	rebuild_ext_doors(t)
}

// traversal_set_progress wires the load-screen callback used during synchronous interior loads. Called
// by the app once the load screen (loadui) exists; `user` is the ^Game the callback casts back to.
traversal_set_progress :: proc(t: ^Traversal, cb: world.Cell_Load_Progress, user: rawptr) {
	t.progress = cb
	t.progress_user = user
}

traversal_destroy :: proc(t: ^Traversal) {
	drop_interior(t) // the interior's bodies leave int_phys before it goes
	world.space_destroy(&t.int_space)
	if t.int_phys_ok {
		physics.world_destroy(&t.int_phys)
	}
	delete(t.ext_doors)
	delete(t.int_doors)
	t^ = {}
}

// gather_doors fills `out` with every load door across `cells` (a worldspace's cell set, or a
// single interior cell). Built straight from gamedb refs — so invisible AutoLoadMarker doors
// (which build_chunk drops as markers) are included. auto = the door's mesh is a marker.
@(private = "file")
gather_doors :: proc(t: ^Traversal, cells: []Form_ID, out: ^[dynamic]Door_Ref) {
	clear(out)
	for cid in cells {
		for r in gamedb.refs_of(t.db, cid) {
			if !r.has_tp || r.disabled || r.base == formid.PRISON_MARKER {
				continue
			}
			model, _ := gamedb.model_of(t.db, r.base)
			append(
				out,
				Door_Ref {
					self = r.form_id,
					pos = r.pos,
					tp_door = r.teleport.door,
					tp_pos = r.teleport.pos,
					tp_rot = r.teleport.rot,
					auto = world.is_marker_path(model),
				},
			)
		}
	}
}

// rebuild_ext_doors indexes the streamer's CURRENT worldspace's load doors (the persistent
// cell — among all its cells — carries the exterior doors, absent from the streamed grid
// chunks). Called at init and on each cross-worldspace retarget.
@(private = "file")
rebuild_ext_doors :: proc(t: ^Traversal) {
	clear(&t.ext_doors)
	if t.st.world_fid == 0 {
		return // no streamed worldspace (e.g. worldspace not found)
	}
	gather_doors(t, gamedb.cells_of(t.db, t.st.world_fid), &t.ext_doors)
	log.infof("traversal: indexed %d load doors in worldspace 0x%08X", len(t.ext_doors), t.st.world_fid)
}

// traversal_scene returns the scene the camera + picker currently operate in: the loaded
// interior cell when inside, the streamed exterior otherwise.
traversal_scene :: proc(t: ^Traversal) -> ^world.Scene {
	if t.mode == .Interior {
		return &t.interior
	}
	return t.ext_scene
}

// traversal_arrival_update clears the auto-fire suppression once the player has walked clear
// of the last transition's landing spot (so re-approaching an auto door fires it again).
traversal_arrival_update :: proc(t: ^Traversal, cam_pos: smath.Vec3) {
	if t.has_arrival && smath.length3(cam_pos - t.arrival_pos) > AUTO_REARM {
		t.has_arrival = false
	}
}

// traversal_nearest_door finds the nearest activatable load door to `pos` — scanning the
// interior cell's doors when inside, the worldspace's doors otherwise (both gamedb-sourced, so
// invisible auto-load doors are found). ok is set only within DOOR_RANGE.
traversal_nearest_door :: proc(t: ^Traversal, pos: smath.Vec3) -> Door_Hit {
	doors := t.int_doors if t.mode == .Interior else t.ext_doors
	best := Door_Hit{dist = max(f32)}
	for d in doors {
		if dist := smath.length3(d.pos - pos); dist < best.dist {
			best = {
				door_pos = d.pos,
				tp_door  = d.tp_door,
				tp_pos   = d.tp_pos,
				tp_rot   = d.tp_rot,
				auto     = d.auto,
				dist     = dist,
			}
		}
	}
	best.ok = best.dist <= DOOR_RANGE
	return best
}

// door_dest_label resolves a load door's destination into a short prompt label, or "" when it
// can't be resolved. Cross-worldspace exteriors now show the destination worldspace's name.
door_dest_label :: proc(t: ^Traversal, tp_door: Form_ID) -> string {
	dref, ok := gamedb.ref_by_formid(t.db, tp_door)
	if !ok {
		return ""
	}
	dcell, cok := gamedb.cell_by_formid(t.db, dref.cell_form_id)
	if !cok {
		return ""
	}
	// Prefer the cell's FULL display name ("Riverwood Trader", "Sleeping Giant Inn") — what the
	// activation prompt should read — over the editor id ("RiverwoodTraderInterior").
	if full := gamedb.name_of(t.db, dcell.form_id); full != "" {
		return full
	}
	if dcell.editor_id != "" {
		return dcell.editor_id
	}
	if dcell.interior {
		return "(interior)"
	}
	if w := gamedb.world_editor_id(t.db, dcell.world_form_id); w != "" {
		return w // exterior worldspace name (e.g. a city gate → "WhiterunWorld")
	}
	return "(exterior)"
}

// go_through follows the activated load door's XTEL to its destination cell and swaps the
// active scene to match, returning the player placement at the arrival marker. The door's
// teleport marker (designer-placed) is the landing spot+facing in the destination cell — far
// better than guessing from the dest door mesh. kind=.None (placement unused) only if the
// destination is unresolved.
go_through :: proc(t: ^Traversal, h: Door_Hit) -> (feet: smath.Vec3, yaw: f32, kind: Traversal_Kind) {
	if !h.ok {
		return {}, 0, .None
	}
	dref, dok := gamedb.ref_by_formid(t.db, h.tp_door)
	if !dok {
		log.warnf("traversal: door dest 0x%08X not found — staying put", h.tp_door)
		return {}, 0, .None
	}
	// The XTEL marker is in interior-local coords for an interior dest, world coords otherwise.
	feet, yaw = h.tp_pos, h.tp_rot.z
	kind = traversal_go_to(t, dref.cell_form_id, feet)
	if kind == .None {
		return {}, 0, .None
	}
	// Anchor auto-fire suppression at the landing spot so the partner door (right here) doesn't
	// immediately teleport us back; it re-arms once we walk AUTO_REARM away.
	t.arrival_pos = feet
	t.has_arrival = true
	log.infof("traversal: entered cell 0x%08X via door 0x%08X", dref.cell_form_id, h.tp_door)
	return feet, yaw, kind
}

// traversal_go_to makes `cell` the active scene for a player arriving at `feet`: an interior loads
// (unless it is the one loaded), another worldspace retargets the streamer, and the exterior
// resumes streaming at `feet`, with a full load when the landing cell is not resident.
// .None when the cell is unknown.
traversal_go_to :: proc(t: ^Traversal, cell: Form_ID, feet: smath.Vec3) -> Traversal_Kind {
	c, ok := gamedb.cell_by_formid(t.db, cell)
	if !ok {
		log.warnf("traversal: cell 0x%08X unknown — staying put", cell)
		return .None
	}
	switch {
	case c.interior && t.mode == .Interior && t.cur_int_cell == c.form_id:
		return .Stay
	case c.interior:
		enter_interior(t, c.form_id) // blocks + shows the load screen via t.progress
		return .Interior
	case c.world_form_id != t.st.world_fid:
		retarget_exterior(t, c.world_form_id)
		return .City
	case t.mode == .Exterior && !world.window_ready(t.ext_scene.space, t.db, feet):
		return .Jump
	}
	exit_to_exterior(t) // same-worldspace exterior (interior return / wilderness door)
	return .Exit
}

// enter_interior swaps to a freshly-loaded interior cell. The exterior's live cells stay as they are
// (the sim moves its window only outside), so a return is instant. The new cell's own doors are
// indexed for proximity.
@(private = "file")
enter_interior :: proc(t: ^Traversal, cell_id: Form_ID) {
	drop_interior(t) // interior → interior swap
	t.interior = world.scene_init(t.r, t.v, t.ext_scene.collisions)
	t.interior.pretty = t.ext_scene.pretty // inherit --pretty from the exterior we branched from
	if t.int_phys_ok {t.interior.space = &t.int_space} // the interior's bhk* collision builds into the reusable world
	world.load_cell(&t.interior, t.db, cell_id, t.progress, t.progress_user) // reports decode progress to the load screen
	// Build all of the interior's static collision NOW (load_cell resolved every model
	// synchronously, so sync_physics can cook them immediately): the player lands on a solid
	// floor on arrival instead of falling through for the first few budgeted frames.
	if t.int_phys_ok {
		for world.sync_physics(&t.int_space) > 0 {}
		physics.optimize_broadphase(&t.int_phys)
		nbodies := 0
		for _, &c in t.int_space.cells {
			nbodies += len(c.bodies)
		}
		log.infof("traversal: interior 0x%08X collision built — %d static bodies", cell_id, nbodies)
	}
	gather_doors(t, {cell_id}, &t.int_doors)
	t.cur_int_cell = cell_id
	t.mode = .Interior
	if t.progress != nil {
		t.progress(t.progress_user, 1) // final frame: bar reaches 100% before gameplay resumes
	}
}

// drop_interior frees the loaded interior, if one is: its scene and its live cells.
@(private = "file")
drop_interior :: proc(t: ^Traversal) {
	if t.mode != .Interior {return}
	world.scene_destroy(&t.interior)
	world.space_clear(&t.int_space)
	t.interior = {}
}

// traversal_reload rebuilds the current interior cell in place (an interior→interior swap to the
// SAME cell) so a just-loaded overlay (F9 quickload) is re-applied: moved clutter snaps to the
// loaded save's positions and its dynamic bodies rebuild there. No-op outside an interior.
traversal_reload :: proc(t: ^Traversal) {
	if t.mode == .Interior {
		enter_interior(t, t.cur_int_cell)
	}
}

// exit_to_exterior tears down the interior. The sim's next tick moves its window to the arrival cell.
@(private = "file")
exit_to_exterior :: proc(t: ^Traversal) {
	drop_interior(t)
	t.mode = .Exterior
}

// retarget_exterior crosses to a DIFFERENT exterior worldspace (a city gate): a full swap, like
// Skyrim's city load screen. The sim retires every live cell of the old worldspace, and the
// per-worldspace far-terrain backdrop + door index are rebuilt. Models stay cached (shared meshes
// carry over). The load screen then fills the arrival bubble.
@(private = "file")
retarget_exterior :: proc(t: ^Traversal, world_fid: Form_ID) {
	drop_interior(t)
	sp := t.ext_scene.space
	world.set_world(sp, t.db, world_fid, sp.window.radius)
	world.stream_retarget(t.st, world_fid)
	world.release_terrain_field(t.ext_scene)
	world.build_terrain_field(t.ext_scene, t.db, world_fid)
	rebuild_ext_doors(t)
	t.mode = .Exterior
	log.infof("traversal: crossed to worldspace 0x%08X (%s)", world_fid, gamedb.world_editor_id(t.db, world_fid))
}
