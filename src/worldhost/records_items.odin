package worldhost

// The engine's record views: items (see records.odin).

import "../gamedb"
import "../plugin"

@(private)
view_enchantment :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Enchantment, ok: bool) {
	e := db.enchantments[form] or_return
	return {info = e.info, base_enchantment = e.base_enchantment, worn_restrictions = e.worn_restrictions, effects = effects(e.effects)}, true
}

@(private)
view_potion :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Potion, ok: bool) {
	p := db.potions[form] or_return
	return {effects = effects(p.effects), poison = p.poison}, true
}

@(private)
view_ingredient :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Ingredient, ok: bool) {
	fx := db.ingredients[form] or_return
	return {effects = effects(fx)}, true
}

@(private)
view_projectile :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Projectile, ok: bool) {
	p := db.projectiles[form] or_return
	return {info = p}, true
}

@(private)
view_book :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Book, ok: bool) {
	b := db.books[form] or_return
	return {skill = b.skill, spell = b.spell}, true
}

@(private)
view_recipe :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Recipe, ok: bool) {
	r := db.recipes[form] or_return
	return {ingredients = item_counts(r.ingredients), result = r.result, bench = r.bench, quantity = r.quantity, conditions = conditions(r.conditions)}, true
}

@(private)
view_leveled_list :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Leveled_List, ok: bool) {
	l := db.leveled_lists[form] or_return
	entries := make([]plugin.Leveled_List_Entry, len(l.entries), context.temp_allocator)
	for e, i in l.entries {entries[i] = {e.level, e.form, e.count}}
	return {chance_none = l.chance_none, chance_global = l.chance_global, flags = l.flags, entries = plugin.span(entries)}, true
}

@(private)
view_container :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Container, ok: bool) {
	c := db.containers[form] or_return
	return {contents = item_counts(c)}, true
}

@(private)
view_outfit :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Outfit, ok: bool) {
	o := db.outfits[form] or_return
	return {items = forms(o)}, true
}

@(private)
view_form_list :: proc(db: ^gamedb.DB, form: Form_ID) -> (v: plugin.Form_List, ok: bool) {
	f := db.form_lists[form] or_return
	return {forms = forms(f)}, true
}
