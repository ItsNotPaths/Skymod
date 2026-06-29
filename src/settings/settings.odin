package settings

// Settings file (boot config). A plain "key = value" text file that lives beside
// the executable — settings.txt — so the user can edit it by hand. The first key
// is `source_game`: the path to their own Skyrim install, set once so the
// installer never has to ask for it again.
//
// load() reads the file (creating nothing), then fills in any DEFAULTS key that
// the file is missing — so a release that ships an older settings.txt silently
// gains new keys without clobbering the user's existing values. release.sh does
// the same merge at build time; this is the runtime safety net.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

FILE_NAME :: "settings.txt"

HEADER ::
	"# SkyMod settings — \"key = value\" per line; '#' starts a comment.\n" +
	"# Your edits are preserved; new keys are appended automatically.\n\n"

// Default keys and values, in the order a fresh file is written. source_game is
// FIRST on purpose — it's the one line you usually edit, so it sits at the top.
Default :: struct {
	key:   string,
	value: string,
}
DEFAULTS := [?]Default {
	{"source_game", ""},
	{"persist_logs", "false"},
	// Pretty mode: hide the white, untextured editor-marker placeholders (effect placements,
	// bird/patrol routes, X markers) that slip past the name-based filter. Also set with --pretty.
	{"pretty", "false"},
	// Exterior render distance as the streaming window half-size in cells: the
	// loaded square is (2·render_distance + 1)² cells around the player. Higher =
	// see farther, more to stream/draw. LOD distance settings will join this when
	// terrain/object LOD lands.
	{"render_distance", "2"},
	// Grass draw distance in world units (grass is dense/expensive, so much shorter
	// than render_distance). Cells beyond this aren't drawn with grass. 0 disables grass.
	{"grass_distance", "8192"},
	// Distant terrain LOD radius in cells (≥ render_distance). Cells between
	// render_distance and this load as terrain-only, downsampled coarser with distance,
	// so the landscape recedes into the distance instead of ending at the window edge.
	{"lod_distance", "24"},
	// Distant-object LOD radius in cells (≤ lod_distance). Larger statics within this
	// range render as instanced coarse meshes; beyond it the LOD rings are terrain-only.
	// Each cell adds draws ≈ its distinct-model count, so raise this gradually.
	{"object_lod_distance", "5"},
	// Baked distant-object LOD band: which of Skyrim's 4 MNAM LOD meshes every distant static
	// uses. 0 = LOD4 (sharpest, most verts/RAM), 1 = LOD8, 2 = LOD16, 3 = LOD32 (coarsest,
	// leanest). The whole worldspace's distant objects are merged per quad once at load.
	{"object_lod_band", "1"},
	// Baked-object merge-quad size in cells. Distant objects merge per quad into one buffer, so
	// SMALLER = cleaner near transition (a quad fully inside the full-detail bubble is suppressed,
	// avoiding double-draw — needs quad ≲ render_distance to engage) but MORE draw calls; LARGER =
	// fewer draws but the near transition double-draws until you raise render_distance.
	{"object_lod_quad", "8"},
	// EXPERIMENTAL: inline interior cells into the exterior worldspace so you can walk
	// through a load door with no load screen ("Open Cities"-style, any interior). Interiors
	// are placed by their door alignment and stream in/out by proximity. May clip/overlap —
	// off by default; normal load-screen interior loading remains the supported path.
	{"experimental_open_interiors", "false"},
	// How close (world units) the player must get to a load door before its interior is
	// inlined (and how far before it unloads, plus a hysteresis margin). Only used when
	// experimental_open_interiors is on.
	{"interior_load_distance", "2048"},
	// Active lighting profile at boot: a baked name ("vanilla"/"realistic") or a sidecar
	// folder under profiles/. Edit + save live in the in-game Lighting panel.
	{"lighting_profile", "vanilla"},
	// Sun-shadow draw distance in world units (cascaded shadow maps cover [near, this]). 0
	// disables shadows. Shorter = crisper near shadows (cascades pack closer); longer = shadows
	// farther out but coarser. Strength/softness/bias are per lighting profile.
	{"shadow_distance", "20000"},
}

