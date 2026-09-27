package worldstate

// Cell reset: the overlay half. What resets and when is decided over gamedb in script/reset.odin.

// Cell_State is a cell's reset clock.
Cell_State :: struct {
	left:        f64, // game hour the cell last detached
	reset_asked: bool, // Cell.Reset: reset on the next entry, created refs too
}

// leave_cell starts a detaching cell's reset clock.
leave_cell :: proc(ws: ^World_State, cell: Form_ID) {
	s := ws.cells[cell]
	s.left = ws.clock.hours
	ws.cells[cell] = s
}

// ask_reset is Cell.Reset.
ask_reset :: proc(ws: ^World_State, cell: Form_ID) {
	s := ws.cells[cell]
	s.reset_asked = true
	ws.cells[cell] = s
}

// reset_ref_state puts a ref's overlay back to its baseline. The enable state and a deletion stay
// (CK wiki, Cell Reset). `inventory` resets its contents and actor values too. Scripts are
// restart_scripts' job.
reset_ref_state :: proc(ws: ^World_State, form: Form_ID, inventory: bool) {
	if d, ok := &ws.ref_deltas[form]; ok {
		d.live &= {.Disabled, .Deleted, .Delete_When_Detached}
		if d.live == {} {drop_delta(ws, form)}
	}
	delete_key(&ws.killers, form)
	if inventory {
		drop_inventory(ws, form)
		if inner, ok := ws.actor_values[form]; ok {delete(inner)}
		delete_key(&ws.actor_values, form)
		drop_deltas(&ws.spells, form)
		delete_key(&ws.actor_picks, form)
		delete_key(&ws.actor_flags, form)
	}
}

// restart_scripts drops a ref's script state; the VM restarts its instances and sends OnReset.
restart_scripts :: proc(ws: ^World_State, form: Form_ID) {
	forget_scripts(ws, form)
	append(&ws.reset_refs, form)
}

// drop_inventory puts a container's contents back to its baseline; leveled entries roll again.
drop_inventory :: proc(ws: ^World_State, form: Form_ID) {
	drop_deltas(&ws.inventories, form)
	if m, ok := ws.stolen[form]; ok {delete(m)}
	delete_key(&ws.stolen, form)
	if list, ok := ws.rolled[form]; ok {delete(list)}
	delete_key(&ws.rolled, form)
	drop_equipment(ws, form)
	gone := make([dynamic]Form_ID, context.temp_allocator)
	for ref, holder in ws.carried {
		if holder == form {append(&gone, ref)}
	}
	for ref in gone {delete_key(&ws.carried, ref)}
}

// remove_created deletes a created ref outright: its placement, delta and scripts.
remove_created :: proc(ws: ^World_State, form: Form_ID) {
	c, ok := ws.created[form]
	if !ok {return}
	delete_key(&ws.created, form)
	if list, lok := &ws.created_by_cell[c.cell]; lok {remove_id(list, form)}
	drop_delta(ws, form)
	append(&ws.gone_refs, form)
}

@(private)
drop_delta :: proc(ws: ^World_State, form: Form_ID) {
	d, ok := ws.ref_deltas[form]
	if !ok {return}
	delete_key(&ws.ref_deltas, form)
	if list, lok := &ws.by_cell[d.cell]; lok {remove_id(list, form)}
}

@(private)
remove_id :: proc(list: ^[dynamic]Form_ID, form: Form_ID) {
	for f, i in list {
		if f == form {unordered_remove(list, i);return}
	}
}
