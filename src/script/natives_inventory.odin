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
// WICourierScript.removeRefFromContainer calls it (docs/s5/todo.md P13). While the courier talks
// to the player it waits, as the script's IsInDialogueWithPlayer loop did (tick_courier).
n_courier_remove_ref :: proc(c: ^Call, args: []Value) -> Value {
	r := worldstate.Courier_Remove{arg_form(args, 0), arg_form(args, 1), arg_form(args, 2), arg_form(args, 4), arg_bool(args, 3, false)}
	if r.courier != 0 && c.ws.talking == r.courier {
		append(&c.ws.courier_waits, r)
	} else {
		courier_remove(c, r)
	}
	return nil
}

// tick_courier applies the removals whose courier stopped talking.
tick_courier :: proc(c: ^Call) {
	for i := 0; i < len(c.ws.courier_waits); {
		r := c.ws.courier_waits[i]
		if c.ws.talking == r.courier {
			i += 1
			continue
		}
		ordered_remove(&c.ws.courier_waits, i)
		courier_remove(c, r)
	}
}

@(private = "file")
courier_remove :: proc(c: ^Call, r: worldstate.Courier_Remove) {
	base, ref := item_of(c, r.item)
	if worldstate.inv_count(c.ws, c.db, r.container, base) <= 0 {return}
	move_items(c, {base = base, ref = ref, from = r.container, to = formid.PLAYER if r.to_player else 0, count = 1})
	if r.count != 0 {
		v, _ := worldstate.get_global(c.ws, r.count)
		worldstate.set_global(c.ws, r.count, v - 1)
	}
}

// AddItem(akItemToAdd, aiCount=1, …). A ref comes whole, out of the container or the world it was
// in. A leveled list adds what it rolls at the container's zone level.
n_add_item :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(args, 0))
	count := max(1, arg_i32(args, 1, 1))
	if ref == 0 {
		give_items(c, c.self, base, count)
	} else if holder, carried := c.ws.carried[ref]; carried {
		move_items(c, {base = base, ref = ref, from = holder, to = c.self, count = worldstate.stack_count(c.ws, c.db, ref)})
	} else if gamedb.is_item(c.db, base) {
		take(c, ref, base, c.self)
	}
	return nil
}

// give_items adds new items to `to`; a leveled list rolls at `to`'s zone level.
give_items :: proc(c: ^Call, to, base: Form_ID, count: i32) {
	if _, leveled := gamedb.leveled_list_of(c.db, base); !leveled {
		move_items(c, {base = base, to = to, count = count})
		return
	}
	rolled := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	level := worldstate.zone_level(c.ws, c.db, gamedb.zone_of(c.db, to))
	worldstate.roll(c.ws, c.db, base, level, count, &rolled)
	for e in rolled {move_items(c, {base = e.item, to = to, count = e.count})}
}

// take puts a world item in a container: its whole stack goes in and the ref leaves the world, carried.
take :: proc(c: ^Call, form, base, by: Form_ID) {
	n := worldstate.stack_count(c.ws, c.db, form)
	theft := report_theft(c, by, form, base, n)
	move_items(c, {base = base, ref = form, to = by, count = n, via = .Steal if theft else .World})
	if theft {worldstate.mark_stolen(c.ws, c.db, by, base, n)}
	worldstate.set_disabled(c.ws, form, worldstate.ref_cell(c.ws, c.db, form), true)
	worldstate.mark_scene_dirty(c.ws, form)
}

