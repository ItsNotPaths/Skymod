package worldhost

// The engine's record views: items (see records.odin).

import "../gamedb"
import "../plugin"

@(private)
view_enchantment :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Enchantment, ok: bool) {
	return
}

@(private)
view_potion :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Potion, ok: bool) {
	return
}

@(private)
view_ingredient :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Ingredient, ok: bool) {
	return
}

@(private)
view_projectile :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Projectile, ok: bool) {
	return
}

@(private)
view_book :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Book, ok: bool) {
	return
}

@(private)
view_recipe :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Recipe, ok: bool) {
	return
}

@(private)
view_leveled_list :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Leveled_List, ok: bool) {
	return
}

@(private)
view_container :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Container, ok: bool) {
	return
}

@(private)
view_outfit :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Outfit, ok: bool) {
	return
}

@(private)
view_form_list :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Form_List, ok: bool) {
	return
}
