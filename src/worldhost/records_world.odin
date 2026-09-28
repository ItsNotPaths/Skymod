package worldhost

// The engine's record views: world (see records.odin).

import "../gamedb"
import "../plugin"

@(private)
view_cell :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Cell, ok: bool) {
	return
}

@(private)
view_location :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Location, ok: bool) {
	return
}

@(private)
view_worldspace :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Worldspace, ok: bool) {
	return
}

@(private)
view_weather :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Weather, ok: bool) {
	return
}

@(private)
view_placed_ref :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Placed_Ref, ok: bool) {
	return
}

@(private)
view_lock :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Lock, ok: bool) {
	return
}

@(private)
view_trigger :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Trigger, ok: bool) {
	return
}

@(private)
view_linked_refs :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Linked_Refs, ok: bool) {
	return
}

@(private)
view_form_scripts :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Form_Scripts, ok: bool) {
	return
}
