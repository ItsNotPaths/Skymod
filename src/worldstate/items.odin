package worldstate

// Items (ws.md Workstream J): a holder stores each plain unit as a count of its base (inventories);
// a unit that carries data is its own form, a created ref or the record ref it was placed as, and
// keeps that ID in an inventory and in the world. Its placement comes and goes; its data stays here.
// Data is an owner it was stolen from, a script, an alias, or being a record ref with scripts.

import "core:slice"
import "../gamedb"

// (hole item-tempering :tags (combat player save) :sev gap) no unit has a quality, so no weapon or armor gets its smithing bonus and Mod_Tempering_Health (20 SE entries) runs nowhere. The bonus formula is not in the data (only fHealthDataValue1 1.1), and only the smithing screen makes a tempered item.
// Unit is one item that carries data.
Unit :: struct {
	base:   Form_ID,
	holder: Form_ID, // 0 = placed in the world
	owner:  Form_ID, // whom it was stolen from; 0 = nobody
}

unit_of :: proc(ws: ^World_State, id: Form_ID) -> (Unit, bool) {
	return ws.units[id]
}

// held_units are `holder`'s units, of `base` only when it is not 0, in form order (temp-allocated).
held_units :: proc(ws: ^World_State, holder: Form_ID, base: Form_ID = 0) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	list, _ := ws.units_of[holder] // never range a missing map key
	for id in list {
		if base == 0 || ws.units[id].base == base {append(&out, id)}
	}
	slice.sort(out[:])
	return out[:]
}

// add_unit makes `id` a unit; a record ref's placement hides while a holder has it.
add_unit :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID, u: Unit) {
	ws.units[id] = {base = u.base, owner = u.owner}
	set_holder(ws, db, id, u.holder)
}

// new_unit makes a unit with no placement, held by `holder`.
new_unit :: proc(ws: ^World_State, db: ^gamedb.DB, base, holder: Form_ID, owner: Form_ID = 0) -> Form_ID {
	id := create_ref(ws, base, 0, {}, {}, 1)
	add_unit(ws, db, id, {base, holder, owner})
	return id
}

// split_unit gives one of `holder`'s plain `base` units identity; 0 when it holds none.
split_unit :: proc(ws: ^World_State, db: ^gamedb.DB, holder, base: Form_ID) -> Form_ID {
	if plain_count(ws, db, holder, base) <= 0 {return 0}
	inv_add(ws, holder, base, -1)
	return new_unit(ws, db, base, holder)
}

// set_holder moves unit `id` to `holder`; 0 places it in the world, where its placement is.
set_holder :: proc(ws: ^World_State, db: ^gamedb.DB, id, holder: Form_ID) {
	u := &ws.units[id]
	if list, ok := &ws.units_of[u.holder]; ok && u.holder != 0 {remove_id(list, id)}
	u.holder = holder
	if holder != 0 {
		if holder not_in ws.units_of {ws.units_of[holder] = make([dynamic]Form_ID)}
		append(&ws.units_of[holder], id)
	}
	d := upsert(ws, id, ref_cell(ws, db, id))
	if holder != 0 {d.live += {.Held}} else {d.live -= {.Held}}
}

// unplace takes a created unit out of its cell: held, it has no placement.
unplace :: proc(ws: ^World_State, id: Form_ID) {
	cr, ok := &ws.created[id]
	if !ok || cr.cell == 0 {return}
	if list, lok := &ws.created_by_cell[cr.cell]; lok {remove_id(list, id)}
	cr.cell = 0
}

// destroy_placed takes a world item out of the game: a unit as a unit, a created ref outright, a
// record ref as deleted.
destroy_placed :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) {
	switch {
	case form in ws.units:   drop_unit(ws, db, form)
	case form in ws.created: remove_created(ws, form)
	case:                    set_deleted(ws, form, ref_cell(ws, db, form))
	}
}

// drop_unit destroys unit `id`: a created one outright, a record ref as deleted.
drop_unit :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) {
	u, ok := ws.units[id]
	if !ok {return}
	if id in ws.created {
		remove_created(ws, id)
		return
	}
	if list, lok := &ws.units_of[u.holder]; lok {remove_id(list, id)}
	delete_key(&ws.units, id)
	set_deleted(ws, id, ref_cell(ws, db, id))
}

// has_data: a unit or a placed ref carries something a count cannot: an owner it was stolen from,
// scripts (its own or its base's), or an alias holding it.
has_data :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) -> bool {
	if u, ok := ws.units[id]; ok && u.owner != 0 {return true}
	if len(aliases_of(ws, id)) > 0 {return true}
	return len(gamedb.effective_scripts(db, id, ref_base(ws, db, id), context.temp_allocator)) > 0
}

// settle turns a held created unit that no longer carries data back into a count.
settle :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) {
	u, ok := ws.units[id]
	if !ok || u.holder == 0 || id not_in ws.created || has_data(ws, db, id) {return}
	inv_add(ws, u.holder, u.base, 1)
	drop_unit(ws, db, id)
}

// unit_for is the ref an item in a holder is to its scripts: a unit of it the holder has, else for a
// scripted base one of its plain units given identity (starting contents). 0 when neither.
unit_for :: proc(ws: ^World_State, db: ^gamedb.DB, holder, base: Form_ID) -> Form_ID {
	if units := held_units(ws, holder, base); len(units) > 0 {return units[0]}
	if len(gamedb.base_scripts(db, base)) == 0 {return 0}
	return split_unit(ws, db, holder, base)
}

// stolen_count is how many of the `item`s `holder` holds are stolen, from anyone.
stolen_count :: proc(ws: ^World_State, db: ^gamedb.DB, holder, item: Form_ID) -> i32 {
	n: i32
	for id in held_units(ws, holder, item) {
		if ws.units[id].owner != 0 {n += 1}
	}
	return n
}

// Item_Stack is one row of a holder's items as a menu shows them: identical units grouped.
Item_Stack :: struct {
	item:   Form_ID,
	stolen: bool,
	count:  i32,
}

// inv_stacks is `holder`'s items as rows: an item's clean ones, then its stolen ones.
inv_stacks :: proc(ws: ^World_State, db: ^gamedb.DB, holder: Form_ID) -> []Item_Stack {
	out := make([dynamic]Item_Stack, context.temp_allocator)
	for item in inv_items(ws, db, holder) {
		n, s := inv_count(ws, db, holder, item), stolen_count(ws, db, holder, item)
		if n > s {append(&out, Item_Stack{item, false, n - s})}
		if s > 0 {append(&out, Item_Stack{item, true, s})}
	}
	return out[:]
}

// split_scripted_counts gives identity to the counted units of every base that now has scripts (a
// mod added them since the save was made). Called after a load.
split_scripted_counts :: proc(ws: ^World_State, db: ^gamedb.DB) {
	Count :: struct {
		holder, base: Form_ID,
		n:            i32,
	}
	todo := make([dynamic]Count, context.temp_allocator)
	for holder, items in ws.inventories {
		for base, n in items {
			if n > 0 && len(gamedb.base_scripts(db, base)) > 0 {append(&todo, Count{holder, base, n})}
		}
	}
	for c in todo {
		for _ in 0 ..< c.n {split_unit(ws, db, c.holder, c.base)}
	}
}
