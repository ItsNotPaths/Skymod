package script

// Inventory natives (docs/scripting-natives.md §B). `self` is the container/actor; items are keyed by
// their base-object FormID. A count is the starting contents (gamedb) plus the overlay's delta.
// Not scene geometry → no mark_scene_dirty, except a dropped world item.

import "core:math"
import "../gamedb"
import smath "../math"
import "../worldstate"
import "../formid"


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
	register(reg, "ObjectReference", "DropObject", n_drop_object)
}

// Courier.RemoveRef(courier, container, item, toPlayer, countGlobal): the courier's bag gives an
// item back or drops it, and the global that gates the courier's dialogue counts one item fewer.
// WICourierScript.removeRefFromContainer calls it (docs/s5/todo.md P13).
// (hole courier-dialogue-wait :tags dialogue :sev gap :needs (dialogue-system)) the courier's removal applies at once.
// While the courier talks to the player, the removal must wait for the dialogue to end: one
// saved entry per item, applied when it ends. Nothing talks yet.
n_courier_remove_ref :: proc(c: ^Call, args: []Value) -> Value {
	container, to_player, count := arg_form(args, 1), arg_bool(args, 3, false), arg_form(args, 4)
	base, ref := item_of(c, arg_form(args, 2))
	if worldstate.inv_count(c.ws, c.db, container, base) <= 0 {return nil}
	move_items(c, {base = base, ref = ref, from = container, to = formid.PLAYER if to_player else 0, count = 1})
	if count != 0 {
		v, _ := worldstate.get_global(c.ws, count)
		worldstate.set_global(c.ws, count, v - 1)
	}
	return nil
}

// (hole addref-source :tags script :sev gap) a ref given to AddItem is not taken from the container it was in; OnItemAdded names no source container and the old one gets no OnItemRemoved.
// AddItem(akItemToAdd, aiCount=1, abSilent=false).
// AddItem(akItemToAdd, aiCount=1, …). A leveled list adds what it rolls at the container's zone level.
n_add_item :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(args, 0))
	count := max(1, arg_i32(args, 1, 1))
	if _, leveled := gamedb.leveled_list_of(c.db, base); leveled {
		rolled := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
		level := worldstate.zone_level(c.ws, c.db, gamedb.zone_of(c.db, c.self))
		worldstate.roll(c.ws, c.db, base, level, count, &rolled)
		for e in rolled {move_items(c, {base = e.item, to = c.self, count = e.count})}
		return nil
	}
	move_items(c, {base = base, ref = ref, to = c.self, count = count})
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
	return worldstate.inv_count(c.ws, c.db, c.self, base)
}

// RemoveAllItems(akTransferTo=None, …): one move per item type, in form order.
n_remove_all_items :: proc(c: ^Call, args: []Value) -> Value {
	to := arg_form(args, 0)
	for base in worldstate.inv_items(c.ws, c.db, c.self) {
		move_items(c, {base = base, from = c.self, to = to, count = worldstate.inv_count(c.ws, c.db, c.self, base)})
	}
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

// move_items moves the counts and queues the move's inventory events for the next tick. A source
// gives at most what it holds. The container menu moves items through it too.
move_items :: proc(c: ^Call, m: worldstate.Item_Move) {
	m := m
	if m.from != 0 {
		m.count = min(m.count, worldstate.inv_count(c.ws, c.db, m.from, m.base))
		if m.count <= 0 {return}
		worldstate.inv_add(c.ws, m.from, m.base, -m.count)
		if m.from in c.ws.equipment && worldstate.inv_count(c.ws, c.db, m.from, m.base) == 0 {
			worldstate.unequip(c.ws, c.db, m.from, m.base) // the last one left
		}
	}
	if m.to != 0 {worldstate.inv_add(c.ws, m.to, m.base, m.count)}
	worldstate.carry(c.ws, c.db, m)
	worldstate.move_items(c.ws, m)
}

// DropObject(akObject, aiCount=1): the items leave `self` into the world beside it. A ref it
// carries of that item drops whole, as itself; otherwise a new ref holds the count.
n_drop_object :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(args, 0))
	if dropped := drop_object(c, c.self, base, ref, max(1, arg_i32(args, 1, 1))); dropped != 0 {return dropped}
	return nil
}

DROP_RADIUS :: 70 // 1 m
DROP_HEIGHT :: 48
DROP_STEP :: math.PI / 4

drop_object :: proc(c: ^Call, owner, base, ref: Form_ID, count: i32) -> Form_ID {
	ref := ref
	if ref == 0 || c.ws.carried[ref] != owner {
		refs := worldstate.carried_refs(c.ws, c.db, owner, base)
		ref = refs[0] if len(refs) > 0 else 0
	}
	count := worldstate.stack_count(c.ws, c.db, ref) if ref != 0 else count
	count = min(count, worldstate.inv_count(c.ws, c.db, owner, base))
	if count <= 0 {return 0}
	cell := ref_cell(c, owner)
	// Each drop lands at the next angle on a ring round the dropper, so items do not pile up.
	angle := f32(c.ws.drops) * DROP_STEP
	c.ws.drops += 1
	pos := ref_pos(c, owner) + {DROP_RADIUS * math.cos(angle), DROP_RADIUS * math.sin(angle), DROP_HEIGHT}
	if ref != 0 {
		worldstate.set_moved(c.ws, ref, cell, smath.trs(pos, {}, 1), pos)
		worldstate.set_disabled(c.ws, ref, cell, false)
	} else {
		ref = worldstate.create_ref(c.ws, base, cell, pos, {}, 1)
		(&c.ws.created[ref]).count = count
	}
	worldstate.mark_scene_dirty(c.ws, ref)
	move_items(c, {base = base, ref = ref, from = owner, count = count})
	return ref
}

// item_of splits an item argument into its base object and, when the argument is a reference, the ref.
@(private)
item_of :: proc(c: ^Call, form: Form_ID) -> (base, ref: Form_ID) {
	if cr, ok := c.ws.created[form]; ok {return cr.base, form}
	if r, ok := gamedb.ref_by_formid(c.db, form); ok {return r.base, form}
	return form, 0
}

n_get_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.inv_count(c.ws, c.db, c.self, formid.GOLD)
}
