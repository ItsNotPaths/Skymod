package script

// Inventory natives (mydocs/scripting-natives.md §B). `self` is the container/actor. A holder keeps
// plain items as counts of their base and items with data as units (worldstate/items.odin), which keep
// their ID in the world and out of it. Not scene geometry → no mark_scene_dirty, except a world item.

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
// WICourierScript.removeRefFromContainer calls it (mydocs/s5/todo.md P13). While the courier talks
// to the player it waits, as the script's IsInDialogueWithPlayer loop did (tick_courier).
n_courier_remove_ref :: proc(c: ^Call, args: []Value) -> Value {
	r := worldstate.Courier_Remove{arg_form(c, args, 0), arg_form(c, args, 1), arg_form(c, args, 2), arg_form(c, args, 4), arg_bool(args, 3, false)}
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
	move_items(c, {base = base, ref = ref, from = r.container, to = c.ws.player if r.to_player else 0, count = 1})
	if r.count != 0 {
		v, _ := worldstate.get_global(c.ws, r.count)
		worldstate.set_global(c.ws, r.count, v - 1)
	}
}

// AddItem(akItemToAdd, aiCount=1, …). A ref comes whole, out of the container or the world it was
// in. A leveled list adds what it rolls at the container's zone level.
n_add_item :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(c, args, 0))
	count := max(1, arg_i32(args, 1, 1))
	switch {
	case ref == 0:
		give_items(c, c.self, base, count)
	case c.ws.units[ref].holder != 0:
		move_items(c, {base = base, ref = ref, from = c.ws.units[ref].holder, to = c.self, count = 1})
	case gamedb.is_item(c.db, base):
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

// take puts a world item in `by`. A plain one becomes a count and leaves the world; one with data, or
// one a theft marks, keeps its ID as a unit (the rest of its placed stack become units of their own)
// and only loses its placement.
take :: proc(c: ^Call, form, base, by: Form_ID) {
	n := worldstate.stack_count(c.ws, c.db, form)
	victim := report_theft(c, by, form, base, n)
	via: worldstate.Item_Via = .Steal if victim != 0 else .World
	worldstate.mark_scene_dirty(c.ws, form)
	if !worldstate.has_data(c.ws, c.db, form) && !marks(c, by, base, victim) {
		worldstate.destroy_placed(c.ws, c.db, form)
		move_items(c, {base = base, to = by, count = n, via = via, robbed = victim})
		return
	}
	if form not_in c.ws.units {worldstate.add_unit(c.ws, c.db, form, {base = base})}
	if cr, ok := &c.ws.created[form]; ok {cr.count = 1}
	worldstate.unplace(c.ws, form)
	move_items(c, {base = base, ref = form, count = 1, to = by, via = via, robbed = victim})
	if n > 1 {move_items(c, {base = base, to = by, count = n - 1, via = via, robbed = victim})}
}

// marks: a theft from `victim` marks the items `by` takes stolen.
@(private = "file")
marks :: proc(c: ^Call, by, base, victim: Form_ID) -> bool {
	return victim != 0 && worldstate.takes_mark(c.ws, c.db, base) && !worldstate.owns(c.ws, c.db, by, victim)
}

// report_theft reports `by` taking `count` of `base` from `from` (a loose item or a container), if
// that robs someone, and returns whom: the caller marks what it took as stolen from them.
report_theft :: proc(c: ^Call, by, from, base: Form_ID, count: i32) -> Form_ID {
	victim := worldstate.robbed(c.ws, c.db, by, from)
	if victim == 0 {return 0}
	value, _ := gamedb.value_of(c.db, base)
	worldstate.report_crime(c.ws, c.db, by, victim, .Steal, value * count)
	return victim
}

// RemoveItem(akItemToRemove, aiCount=1, abSilent=false, akOtherContainer=None). With no other
// container the items are destroyed.
n_remove_item :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(c, args, 0))
	move_items(c, {base = base, ref = ref, from = c.self, to = arg_form(c, args, 3), count = max(1, arg_i32(args, 1, 1))})
	return nil
}

