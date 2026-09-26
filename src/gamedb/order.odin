package gamedb

import "core:slice"

// chain_order orders siblings by their previous-sibling links (`previous`, 0 for none): each chain
// in turn, chains by their first form's order, then any loop. Returns a slice in `allocator`.
chain_order :: proc(kids: []Form_ID, previous: map[Form_ID]Form_ID, allocator := context.allocator) -> []Form_ID {
	slice.sort(kids)
	after := make(map[Form_ID][dynamic]Form_ID, len(kids), context.temp_allocator)
	for k in kids {
		prev := previous[k]
		if !slice.contains(kids, prev) {continue}
		if prev not_in after {after[prev] = make([dynamic]Form_ID, context.temp_allocator)}
		append(&after[prev], k)
	}
	out := make([dynamic]Form_ID, 0, len(kids), allocator)
	placed := make(map[Form_ID]bool, len(kids), context.temp_allocator)
	chain :: proc(k: Form_ID, after: map[Form_ID][dynamic]Form_ID, placed: ^map[Form_ID]bool, out: ^[dynamic]Form_ID) {
		if placed[k] {return}
		placed[k] = true
		append(out, k)
		if nexts, ok := after[k]; ok {
			for next in nexts {chain(next, after, placed, out)}
		}
	}
	for k in kids {
		if !slice.contains(kids, previous[k]) {chain(k, after, &placed, &out)}
	}
	for k in kids {chain(k, after, &placed, &out)} // a loop of siblings
	return out[:]
}
