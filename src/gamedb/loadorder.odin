package gamedb

// Multi-master load order + FormID resolution (the identity substrate). A plugin's
// records and refs use plugin-LOCAL FormIDs whose high byte indexes its [masters…, self]
// list; to merge several plugins into one DB they must be rewritten into a shared GLOBAL
// space keyed by load-order position. resolve_load_order topo-sorts the plugins and builds
// each a Form_Map (esm.remap_form); build_plugins then walks them in order, remapping every
// FormID and letting a later plugin override an earlier one (last write wins).

import "core:log"
import "core:strings"
import "../formats/esm"

// Plugin_Input is one plugin file handed to the loader: its filename (drives master
// resolution + load order) and its raw bytes (borrowed — the DB clones what it keeps, so
// the caller may free the bytes after build_plugins returns).
Plugin_Input :: struct {
	name:         string,
	data:         []u8,
	strings_data: []u8, // loose <Plugin>_<Lang>.STRINGS bytes for a localized plugin (nil = none/inline); borrowed
}

// Loaded_Plugin is a Plugin_Input resolved into the global load order: its global index
// (the high byte of the FormIDs it defines) and the Form_Map that rewrites its local
// FormIDs into global space. Produced by resolve_load_order, consumed by build_plugins.
Loaded_Plugin :: struct {
	name:         string,
	data:         []u8,
	strings_data: []u8, // carried from Plugin_Input (localized names table bytes; nil = none)
	localized:    bool, // TES4 flag 0x80 — resolved from the header at build time
	index:        int,
	fm:           esm.Form_Map,
}

// resolve_load_order reads each plugin's TES4 master list, topo-sorts the set into Skyrim
// load order (esm.load_order), and builds each plugin's Form_Map (local master index ->
// the master's global index; the self slot -> the plugin's own global index; everything
// else identity). The returned slice is in load order, allocated in `allocator`; free it
// with delete(). Header masters are read into the temp allocator.
// `slot_of` (case-folded filename → stable slot) decouples IDENTITY from load order: when supplied
// (by the manager's form-table), a plugin's forms carry its stable slot instead of its load-order
// index, so reordering mods never renumbers a form (saves stay portable — docs/mods.md "Two tiers").
// nil ⇒ the placeholder behaviour (slot == load-order index) for the single-file/synthetic paths.
// Override PRECEDENCE is unaffected either way — it's the position in the returned (load-order) slice.
resolve_load_order :: proc(inputs: []Plugin_Input, allocator := context.allocator, slot_of: map[string]u32 = nil) -> []Loaded_Plugin {
	n := len(inputs)
	names := make([]string, n, context.temp_allocator)
	masters := make([][]string, n, context.temp_allocator)
	localized := make([]bool, n, context.temp_allocator)
	for inp, i in inputs {
		names[i] = inp.name
		if h, ok := esm.parse_header(inp.data, context.temp_allocator); ok {
			masters[i] = h.masters
			localized[i] = h.localized
		}
	}
	// Input order is the tie-break rank: passing plugins in mod-list order makes the resolved load
	// order follow the mod order (among non-official plugins; masters + official order still win).
	rank := make(map[string]int, n, context.temp_allocator)
	for nm, i in names {
		rank[strings.to_lower(nm, context.temp_allocator)] = i
	}
	perm := esm.load_order(names, masters, context.temp_allocator, rank)

	gindex := make(map[string]int, n, context.temp_allocator) // lower(name) -> global index
	for p, gi in perm {
		gindex[strings.to_lower(names[p], context.temp_allocator)] = gi
	}

	out := make([]Loaded_Plugin, n, allocator)
	for p, gi in perm {
		lp := Loaded_Plugin {
			name         = inputs[p].name,
			data         = inputs[p].data,
			strings_data = inputs[p].strings_data,
			localized    = localized[p],
			index        = gi,
		}
		for b in 0 ..< 256 {
			lp.fm.slot[b] = u32(b) // identity default (unused high bytes pass through)
		}
		// slot_for maps a plugin name to its GLOBAL slot: the form-table's stable slot when a slot_of
		// is supplied, else the load-order index (the placeholder). ok=false ⇒ unknown plugin.
		slot_for := proc(slot_of: map[string]u32, gindex: map[string]int, name: string) -> (u32, bool) {
			key := strings.to_lower(name, context.temp_allocator)
			if slot_of != nil {
				s, ok := slot_of[key]
				return s, ok
			}
			g, ok := gindex[key]
			return u32(g), ok
		}
		ms := masters[p]
		for m, mi in ms {
			if s, ok := slot_for(slot_of, gindex, m); ok {
				lp.fm.slot[mi] = s
			} else {
				// Missing/disabled master: DON'T leave the identity default (slot[mi] == mi), which
				// would cross-wire this plugin's refs-into-that-master onto whatever plugin occupies
				// global slot `mi`. Poison it so those refs dangle instead. The manager catches this
				// at apply (validate_masters); this is the engine's last-line guard.
				lp.fm.slot[mi] = esm.INVALID_SLOT
				log.warnf("plugin %s: missing master %q — its refs into it will dangle", inputs[p].name, m)
			}
		}
		// The plugin's own records carry high byte == len(masters): map it to the plugin's stable slot
		// (form-table) or its load-order index (placeholder).
		if s, ok := slot_for(slot_of, gindex, names[p]); ok {
			lp.fm.slot[len(ms)] = s
		} else {
			lp.fm.slot[len(ms)] = u32(gi)
		}
		out[gi] = lp
		log.infof("load order [%02X] %s (%d masters)", gi, inputs[p].name, len(ms))
	}
	return out
}

// Missing_Master is one dependency failure: `plugin` declares a master `master` that isn't present
// in the enabled set. Strings are cloned into the caller's allocator.
Missing_Master :: struct {
	plugin: string,
	master: string,
}

// validate_masters reports every plugin whose declared masters aren't present in the given set (the
// enabled plugins of a profile). A missing master is the #1 modding footgun: vanilla Skyrim CTDs and
// our resolver would (without the INVALID_SLOT guard) cross-wire the dependent's references — so the
// manager surfaces it at profile-apply. Case-insensitive on filename. Order follows `names`, then the
// plugin's master list. Result + its strings are allocated in `allocator`.
validate_masters :: proc(names: []string, masters: [][]string, allocator := context.allocator) -> []Missing_Master {
	present := make(map[string]bool, len(names), context.temp_allocator)
	for n in names {present[strings.to_lower(n, context.temp_allocator)] = true}

	out := make([dynamic]Missing_Master, 0, allocator)
	for ms, i in masters {
		for m in ms {
			if !present[strings.to_lower(m, context.temp_allocator)] {
				append(&out, Missing_Master{plugin = strings.clone(names[i], allocator), master = strings.clone(m, allocator)})
			}
		}
	}
	return out[:]
}
