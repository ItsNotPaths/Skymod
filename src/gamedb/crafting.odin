package gamedb

// Crafting recipe indexing: COBJ, one row in a crafting menu. A recipe names what it consumes, what
// it makes, how many, and which workbench shows it.
//
// Recipes are indexed twice: by their own form, and grouped by workbench keyword. The grouping is
// the reason to index at all — a crafting menu opens knowing its station and needs that station's
// rows, which is what recipes_for_bench answers.
//
// NOT decoded: the CTDA conditions that gate a recipe. They carry the perk, quest or item
// requirement that decides whether a row is offered — Steel Smithing for steel armor, and so on.
// Conditions are a subsystem of their own and nothing in the engine evaluates them yet, so a menu
// built on this index lists every recipe its bench owns. Filter here once CTDA lands.

import "../formats/esm"

// Recipe is a COBJ record.
Recipe :: struct {
	ingredients: []Content_Entry, // CNTO items and counts, owned and remapped. Empty is legal.
	result:      Form_ID,         // CNAM created object, remapped. 0 on a recipe that makes nothing.
	bench:       Form_ID,         // BNAM workbench KEYWORD — the station whose menu lists this.
	quantity:    u16,             // NAM1 how many the recipe yields. 583 of the 601 make one.
}

// free_recipe releases a Recipe's owned ingredient list.
@(private)
free_recipe :: proc(db: ^DB, r: Recipe) {
	delete(r.ingredients, db.allocator)
}

// index_recipe decodes a COBJ. The field order is fixed across the base game — EDID, COCT, the CNTO
// runs, the CTDA conditions, then CNAM, BNAM and NAM1 — so every field is reachable by tag and the
// ingredient list reuses the CNTO reader that containers already share.
//
// VERIFIED against Skyrim.esm: 601 records, every one carrying a BNAM and a NAM1, and the seven
// BNAM keywords partition them exactly (armor table 226, forge 159, sharpening wheel 158, cookpot
// 18, smelter 16, tanning rack 15, skyforge 9). Two absences are real data rather than decode
// failures, so neither is treated as an error: 7 records carry no CNAM and make nothing (broken
// vanilla rows such as TemperArmorDA03Masque), and 2 carry no ingredients (the Blade of Woe temper
// recipes). Alchemy and enchanting are absent by design — neither is authored as a COBJ.
@(private)
index_recipe :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	bench, bok := esm.subrecord_formid(fl, "BNAM")
	if !bok {
		return // no workbench means no menu can ever show it
	}

	r := Recipe{bench = esm.remap_form(fm, bench)}
	if c, cok := esm.subrecord_formid(fl, "CNAM"); cok && c != 0 {
		r.result = esm.remap_form(fm, c)
	}
	if q, qok := esm.find_field(fl, "NAM1"); qok && len(q.data) >= 2 {
		r.quantity = u16(q.data[0]) | u16(q.data[1]) << 8
	}
	raw := esm.container_contents(fl, context.allocator) // walk has no temp reset — explicit free
	defer if raw != nil {delete(raw, context.allocator)}
	r.ingredients = make([]Content_Entry, len(raw), db.allocator)
	for c, i in raw {
		r.ingredients[i] = Content_Entry{item = esm.remap_form(fm, c.item), count = c.count}
	}

	if old, existed := db.recipes[rec.form_id]; existed {
		free_recipe(db, old) // override: free the previous plugin's ingredient list
		// The bench grouping already holds this form. A plugin may move a recipe to another
		// station, so drop the stale entry before the new bench claims it.
		unlist_recipe(db, old.bench, rec.form_id)
	}
	db.recipes[rec.form_id] = r

	list, seen := &db.recipes_by_bench[r.bench]
	if !seen {
		db.recipes_by_bench[r.bench] = make([dynamic]Form_ID, 0, 16, db.allocator)
		list = &db.recipes_by_bench[r.bench]
	}
	append(list, rec.form_id)
}

// unlist_recipe removes one recipe from a bench's list, for the override path where a later plugin
// reassigns it. Order within a bench is not meaningful, so this swaps the last entry into the gap.
@(private)
unlist_recipe :: proc(db: ^DB, bench: Form_ID, form: Form_ID) {
	list, ok := &db.recipes_by_bench[bench]
	if !ok {
		return
	}
	for f, i in list {
		if f == form {
			ordered_remove(list, i)
			return
		}
	}
}

// --- queries ----------------------------------------------------------------------------

// recipe_of returns a COBJ's decoded recipe. Borrowed — the DB owns the ingredient list. ok=false
// when the form is not an indexed recipe.
recipe_of :: proc(db: ^DB, form: Form_ID) -> (Recipe, bool) {
	if db == nil {
		return {}, false
	}
	r, ok := db.recipes[form]
	return r, ok
}

// recipes_for_bench returns the recipes a workbench shows, addressed by its BNAM KEYWORD form (for
// instance the one CraftingSmithingForge names). Borrowed, and empty for a keyword no recipe uses.
// Every recipe the bench owns is listed: the CTDA requirements are not decoded, so the caller sees
// rows the player may not yet be able to craft.
recipes_for_bench :: proc(db: ^DB, bench: Form_ID) -> []Form_ID {
	if db == nil {
		return {}
	}
	return db.recipes_by_bench[bench][:]
}