n_get_item_count :: proc(c: ^Call, args: []Value) -> Value {
	base, _ := item_of(c, arg_form(c, args, 0))
	return worldstate.inv_count(c.ws, c.db, c.self, base)
}

// RemoveAllItems(akTransferTo=None, …): one move per item type, in form order.
n_remove_all_items :: proc(c: ^Call, args: []Value) -> Value {
	to := arg_form(c, args, 0)
	for base in worldstate.inv_items(c.ws, c.db, c.self) {
		move_items(c, {base = base, from = c.self, to = to, count = worldstate.inv_count(c.ws, c.db, c.self, base)})
	}
	return nil
}

n_add_inventory_event_filter :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.add_item_filter(c.ws, c.self, arg_form(c, args, 0))
	return nil
}

n_remove_inventory_event_filter :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.remove_item_filter(c.ws, c.self, arg_form(c, args, 0))
	return nil
}

n_remove_all_inventory_event_filters :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.remove_item_filters(c.ws, c.self)
	return nil
}

// move_items moves items and queues their inventory events for the next tick. A source gives at most
// what it holds. With no destination they are destroyed. A plain item that arrives with data (a
// scripted base, a theft that marks it) becomes a unit; a stolen unit back with its owner is clean.
move_items :: proc(c: ^Call, m: worldstate.Item_Move) {
	m := m
	units, plain := pick(c, m)
	if m.from == 0 && m.ref not_in c.ws.units {plain = m.count} // new items
	m.count = plain + i32(len(units))
	if m.count <= 0 {return}
	if m.from != 0 {worldstate.inv_add(c.ws, m.from, m.base, -plain)}
	stolen := marks(c, m.to, m.base, m.robbed)
	if m.to != 0 && plain > 0 && (stolen || len(gamedb.base_scripts(c.db, m.base)) > 0) {
		for _ in 0 ..< plain {append(&units, worldstate.new_unit(c.ws, c.db, m.base, m.to))}
		plain = 0
	}
	if m.to != 0 {worldstate.inv_add(c.ws, m.to, m.base, plain)}
	if plain > 0 {worldstate.move_items(c.ws, {base = m.base, from = m.from, to = m.to, count = plain, via = m.via})}
	for id in units {
		worldstate.move_items(c.ws, {base = m.base, ref = id, from = m.from, to = m.to, count = 1, via = m.via})
		if m.to == 0 {
			worldstate.drop_unit(c.ws, c.db, id)
			continue
		}
		u := &c.ws.units[id]
		if stolen && u.owner == 0 {u.owner = m.robbed}
		if u.owner != 0 && worldstate.owns(c.ws, c.db, m.to, u.owner) {u.owner = 0}
		worldstate.set_holder(c.ws, c.db, id, m.to)
		worldstate.settle(c.ws, c.db, id)
	}
	unequip_gone(c, m.from, m.base)
	queue_item_event(c, m)
}

// unequip_gone takes `base` off `holder` once it has none left.
@(private = "file")
unequip_gone :: proc(c: ^Call, holder, base: Form_ID) {
	if holder in c.ws.equipment && worldstate.inv_count(c.ws, c.db, holder, base) == 0 {worldstate.unequip(c.ws, c.db, holder, base)}
}

// pick is what a move takes from its source: the named unit, else plain items first, then clean
// units, then stolen ones; only stolen ones when the move asks for them.
@(private = "file")
pick :: proc(c: ^Call, m: worldstate.Item_Move) -> (units: [dynamic]Form_ID, plain: i32) {
	units = make([dynamic]Form_ID, context.temp_allocator)
	if u, ok := c.ws.units[m.ref]; ok && m.ref != 0 {
		if u.holder == m.from {append(&units, m.ref)}
		return
	}
	if m.from == 0 {return}
	if !m.stolen {plain = min(m.count, worldstate.plain_count(c.ws, c.db, m.from, m.base))}
	held := worldstate.held_units(c.ws, m.from, m.base)
	for want_stolen in ([2]bool{false, true}) {
		if m.stolen && !want_stolen {continue}
		for id in held {
			if plain + i32(len(units)) >= m.count {return}
			if (c.ws.units[id].owner != 0) == want_stolen {append(&units, id)}
		}
	}
	return
}

