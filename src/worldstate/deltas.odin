package worldstate

// Deltas is owner -> form -> a count against what the records give the owner (inventories, spell
// lists). The records are read again on every use, so a mod update shows in an old save; only the
// changes are saved.
Deltas :: map[Form_ID]map[Form_ID]i32

@(private)
delta_upsert :: proc(m: ^Deltas, owner: Form_ID) -> ^map[Form_ID]i32 {
	if owner not_in m {m[owner] = make(map[Form_ID]i32)}
	return &m[owner]
}

// drop_deltas puts an owner back to its records.
@(private)
drop_deltas :: proc(m: ^Deltas, owner: Form_ID) {
	if inner, ok := m[owner]; ok {delete(inner)}
	delete_key(m, owner)
}

@(private)
free_deltas :: proc(m: ^Deltas) {
	for _, &inner in m {delete(inner)}
	delete(m^)
}

@(private)
save_deltas :: proc(m: Deltas) -> []Saved_Inv {
	out := make([dynamic]Saved_Inv, 0, len(m), context.temp_allocator)
	for owner, inner in m {
		for form, n in inner {append(&out, Saved_Inv{owner, form, n})}
	}
	return out[:]
}

// load_deltas drops an entry whose owner or form comes from a missing mod.
@(private)
load_deltas :: proc(m: ^Deltas, saved: []Saved_Inv, remap: map[u32]u32, on: bool, rf: proc(map[u32]u32, bool, Form_ID) -> (Form_ID, bool)) {
	for s in saved {
		owner, ook := rf(remap, on, s.owner)
		form, fok := rf(remap, on, s.item)
		if ook && fok {delta_upsert(m, owner)^[form] = s.count}
	}
}

// Form_Set is a saved set of forms (cleared locations, vampires, werewolves).
Form_Set :: map[Form_ID]bool

@(private)
save_set :: proc(m: Form_Set) -> []Form_ID {
	out := make([dynamic]Form_ID, 0, len(m), context.temp_allocator)
	for f in m {append(&out, f)}
	return out[:]
}

// load_set drops a form from a missing mod.
@(private)
load_set :: proc(m: ^Form_Set, saved: []Form_ID, remap: map[u32]u32, on: bool, rf: proc(map[u32]u32, bool, Form_ID) -> (Form_ID, bool)) {
	for s in saved {
		if f, ok := rf(remap, on, s); ok {m[f] = true}
	}
}
