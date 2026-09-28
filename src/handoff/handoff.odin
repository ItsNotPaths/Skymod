package handoff

// Handing values between two threads: a Queue one side appends to and the other drains, and a
// Latest one side publishes and the other takes the newest of. Buffers swap, never copy.

import "core:sync"

// Queue is a list one side appends to and the other drains whole.
Queue :: struct($T: typeid) {
	mu:    sync.Mutex,
	items: [dynamic]T,
}

push :: proc(q: ^Queue($T), item: T) {
	sync.guard(&q.mu)
	append(&q.items, item)
}

// drain moves everything queued into `into` (cleared first). The two buffers swap, so neither
// side allocates once both have grown.
drain :: proc(q: ^Queue($T), into: ^[dynamic]T) {
	clear(into)
	sync.guard(&q.mu)
	q.items, into^ = into^, q.items
}

// take_first pops the oldest item.
take_first :: proc(q: ^Queue($T)) -> (item: T, ok: bool) {
	sync.guard(&q.mu)
	if len(q.items) == 0 {return}
	item = q.items[0]
	ordered_remove(&q.items, 0)
	return item, true
}

destroy :: proc(q: ^Queue($T)) {
	delete(q.items)
}

// Latest is a value one side publishes and the other takes the newest of. Three buffers turn —
// the publisher's back, the shared slot and the taker's current — so nothing is copied.
Latest :: struct($T: typeid) {
	mu:    sync.Mutex,
	slot:  T,
	fresh: bool,
}

// publish hands `back` over as the newest and gets an old buffer back to fill next.
publish :: proc(l: ^Latest($T), back: ^T) {
	sync.guard(&l.mu)
	l.slot, back^ = back^, l.slot
	l.fresh = true
}

// take swaps the newest into `cur`, if one arrived since the last take.
take :: proc(l: ^Latest($T), cur: ^T) -> bool {
	sync.guard(&l.mu)
	if !l.fresh {return false}
	l.slot, cur^ = cur^, l.slot
	l.fresh = false
	return true
}
