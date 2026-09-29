package worldstate

// Items content gives magic (rt.item): what using an item does. The item itself (model, name,
// weight, value) stays its record's; the definition says how it is used (user, 2026-09-28):
// from the inventory on the user (potions, food, ingredients, a lucky mug), or held in a hand where
// each cast of the spell it `casts` uses one up (scrolls). A `poison` tag coats the held weapon
// instead. Keyed by the item's form, and not saved. item_view answers for a definition or a record.

import "core:log"
import "../gamedb"

Item_Use :: enum u8 {
	Inventory,
	Hand,
}

Item_Def :: struct {
	use:     Item_Use,
	casts:   Form_ID, // Hand: the spell a cast casts
	entries: [dynamic]Spell_Entry, // Inventory: what using it applies
}

Item_Def_Src :: struct {
	name, form: string, // form: the item's record, required
	use:        string, // "inventory", "hand", or "" for its record's way (a scroll's is hand)
	casts:      string, // a spell's name
	tags:       []string,
	entries:    []Spell_Entry_Src,
}

set_item_def :: proc(ws: ^World_State, db: ^gamedb.DB, src: Item_Def_Src) -> (Form_ID, bool) {
	form, ok := form_by_name(ws, db, src.form)
	if !ok {
		log.warnf("rt.item %s: no item record %q; an item needs one for its model, weight and value", src.name, src.form)
		return 0, false
	}
	d := Item_Def{}
	sp, is_spell := gamedb.spell_of(db, form)
	switch src.use {
	case "inventory": d.use = .Inventory
	case "hand":      d.use = .Hand
	case "":          d.use = .Hand if is_spell && sp.scroll else .Inventory
	case:
		log.warnf("rt.item %s: use %q is not inventory or hand", src.name, src.use)
		return 0, false
	}
	if src.casts != "" {
		d.casts, ok = form_by_name(ws, db, src.casts)
		if !ok {log.warnf("rt.item %s: no spell %q", src.name, src.casts)}
	}
	for e in src.entries {
		effect, eok := effect_by_name(ws, db, e.effect)
		dur, dok := parse_duration(e.d)
		if eok && dok {append(&d.entries, Spell_Entry{effect, e.m, dur, e.area, e.hits == "direct"})} else {log.warnf("rt.item %s: no effect %q, or a bad d", src.name, e.effect)}
	}
	if d.use == .Hand && d.casts == 0 {log.warnf("rt.item %s: held in a hand, it casts nothing", src.name)}
	set_tags(ws, form, src.tags)
	if old, has := &ws.item_defs[form]; has {
		delete(old.entries)
		old^ = d
	} else {
		ws.item_defs[form] = d
	}
	return form, true
}

// Item_View is what using an item does, from its definition or its record.
Item_View :: struct {
	use:     Item_Use,
	poison:  bool, // it coats the held weapon instead
	casts:   Form_ID, // Hand
	entries: []gamedb.Magic_Effect_Ref, // Inventory
}

// item_view: ok=false for an item with no use (a sword, a plain mug).
item_view :: proc(ws: ^World_State, db: ^gamedb.DB, item: Form_ID) -> (v: Item_View, ok: bool) {
	if d, has := ws.item_defs[item]; has {
		return {d.use, has_tag(ws, db, item, "poison"), d.casts, entry_refs(d.entries[:])}, true
	}
	if p, potion := gamedb.potion_of(db, item); potion {return {.Inventory, p.poison, 0, p.effects}, true}
	if sp, spell := gamedb.spell_of(db, item); spell && sp.scroll {return {use = .Hand, casts = item}, true}
	return
}

// item_slots is the engine slots an item fills: both hands, either one, for an item used in a
// hand; none for one used from the inventory; else its record's.
item_slots :: proc(ws: ^World_State, db: ^gamedb.DB, item: Form_ID) -> (slots: gamedb.Slots, either: bool) {
	if d, has := ws.item_defs[item]; has {
		if d.use == .Hand {return {.LeftHand, .RightHand}, true}
		return
	}
	return gamedb.slots_of(db, item)
}