// Config is an ordered key/value store: `keys` preserves write order, `vals` maps
// key -> value. All strings are heap-owned; call destroy() to free them.
Config :: struct {
	path: string,
	keys: [dynamic]string,
	vals: map[string]string,
}

// load reads <base>/settings.txt (if present) and returns a Config with every
// DEFAULTS key guaranteed present. It does not write the file — call save() for
// that (boot does so once it has captured a value worth persisting).
load :: proc(base: string, allocator := context.allocator) -> Config {
	context.allocator = allocator
	cfg: Config
	cfg.path, _ = filepath.join({base, FILE_NAME})
	cfg.vals = make(map[string]string)

	if data, err := os.read_entire_file(cfg.path, context.temp_allocator); err == nil {
		it := string(data)
		for raw in strings.split_lines_iterator(&it) {
			line := strings.trim_space(raw)
			if line == "" || line[0] == '#' {
				continue
			}
			eq := strings.index_byte(line, '=')
			if eq < 0 {
				continue
			}
			key := strings.trim_space(line[:eq])
			val := strings.trim_space(line[eq + 1:])
			if key != "" {
				put(&cfg, key, val)
			}
		}
	}

	// Backfill anything the file didn't have, in DEFAULTS order.
	for d in DEFAULTS {
		if _, has := cfg.vals[d.key]; !has {
			put(&cfg, d.key, d.value)
		}
	}
	return cfg
}

// get returns the value for key, or "" if absent.
get :: proc(cfg: ^Config, key: string) -> string {
	return cfg.vals[key] or_else ""
}

// get_bool interprets the value as a boolean (true/1/yes/on, case-insensitive).
get_bool :: proc(cfg: ^Config, key: string) -> bool {
	v := get(cfg, key)
	return strings.equal_fold(v, "true") || v == "1" || strings.equal_fold(v, "yes") || strings.equal_fold(v, "on")
}

// get_int interprets the value as a base-10 integer, returning `fallback` if the key
// is absent or unparseable.
get_int :: proc(cfg: ^Config, key: string, fallback: int) -> int {
	v := get(cfg, key)
	if n, ok := strconv.parse_int(v, 10); ok {
		return n
	}
	return fallback
}

// get_float returns a key parsed as f32, or `fallback` if absent/unparseable. Used for the
// optional (commented-out by default) LOD falloff-tuning keys.
get_float :: proc(cfg: ^Config, key: string, fallback: f32) -> f32 {
	v := get(cfg, key)
	if n, ok := strconv.parse_f32(v); ok {
		return n
	}
	return fallback
}

// set updates (or adds) a key. Persist with save().
set :: proc(cfg: ^Config, key, val: string) {
	put(cfg, key, val)
}

// save writes the config back to settings.txt, keys in order, under a fixed
// header. Hand-written comments are not round-tripped — this is only called when
// the app itself changes a value (e.g. it just learned the source path).
save :: proc(cfg: ^Config) -> bool {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, HEADER)
	for k in cfg.keys {
		strings.write_string(&b, k)
		strings.write_string(&b, " = ")
		strings.write_string(&b, cfg.vals[k])
		strings.write_byte(&b, '\n')
	}
	if err := os.write_entire_file(cfg.path, transmute([]byte)strings.to_string(b)); err != nil {
		log.errorf("settings: could not write %q: %v", cfg.path, err)
		return false
	}
	return true
}

destroy :: proc(cfg: ^Config) {
	for k in cfg.keys {
		delete(cfg.vals[k])
		delete(k)
	}
	delete(cfg.keys)
	delete(cfg.vals)
	delete(cfg.path)
}

// put inserts or replaces key, cloning both strings into the Config's ownership
// and tracking insertion order for new keys.
@(private)
put :: proc(cfg: ^Config, key, val: string) {
	if _, has := cfg.vals[key]; has {
		delete(cfg.vals[key])
		cfg.vals[key] = strings.clone(val)
	} else {
		k := strings.clone(key)
		append(&cfg.keys, k)
		cfg.vals[k] = strings.clone(val)
	}
}
