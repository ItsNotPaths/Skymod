package models

// A model's ID names its mesh path, lowercased, for the session: placements, the collision store,
// the streamer and render key on it, so no path string or pointer crosses the sim seam. Any thread.

import "base:runtime"
import "core:strings"
import "core:sync"

// ID is a model; 0 is none.
ID :: distinct u32

@(private)
table: struct {
	mu:    sync.RW_Mutex,
	ids:   map[string]ID,
	paths: [dynamic]string, // by ID; [0] = ""
}

// intern is the ID of a mesh path, made on first sight; 0 for "".
intern :: proc(path: string) -> ID {
	if path == "" {return 0}
	key := strings.to_lower(path, context.temp_allocator)
	{
		sync.shared_guard(&table.mu)
		if id, ok := table.ids[key]; ok {return id}
	}
	sync.guard(&table.mu)
	if id, ok := table.ids[key]; ok {return id}
	context.allocator = runtime.heap_allocator() // session-long: never freed
	if len(table.paths) == 0 {append(&table.paths, "")}
	owned := strings.clone(key)
	id := ID(len(table.paths))
	append(&table.paths, owned)
	table.ids[owned] = id
	return id
}

// path is a model's mesh path, lowercased; "" for 0 or an unknown ID.
path :: proc(id: ID) -> string {
	sync.shared_guard(&table.mu)
	return table.paths[id] if int(id) < len(table.paths) else ""
}
