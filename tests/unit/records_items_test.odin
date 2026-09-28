package unit_tests

import "core:testing"
import "../../src/gamedb"
import "../../src/plugin"
import "../../src/worldhost"
import "../../src/worldstate"

@(test)
test_record_enchantment :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.enchantments)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	fx := []gamedb.Magic_Effect_Ref{{effect = 0xE1, magnitude = 5}}
	db.enchantments[0x10] = {info = {cost = 12}, base_enchantment = 0x11, effects = fx}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Enchantment
	testing.expect(t, plugin.record(&w, 0x10, .Enchantment, &v), "found")
	testing.expect_value(t, v.info.cost, 12)
	testing.expect_value(t, v.base_enchantment, 0x11)
	testing.expect_value(t, plugin.items(v.effects)[0].magnitude, 5)
	testing.expect(t, !plugin.record(&w, 0x12, .Enchantment, &v), "missing")
}

@(test)
test_record_potion :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.potions)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	fx := []gamedb.Magic_Effect_Ref{{effect = 0xE1, duration = 30}}
	db.potions[0x10] = {effects = fx, poison = true}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Potion
	testing.expect(t, plugin.record(&w, 0x10, .Potion, &v), "found")
	testing.expect(t, v.poison, "poison")
	testing.expect_value(t, plugin.items(v.effects)[0].duration, 30)
	testing.expect(t, !plugin.record(&w, 0x12, .Potion, &v), "missing")
}

@(test)
test_record_ingredient :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.ingredients)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.ingredients[0x10] = []gamedb.Magic_Effect_Ref{{effect = 0xE1}, {effect = 0xE2}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Ingredient
	testing.expect(t, plugin.record(&w, 0x10, .Ingredient, &v), "found")
	e := plugin.items(v.effects)
	testing.expect_value(t, len(e), 2)
	testing.expect_value(t, e[1].effect, 0xE2)
	testing.expect(t, !plugin.record(&w, 0x12, .Ingredient, &v), "missing")
}

@(test)
test_record_projectile :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.projectiles)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.projectiles[0x10] = {type = .Arrow, speed = 5000, gravity = 0.35}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Projectile
	testing.expect(t, plugin.record(&w, 0x10, .Projectile, &v), "found")
	testing.expect(t, v.info.type == .Arrow, "arrow")
	testing.expect_value(t, v.info.speed, 5000)
	testing.expect(t, !plugin.record(&w, 0x12, .Projectile, &v), "missing")
}

@(test)
test_record_book :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.books)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.books[0x10] = {skill = -1, spell = 0x5A}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Book
	testing.expect(t, plugin.record(&w, 0x10, .Book, &v), "found")
	testing.expect_value(t, v.skill, -1)
	testing.expect_value(t, v.spell, 0x5A)
	testing.expect(t, !plugin.record(&w, 0x12, .Book, &v), "missing")
}

@(test)
test_record_recipe :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.recipes)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ingredients := []gamedb.Content_Entry{{item = 0x20, count = 2}}
	cond := []gamedb.Condition{{function = 448, value = 1}}
	db.recipes[0x10] = {ingredients = ingredients, result = 0x21, bench = 0x22, quantity = 1, conditions = cond}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Recipe
	testing.expect(t, plugin.record(&w, 0x10, .Recipe, &v), "found")
	testing.expect_value(t, v.result, 0x21)
	testing.expect_value(t, v.quantity, 1)
	testing.expect_value(t, plugin.items(v.ingredients)[0], plugin.Item_Count{0x20, 2})
	testing.expect_value(t, plugin.items(v.conditions)[0].function, 448)
	testing.expect(t, !plugin.record(&w, 0x12, .Recipe, &v), "missing")
}

@(test)
test_record_leveled_list :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.leveled_lists)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	entries := []gamedb.Leveled_Entry{{level = 1, form = 0x20, count = 1}, {level = 10, form = 0x21, count = 3}}
	db.leveled_lists[0x10] = {chance_none = 25, chance_global = 0x30, entries = entries}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Leveled_List
	testing.expect(t, plugin.record(&w, 0x10, .Leveled_List, &v), "found")
	testing.expect_value(t, v.chance_none, 25)
	testing.expect_value(t, v.chance_global, 0x30)
	e := plugin.items(v.entries)
	testing.expect_value(t, len(e), 2)
	testing.expect_value(t, e[1], plugin.Leveled_List_Entry{10, 0x21, 3})
	testing.expect(t, !plugin.record(&w, 0x12, .Leveled_List, &v), "missing")
}

@(test)
test_record_container :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.containers)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.containers[0x10] = []gamedb.Content_Entry{{item = 0xF, count = 100}}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Container
	testing.expect(t, plugin.record(&w, 0x10, .Container, &v), "found")
	testing.expect_value(t, plugin.items(v.contents)[0], plugin.Item_Count{0xF, 100})
	testing.expect(t, !plugin.record(&w, 0x12, .Container, &v), "missing")
}

@(test)
test_record_outfit :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.outfits)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.outfits[0x10] = []gamedb.Form_ID{0x20, 0x21}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Outfit
	testing.expect(t, plugin.record(&w, 0x10, .Outfit, &v), "found")
	testing.expect_value(t, plugin.items(v.items)[1], 0x21)
	testing.expect(t, !plugin.record(&w, 0x12, .Outfit, &v), "missing")
}

@(test)
test_record_form_list :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.form_lists)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.form_lists[0x10] = []gamedb.Form_ID{0x20, 0x21, 0x22}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	v: plugin.Form_List
	testing.expect(t, plugin.record(&w, 0x10, .Form_List, &v), "found")
	testing.expect_value(t, len(plugin.items(v.forms)), 3)
	testing.expect_value(t, plugin.items(v.forms)[2], 0x22)
	testing.expect(t, !plugin.record(&w, 0x12, .Form_List, &v), "missing")
}
