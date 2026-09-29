package mods

// A mod's identity sidecar (docs/mods.md "Two tiers"): mods/<name>/skymod/mod.txt carries the
// author-stable UUID + metadata that make the mod's forms portable across installs — the save bridge
// keys on it, and it names the mod's dependencies. `skymod/` is the shared per-mod metadata seam.
// A mod WITHOUT a sidecar falls
// back to a content hash of its plugin bytes: deterministic and stable while the files are unchanged,
// so legacy mods still get a usable (if non-authoritative, install-local-ish) identity.
//
// mod.txt format (key = value lines, '#' comments — the settings/profile idiom):
//   uuid     = 5f3c9a...                     # author-generated, stable across versions
//   name     = Sword of the Ancient Tongues  # display
//   version  = 1.2.0
//   requires = Dawnguard.esm, Some Other Mod # masters and/or mod names this depends on

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"

SIDECAR_SUBDIR :: "skymod"
SIDECAR_FILE :: "mod.txt"

// Mod_Identity is a mod's parsed sidecar. All strings are owned by the passed allocator.
Mod_Identity :: struct {
	uuid:     string,
	name:     string,
	version:  string,
	requires: []string, // dependency names (master filenames and/or mod names); each element owned
}

mod_identity_destroy :: proc(id: ^Mod_Identity, allocator := context.allocator) {
	delete(id.uuid, allocator)
	delete(id.name, allocator)
	delete(id.version, allocator)
	for r in id.requires {delete(r, allocator)}
	delete(id.requires, allocator)
}

// read_sidecar parses mods/<name>/skymod/mod.txt into a Mod_Identity. ok=false if the file is absent
// (caller falls back to content_hash_identity) or carries no `uuid` (an incomplete sidecar isn't an
// identity). Strings are cloned into `allocator`.
read_sidecar :: proc(mod_dir: string, allocator := context.allocator) -> (id: Mod_Identity, ok: bool) {
	path, _ := filepath.join({mod_dir, SIDECAR_SUBDIR, SIDECAR_FILE}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return {}, false}
	it := string(data)
	for raw in strings.split_lines_iterator(&it) {
		s := strings.trim_space(raw)
		if s == "" || s[0] == '#' {continue}
		eq := strings.index_byte(s, '=')
		if eq < 0 {continue}
		key := strings.to_lower(strings.trim_space(s[:eq]), context.temp_allocator)
		val := strings.trim_space(s[eq + 1:])
		switch key {
		case "uuid":
			id.uuid = strings.clone(val, allocator)
		case "name":
			id.name = strings.clone(val, allocator)
		case "version":
			id.version = strings.clone(val, allocator)
		case "requires":
			id.requires = split_requires(val, allocator)
		}
	}
	if id.uuid == "" { // an incomplete sidecar is not a usable identity
		mod_identity_destroy(&id, allocator)
		return {}, false
	}
	return id, true
}

// content_hash_identity derives a deterministic synthetic uuid ("ch-<hex>") from a mod's plugin bytes
// — the fallback identity for a mod that ships no sidecar. Stable while the plugins are unchanged;
// order-independent (each plugin's fnv64a is XOR-folded, with its length mixed in so two byte-equal
// plugins don't cancel) so the order the loader lists files in doesn't perturb it.
content_hash_identity :: proc(plugin_bytes: [][]u8, allocator := context.allocator) -> string {
	acc: u64 = 0xcbf2_9ce4_8422_2325
	for b in plugin_bytes {
		acc ~= hash.fnv64a(b) + u64(len(b))
	}
	return fmt.aprintf("ch-%016x", acc, allocator = allocator)
}

// split_requires turns a "requires =" value into owned dependency tokens, split on COMMAS (so
// multi-word mod folder names like "Sword of the Ancient Tongues" survive) and trimmed; empties are
// dropped. Master filenames (no spaces) and mod names both work: "Dawnguard.esm, Some Other Mod".
@(private)
split_requires :: proc(val: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, allocator)
	for part in strings.split(val, ",", context.temp_allocator) {
		p := strings.trim_space(part)
		if p != "" {append(&out, strings.clone(p, allocator))}
	}
	return out[:]
}
