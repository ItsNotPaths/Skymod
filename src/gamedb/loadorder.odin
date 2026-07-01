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
	name: string,
	data: []u8,
}

// Loaded_Plugin is a Plugin_Input resolved into the global load order: its global index
// (the high byte of the FormIDs it defines) and the Form_Map that rewrites its local
// FormIDs into global space. Produced by resolve_load_order, consumed by build_plugins.
Loaded_Plugin :: struct {
	name:  string,
	data:  []u8,
	index: int,
	fm:    esm.Form_Map,
}

// resolve_load_order reads each plugin's TES4 master list, topo-sorts the set into Skyrim
// load order (esm.load_order), and builds each plugin's Form_Map (local master index ->
// the master's global index; the self slot -> the plugin's own global index; everything
// else identity). The returned slice is in load order, allocated in `allocator`; free it
// with delete(). Header masters are read into the temp allocator.
resolve_load_order :: proc(inputs: []Plugin_Input, allocator := context.allocator) -> []Loaded_Plugin {
	n := len(inputs)
	names := make([]string, n, context.temp_allocator)
	masters := make([][]string, n, context.temp_allocator)
	for inp, i in inputs {
		names[i] = inp.name
		if h, ok := esm.parse_header(inp.data, context.temp_allocator); ok {
			masters[i] = h.masters
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
			name  = inputs[p].name,
			data  = inputs[p].data,
			index = gi,
		}
		for b in 0 ..< 256 {
			lp.fm.slot[b] = u32(b) // identity default (unused high bytes pass through)
		}
		ms := masters[p]
		for m, mi in ms {
			if g, ok := gindex[strings.to_lower(m, context.temp_allocator)]; ok {
				lp.fm.slot[mi] = u32(g)
			}
		}
		lp.fm.slot[len(ms)] = u32(gi) // the plugin's own records carry high byte == len(masters)
		out[gi] = lp
		log.infof("load order [%02X] %s (%d masters)", gi, inputs[p].name, len(ms))
	}
	return out
}
