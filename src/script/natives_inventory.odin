package script

// Inventory natives (docs/scripting-natives.md §B). `self` is the container/actor; items are keyed by
// their base-object FormID. Overlay-only: the ESM baseline contents aren't indexed, so counts are
// DELTAS from the baseline (GetItemCount reads what scripts added/removed, not absolute contents).
// Not scene geometry → no mark_scene_dirty (a dropped world item would be, but DropObject is deferred).

import "core:slice"
import "../gamedb"
import "../worldstate"

// Gold001 — Skyrim.esm local 0x0000000F, master slot 0 → the wide FormID 0xF. GetGoldAmount counts it.
GOLD :: Form_ID(0x0000_000F)

register_inventory :: proc(reg: ^Registry) {
	register(reg, "ObjectReference", "AddItem", n_add_item)
	register(reg, "ObjectReference", "RemoveItem", n_remove_item)
	register(reg, "ObjectReference", "GetItemCount", n_get_item_count)
	register(reg, "ObjectReference", "RemoveAllItems", n_remove_all_items)
	register(reg, "Actor", "GetGoldAmount", n_get_gold)
	register(reg, "ObjectReference", "AddInventoryEventFilter", n_add_inventory_event_filter)
	register(reg, "ObjectReference", "RemoveInventoryEventFilter", n_remove_inventory_event_filter)
	register(reg, "ObjectReference", "RemoveAllInventoryEventFilters", n_remove_all_inventory_event_filters)
	register(reg, "Courier", "RemoveRef", n_courier_remove_ref)
}

// Courier.RemoveRef(courier, container, item, toPlayer, countGlobal): the courier's bag gives an
// item back or drops it, and the global that gates the courier's dialogue counts one item fewer.
// WICourierScript.removeRefFromContainer calls it (docs/s5/todo.md P13).
// HOLE(dialogue, gap): while the courier talks to the player the removal must wait for the
// dialogue to end: one saved entry per item, applied when it ends. Nothing talks yet, so it
// applies at once.
n_courier_remove_ref :: proc(c: ^Call, args: []Value) -> Value {
	container, to_player, count := arg_form(args, 1), arg_bool(args, 3, false), arg_form(args, 4)
	base, ref := item_of(c, arg_form(args, 2))
	if worldstate.inv_count(c.ws, container, base) <= 0 {return nil}
	move_items(c, {base = base, ref = ref, from = container, to = PLAYER if to_player else 0, count = 1})
	if count != 0 {
		v, _ := worldstate.get_global(c.ws, count)
		worldstate.set_global(c.ws, count, v - 1)
	}
	return nil
}

// HOLE(script, gap): a ref given to AddItem is not taken from the container it was in; OnItemAdded names no source container and the old one gets no OnItemRemoved.
// AddItem(akItemToAdd, aiCount=1, abSilent=false).
n_add_item :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(args, 0))
	move_items(c, {base = base, ref = ref, to = c.self, count = max(1, arg_i32(args, 1, 1))})
	return nil
}

// RemoveItem(akItemToRemove, aiCount=1, abSilent=false, akOtherContainer=None). With no other
// container the items are destroyed.
n_remove_item :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(args, 0))
	move_items(c, {base = base, ref = ref, from = c.self, to = arg_form(args, 3), count = max(1, arg_i32(args, 1, 1))})
	return nil
}

n_get_item_count :: proc(c: ^Call, args: []Value) -> Value {
	base, _ := item_of(c, arg_form(args, 0))
	return worldstate.inv_count(c.ws, c.self, base)
}

// RemoveAllItems(akTransferTo=None, …): one move per item type, in form order.
n_remove_all_items :: proc(c: ^Call, args: []Value) -> Value {
	to := arg_form(args, 0)
	moves := make([dynamic]worldstate.Item_Move, context.temp_allocator)
	inv, _ := c.ws.inventories[c.self]
	for base, n in inv {
		append(&moves, worldstate.Item_Move{base = base, from = c.self, to = to, count = n})
	}
	slice.sort_by(moves[:], proc(a, b: worldstate.Item_Move) -> bool {return a.base < b.base})
	for m in moves {move_items(c, m)}
	return nil
}

n_add_inventory_event_filter :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.add_item_filter(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_remove_inventory_event_filter :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.remove_item_filter(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_remove_all_inventory_event_filters :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.remove_item_filters(c.ws, c.self)
	return nil
}

// move_items moves the counts and queues the move's inventory events for the next tick.
@(private)
move_items :: proc(c: ^Call, m: worldstate.Item_Move) {
	if m.from != 0 {worldstate.inv_add(c.ws, m.from, m.base, -m.count)}
	if m.to != 0 {worldstate.inv_add(c.ws, m.to, m.base, m.count)}
	worldstate.move_items(c.ws, m)
}

// item_of splits an item argument into its base object and, when the argument is a reference, the ref.
@(private)
item_of :: proc(c: ^Call, form: Form_ID) -> (base, ref: Form_ID) {
	if cr, ok := c.ws.created[form]; ok {return cr.base, form}
	if r, ok := gamedb.ref_by_formid(c.db, form); ok {return r.base, form}
	return form, 0
}

n_get_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.inv_count(c.ws, c.self, GOLD)
}