// (hole item-event-owner :tags (quest player) :sev polish :needs (barter)) the player's AIPL and REMP story events name no owner and never say Buy or Pickpocket (a theft says Steal): nothing trades or pickpockets.
// queue_item_event makes items the player gains or loses a story event (AIPL / REMP):
// the container, the player's location, the item, how.
@(private = "file")
queue_item_event :: proc(c: ^Call, m: worldstate.Item_Move) {
	loc := worldstate.ref_location(c.ws, c.db, c.ws.player)
	switch c.ws.player {
	case m.to:
		worldstate.queue_story_event(c.ws, {type = worldstate.STORY_ADD_ITEM, ref2 = m.from, location1 = loc, object = m.base, value1 = i32(m.via)})
	case m.from:
		worldstate.queue_story_event(c.ws, {type = worldstate.STORY_REMOVE_ITEM, ref2 = m.ref, location1 = loc, object = m.base, value1 = i32(m.via)})
	}
}

// DropObject(akObject, aiCount=1): the items leave `self` into the world beside it. A unit drops as
// itself; plain items drop as one new ref that holds their count.
n_drop_object :: proc(c: ^Call, args: []Value) -> Value {
	base, ref := item_of(c, arg_form(c, args, 0))
	if dropped := drop_object(c, c.self, base, ref, max(1, arg_i32(args, 1, 1))); dropped != 0 {return dropped}
	return nil
}

DROP_RADIUS :: 70 // 1 m
DROP_HEIGHT :: 48
DROP_STEP :: math.PI / 4

drop_object :: proc(c: ^Call, owner, base, ref: Form_ID, count: i32, stolen := false) -> (first: Form_ID) {
	m := worldstate.Item_Move{base = base, ref = ref, from = owner, count = count, via = .World, stolen = stolen}
	units, plain := pick(c, m)
	m.count = plain + i32(len(units))
	if m.count <= 0 {return 0}
	cell := worldstate.ref_cell(c.ws, c.db, owner)
	for id in units {
		pos := drop_spot(c, owner)
		worldstate.set_moved(c.ws, id, cell, smath.trs(pos, {}, 1), pos)
		worldstate.set_holder(c.ws, c.db, id, 0)
		worldstate.mark_scene_dirty(c.ws, id)
		worldstate.move_items(c.ws, {base = base, ref = id, from = owner, count = 1, via = .World})
		if first == 0 {first = id}
	}
	if plain > 0 {
		worldstate.inv_add(c.ws, owner, base, -plain)
		r := worldstate.create_ref(c.ws, base, cell, drop_spot(c, owner), {}, 1)
		(&c.ws.created[r]).count = plain
		worldstate.mark_scene_dirty(c.ws, r)
		worldstate.move_items(c.ws, {base = base, ref = r, from = owner, count = plain, via = .World})
		if first == 0 {first = r}
	}
	unequip_gone(c, owner, base)
	queue_item_event(c, m)
	return
}

// drop_spot is where the next dropped item lands: the next angle on a ring round the dropper, so
// items do not pile up.
@(private = "file")
drop_spot :: proc(c: ^Call, owner: Form_ID) -> [3]f32 {
	angle := f32(c.ws.drops) * DROP_STEP
	c.ws.drops += 1
	return worldstate.ref_pos(c.ws, c.db, owner) + {DROP_RADIUS * math.cos(angle), DROP_RADIUS * math.sin(angle), DROP_HEIGHT}
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
