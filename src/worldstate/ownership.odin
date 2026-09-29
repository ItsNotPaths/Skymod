package worldstate

import "core:slice"
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
	return 0 if o == 0 || owns(ws, db, taker, o) else o
}

// owns: what `owner` owns is `actor`'s to use: the owner is its own base, or a faction it is in.
owns :: proc(ws: ^World_State, db: ^gamedb.DB, actor, owner: Form_ID) -> bool {
	if owner == ref_base(ws, db, actor) {return true}
	_, is_faction := faction(ws, db, owner)
	return is_faction && in_faction(ws, db, actor, owner)
}

// (hole stolen-item-value :tags combat :sev polish) GetStolenItemValue (and Faction.GetStolenItemValueCrime/NoCrime) read 0: a mark knows whose item it was, not whether the theft was seen.
// Stolen is how many of one item a holder holds that were stolen from one owner.
Stolen :: struct {
	owner: Form_ID,
	count: i32,
}

// stolen_count is how many of the `item`s `holder` holds are stolen, from anyone.
stolen_count :: proc(ws: ^World_State, db: ^gamedb.DB, holder, item: Form_ID) -> i32 {
	n: i32
	for k, count in ws.stolen[holder] or_else nil {
		if k[0] == item {n += count}
	}
	return min(n, inv_count(ws, db, holder, item))
}

// mark_stolen marks `n` of `holder`'s `item`s as stolen from `owner`; an owner getting its own
// things back, or its faction's, holds them clean, and an item a theft does not mark stays clean.
mark_stolen :: proc(ws: ^World_State, db: ^gamedb.DB, holder, item, owner: Form_ID, n: i32) {
	if n <= 0 || owner == 0 || !takes_mark(ws, db, item) || owns(ws, db, holder, owner) {return}
	if holder not_in ws.stolen {ws.stolen[holder] = make(map[[2]Form_ID]i32)}
	(&ws.stolen[holder])^[{item, owner}] += n
}

// unmark_stolen takes `n` stolen marks off `holder`'s `item`s, the lowest owner first, and returns
// whose they were (temp-allocated).
unmark_stolen :: proc(ws: ^World_State, holder, item: Form_ID, n: i32) -> []Stolen {
	out := make([dynamic]Stolen, context.temp_allocator)
	marks, ok := &ws.stolen[holder]
	if !ok {return nil}
	owners := make([dynamic]Form_ID, context.temp_allocator)
	for k in marks {
		if k[0] == item {append(&owners, k[1])}
	}
	slice.sort(owners[:])
	left := n
	for o in owners {
		if left <= 0 {break}
		have := marks[{item, o}]
		take := min(have, left)
		append(&out, Stolen{o, take})
		left -= take
		if take == have {delete_key(marks, [2]Form_ID{item, o})} else {marks[{item, o}] = have - take}
	}
	return out[:]
}

// stolen_moved is how many of a move's items are stolen: the stolen stack's, else the stolen ones
// left once the clean ones are gone. `m.count` is what the source can give.
stolen_moved :: proc(ws: ^World_State, db: ^gamedb.DB, m: Item_Move) -> i32 {
	if m.from == 0 {return 0}
	have := stolen_count(ws, db, m.from, m.base)
	if m.stolen {return min(m.count, have)}
	return max(m.count - (inv_count(ws, db, m.from, m.base) - have), 0)
}

// takes_mark: a theft marks `item` stolen. One unit worth no more than iStolenMarkMaxValue (5; a
// plugin's GMST can change it) could be anyone's, so it stays clean: cups, pots, lockpicks, and gold,
// whose 500 coins are 500 units of 1. A mod's rt.stolen_mark overrides the rule for an item.
takes_mark :: proc(ws: ^World_State, db: ^gamedb.DB, item: Form_ID) -> bool {
	if marks, set := ws.stolen_marks[item]; set {return marks}
	value, _ := gamedb.value_of(db, item)
	return value > gamedb.setting_int(db, "iStolenMarkMaxValue", 5)
}

// set_stolen_mark is rt.stolen_mark: whether a theft marks `item`, whatever it is worth. Gold never
// is (the engine's rule; no record says so).
set_stolen_mark :: proc(ws: ^World_State, item: Form_ID, marks: bool) {
	ws.stolen_marks[item] = marks
}

// (hole item-tempering :tags (combat player save) :sev gap) no item is tempered: a stack is an item and a stolen flag, with no per-item quality, so no weapon or armor gets its smithing bonus, and Mod_Tempering_Health (11 SE entries) is not run.
// Item_Stack is one row of a holder's items: the clean ones stack, a stolen one never does.
Item_Stack :: struct {
	item:   Form_ID,
	stolen: bool,
	count:  i32,
}

// inv_stacks is `holder`'s items as rows: the clean ones of an item as one stack, then each stolen
// one on its own.
inv_stacks :: proc(ws: ^World_State, db: ^gamedb.DB, holder: Form_ID) -> []Item_Stack {
	out := make([dynamic]Item_Stack, context.temp_allocator)
	for item in inv_items(ws, db, holder) {
		n, s := inv_count(ws, db, holder, item), stolen_count(ws, db, holder, item)
		if n > s {append(&out, Item_Stack{item, false, n - s})}
		for _ in 0 ..< s {append(&out, Item_Stack{item, true, 1})}
	}
	return out[:]
}
