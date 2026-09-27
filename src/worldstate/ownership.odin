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
// (hole stolen-marks :tags (combat player) :sev gap) a stolen item keeps no mark: vendors buy it, jail and PlayerPayCrimeGold cannot take it, GetStolenItemValue reads nothing. XRNK (a required faction rank, 4 vanilla refs) is not decoded.
robbed :: proc(ws: ^World_State, db: ^gamedb.DB, taker, form: Form_ID) -> Form_ID {
	o := owner(ws, db, form)
	if o == 0 && !gamedb.is_actor(db, ref_base(ws, db, form)) {o = owner(ws, db, ref_cell(ws, db, form))}
	if o == 0 || o == ref_base(ws, db, taker) {return 0}
	if _, is_faction := faction(ws, db, o); is_faction && in_faction(ws, db, taker, o) {return 0}
	return o
}
