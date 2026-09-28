package worldhost

// The engine's record views: actors (see records.odin).

import "../gamedb"
import "../plugin"

@(private)
view_actor_base :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Actor_Base, ok: bool) {
	return
}

@(private)
view_race :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Race, ok: bool) {
	return
}

@(private)
view_class :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Class, ok: bool) {
	return
}

@(private)
view_faction :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Faction, ok: bool) {
	return
}

@(private)
view_actor_value_info :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Actor_Value_Info, ok: bool) {
	return
}

@(private)
view_perk :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Perk, ok: bool) {
	return
}

@(private)
view_perk_tree :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Perk_Tree, ok: bool) {
	return
}

@(private)
view_package :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Package, ok: bool) {
	return
}

@(private)
view_zone :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Zone, ok: bool) {
	return
}

@(private)
view_equip_slot :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Equip_Slot, ok: bool) {
	return
}

@(private)
view_equip_type :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Equip_Type, ok: bool) {
	return
}

@(private)
view_movement :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Movement, ok: bool) {
	return
}
