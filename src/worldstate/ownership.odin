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

// stolen: `taker` taking `form` is theft.
// (hole crime-owners :tags combat :sev gap) nothing is stolen: wanted the owner test (the taker's own base, a member of the owning faction at its XRNK rank, the ref's owner else its cell's), and the stolen mark the item keeps in the taker's inventory (vendors, STOL, GetStolenItemValue).
stolen :: proc(ws: ^World_State, db: ^gamedb.DB, taker, form: Form_ID) -> bool {
	return false
}
