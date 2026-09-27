package worldstate

import "../gamedb"

// set_owner is SetActorOwner or SetFactionOwner on a ref or a cell; 0 clears the owner.
set_owner :: proc(ws: ^World_State, form, owner: Form_ID) {
	if form != 0 {ws.owners[form] = owner}
}

// owner is a ref's or a cell's owner, an NPC_ or a FACT: a script's, else the records'. 0 when none.
owner :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> Form_ID {
	if o, ok := ws.owners[form]; ok {return o}
	return gamedb.owner_of(db, form)
}

// robbed is the owner `taker` robs by taking from `form` (an item or a container): the ref's owner,
// else its cell's unless it is an actor. Its own base's things and its factions' are no theft.
// 0 when the take is no theft.
// (hole ownership-rank :tags (combat records) :sev polish) XRNK, the faction rank an owning faction's member needs to take freely (4 vanilla refs, College of Winterhold rank 6), is not decoded.
robbed :: proc(ws: ^World_State, db: ^gamedb.DB, taker, form: Form_ID) -> Form_ID {
	o := owner(ws, db, form)
	if o == 0 && !gamedb.is_actor(db, ref_base(ws, db, form)) {o = owner(ws, db, ref_cell(ws, db, form))}
	if o == 0 || o == ref_base(ws, db, taker) {return 0}
	if _, is_faction := faction(ws, db, o); is_faction && in_faction(ws, db, taker, o) {return 0}
	return o
}

// (hole stolen-owner :tags (combat player) :sev gap) a stolen mark does not remember whose the item was: dropped, it lands clean (vanilla keeps the victim as its owner), handing it back does not clear it, and GetStolenItemValue(Crime/NoCrime) cannot split by faction.
// stolen_count is how many of the `item`s `holder` holds are stolen.
stolen_count :: proc(ws: ^World_State, db: ^gamedb.DB, holder, item: Form_ID) -> i32 {
	inner, _ := ws.stolen[holder]
	return min(inner[item], inv_count(ws, db, holder, item))
}

// mark_stolen changes how many of `holder`'s `item`s are stolen.
mark_stolen :: proc(ws: ^World_State, db: ^gamedb.DB, holder, item: Form_ID, n: i32) {
	inner := delta_upsert(&ws.stolen, holder)
	left := stolen_count(ws, db, holder, item) + n
	if left <= 0 {delete_key(inner, item)} else {inner^[item] = left}
}

// stolen_moved is how many of a move's items are stolen: the stolen stack's, else the stolen ones
// left once the clean ones are gone. `m.count` is what the source can give.
stolen_moved :: proc(ws: ^World_State, db: ^gamedb.DB, m: Item_Move) -> i32 {
	if m.from == 0 {return 0}
	have := stolen_count(ws, db, m.from, m.base)
	if m.stolen {return min(m.count, have)}
	return max(m.count - (inv_count(ws, db, m.from, m.base) - have), 0)
}

// Item_Stack is one row of a holder's items: the stolen ones stack apart from the rest.
Item_Stack :: struct {
	item:   Form_ID,
	stolen: bool,
	count:  i32,
}

// inv_stacks is `holder`'s items as stacks, a stolen stack after the clean one of the same item.
inv_stacks :: proc(ws: ^World_State, db: ^gamedb.DB, holder: Form_ID) -> []Item_Stack {
	out := make([dynamic]Item_Stack, context.temp_allocator)
	for item in inv_items(ws, db, holder) {
		n, s := inv_count(ws, db, holder, item), stolen_count(ws, db, holder, item)
		if n > s {append(&out, Item_Stack{item, false, n - s})}
		if s > 0 {append(&out, Item_Stack{item, true, s})}
	}
	return out[:]
}