// report_theft reports `by` taking `count` of `base` from `from` (a loose item or a container), if
// that robs someone. True when it does: the caller marks what it took stolen.
report_theft :: proc(c: ^Call, by, from, base: Form_ID, count: i32) -> bool {
	victim := worldstate.robbed(c.ws, c.db, by, from)
	if victim == 0 {return false}
	value, _ := gamedb.value_of(c.db, base)
	worldstate.report_crime(c.ws, c.db, by, victim, .Steal, value * count)
	return true
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
// gives at most what it holds. A carried ref that a move by base takes along is its own move, so
// it hears OnContainerChanged. The container menu moves items through it too.
move_items :: proc(c: ^Call, m: worldstate.Item_Move) {
	m := m
	stolen: i32
	if m.from != 0 {
		m.count = min(m.count, worldstate.stolen_count(c.ws, c.db, m.from, m.base) if m.stolen else worldstate.inv_count(c.ws, c.db, m.from, m.base))
		if m.count <= 0 {return}
		stolen = worldstate.stolen_moved(c.ws, c.db, m)
		worldstate.mark_stolen(c.ws, c.db, m.from, m.base, -stolen)
		worldstate.inv_add(c.ws, m.from, m.base, -m.count)
		if m.from in c.ws.equipment && worldstate.inv_count(c.ws, c.db, m.from, m.base) == 0 {
			worldstate.unequip(c.ws, c.db, m.from, m.base) // the last one left
		}
	}
	if m.to != 0 {
		worldstate.inv_add(c.ws, m.to, m.base, m.count)
		worldstate.mark_stolen(c.ws, c.db, m.to, m.base, stolen)
	}
	rest := m
	for ref in worldstate.carry(c.ws, c.db, m) {
		n := worldstate.stack_count(c.ws, c.db, ref)
		worldstate.move_items(c.ws, {base = m.base, ref = ref, from = m.from, to = m.to, count = n, via = m.via})
		rest.count -= n
	}
	if rest.count > 0 {
		if m.ref == 0 && m.to != 0 {rest.ref = stack_into(c, m.to, m.base, rest.count)}
		worldstate.move_items(c.ws, rest)
	}
	queue_item_event(c, m)
}

// stack_into puts `count` of a scripted item arriving by count into the container's stack of it,
// a carried ref that holds the count and runs the item's scripts (Papyrus gives an inventory item its
// own instance). The first stack is new and returned; later ones join it and return 0. An item
// without scripts gets no ref.
@(private = "file")
stack_into :: proc(c: ^Call, container, base: Form_ID, count: i32) -> Form_ID {
	if len(gamedb.base_scripts(c.db, base)) == 0 {return 0}
	for ref in worldstate.carried_refs(c.ws, c.db, container, base) {
		if cr, ok := &c.ws.created[ref]; ok {
			cr.count = max(cr.count, 1) + count
			return 0
		}
	}
	return new_stack(c, container, base, count)
}

// item_stack is the ref an item in a container is to its scripts: a ref the container carries, or,
// for a scripted item no ref holds yet (starting contents), a new stack of all of it. 0 when there
// is neither.
item_stack :: proc(c: ^Call, container, base: Form_ID) -> Form_ID {
	if refs := worldstate.carried_refs(c.ws, c.db, container, base); len(refs) > 0 {return refs[0]}
	n := worldstate.inv_count(c.ws, c.db, container, base)
	if n <= 0 || len(gamedb.base_scripts(c.db, base)) == 0 {return 0}
	return new_stack(c, container, base, n)
}

@(private = "file")
new_stack :: proc(c: ^Call, container, base: Form_ID, count: i32) -> Form_ID {
	ref := worldstate.create_ref(c.ws, base, 0, {}, {}, 1)
	(&c.ws.created[ref]).count = count
	c.ws.carried[ref] = container
	return ref
}

// (hole item-event-owner :tags (quest player) :sev polish :needs (container-screen)) the player's AIPL and REMP story events name no owner and never say Buy or Pickpocket (a theft says Steal): nothing trades or pickpockets.
// queue_item_event makes items the player gains or loses a story event (AIPL / REMP):
// the container, the player's location, the item, how.
@(private = "file")
queue_item_event :: proc(c: ^Call, m: worldstate.Item_Move) {
	loc := worldstate.ref_location(c.ws, c.db, formid.PLAYER)
	switch formid.PLAYER {
	case m.to:
		worldstate.queue_story_event(c.ws, {type = worldstate.STORY_ADD_ITEM, ref2 = m.from, location1 = loc, object = m.base, value1 = i32(m.via)})
	case m.from:
		worldstate.queue_story_event(c.ws, {type = worldstate.STORY_REMOVE_ITEM, ref2 = m.ref, location1 = loc, object = m.base, value1 = i32(m.via)})
	}
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

drop_object :: proc(c: ^Call, owner, base, ref: Form_ID, count: i32, stolen := false) -> Form_ID {
	ref := ref
	if ref == 0 || c.ws.carried[ref] != owner {
		refs := worldstate.carried_refs(c.ws, c.db, owner, base)
		ref = refs[0] if len(refs) > 0 else 0
		if ref != 0 && ref in c.ws.created && worldstate.stack_count(c.ws, c.db, ref) > count {
			(&c.ws.created[ref]).count -= count // part of a stack drops: the stack keeps the rest
			ref = 0
		}
	}
	count := worldstate.stack_count(c.ws, c.db, ref) if ref != 0 else count
	count = min(count, worldstate.stolen_count(c.ws, c.db, owner, base) if stolen else worldstate.inv_count(c.ws, c.db, owner, base))
	if count <= 0 {return 0}
	cell := worldstate.ref_cell(c.ws, c.db, owner)
	// Each drop lands at the next angle on a ring round the dropper, so items do not pile up.
	angle := f32(c.ws.drops) * DROP_STEP
	c.ws.drops += 1
	pos := worldstate.ref_pos(c.ws, c.db, owner) + {DROP_RADIUS * math.cos(angle), DROP_RADIUS * math.sin(angle), DROP_HEIGHT}
	if ref != 0 {
		worldstate.set_moved(c.ws, ref, cell, smath.trs(pos, {}, 1), pos)
		worldstate.set_disabled(c.ws, ref, cell, false)
	} else {
		ref = worldstate.create_ref(c.ws, base, cell, pos, {}, 1)
		(&c.ws.created[ref]).count = count
	}
	worldstate.mark_scene_dirty(c.ws, ref)
	move_items(c, {base = base, ref = ref, from = owner, count = count, via = .World, stolen = stolen})
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
