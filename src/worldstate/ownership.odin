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
	o := ws.units[form].owner if form in ws.units else 0 // a stolen item is still its owner's
	if o == 0 {o = owner(ws, db, form)}
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
