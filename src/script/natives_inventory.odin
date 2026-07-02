package script

// Inventory natives (docs/scripting-natives.md §B). `self` is the container/actor; items are keyed by
// their base-object FormID. Overlay-only: the ESM baseline contents aren't indexed, so counts are
// DELTAS from the baseline (GetItemCount reads what scripts added/removed, not absolute contents).
// Not scene geometry → no mark_scene_dirty (a dropped world item would be, but DropObject is deferred).

import "../worldstate"

// Gold001 — Skyrim.esm local 0x0000000F, master slot 0 → the wide FormID 0xF. GetGoldAmount counts it.
GOLD :: Form_ID(0x0000_000F)

register_inventory :: proc(reg: ^Registry) {
	register(reg, "ObjectReference", "AddItem", n_add_item)
	register(reg, "ObjectReference", "RemoveItem", n_remove_item)
	register(reg, "ObjectReference", "GetItemCount", n_get_item_count)
	register(reg, "ObjectReference", "RemoveAllItems", n_remove_all_items)
	register(reg, "Actor", "GetGoldAmount", n_get_gold)
}

// AddItem(akItemToAdd, aiCount=1, abSilent=false).
n_add_item :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.inv_add(c.ws, c.self, arg_form(args, 0), max(1, arg_i32(args, 1, 1)))
	return nil
}

// RemoveItem(akItemToRemove, aiCount=1, abSilent=false, akOtherContainer=None). The transfer-target
// container is ignored for now (items just leave `self`); a real transfer adds to akOtherContainer too.
n_remove_item :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.inv_add(c.ws, c.self, arg_form(args, 0), -max(1, arg_i32(args, 1, 1)))
	return nil
}

n_get_item_count :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.inv_count(c.ws, c.self, arg_form(args, 0))
}

// RemoveAllItems(akTransferTo=None, …) — clears the overlay inventory (transfer target ignored).
n_remove_all_items :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.inv_clear(c.ws, c.self)
	return nil
}

n_get_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.inv_count(c.ws, c.self, GOLD)
}
