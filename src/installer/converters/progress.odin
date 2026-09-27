package converters

import "core:strings"
import "core:sync"

// Progress is what a running install reports; the installer window reads it every frame. Every
// proc takes a nil Progress and does nothing, for callers that show none.
Progress :: struct {
	mu:       sync.Mutex,
	step:     string, // a literal: "Converting sounds"
	done:     int,    // atomic
	total:    int,
	item:     [256]u8, // what a worker started last
	item_len: int,
}

// progress_step starts a step of total items.
progress_step :: proc(p: ^Progress, step: string, total: int) {
	if p == nil {return}
	sync.guard(&p.mu)
	p.step, p.total, p.item_len = step, total, 0
	sync.atomic_store(&p.done, 0)
}

// progress_note names the item a worker is on now.
progress_note :: proc(p: ^Progress, item: string) {
	if p == nil {return}
	sync.guard(&p.mu)
	p.item_len = copy(p.item[:], item)
}

progress_done :: proc(p: ^Progress, n := 1) {
	if p == nil {return}
	sync.atomic_add(&p.done, n)
}

// progress_read copies the state out; item is temp-allocated.
progress_read :: proc(p: ^Progress) -> (step, item: string, done, total: int) {
	sync.guard(&p.mu)
	return p.step, strings.clone(string(p.item[:p.item_len]), context.temp_allocator), sync.atomic_load(&p.done), p.total
}
