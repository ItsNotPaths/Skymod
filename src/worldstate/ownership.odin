package worldstate

import "../gamedb"

// set_owner is SetActorOwner or SetFactionOwner on a ref or a cell; 0 clears the owner.
set_owner :: proc(ws: ^World_State, form, owner: Form_ID) {
	if form != 0 {ws.owners[form] = owner}
}

// owner is a ref's or a cell's owner, an NPC_ or a FACT: a script's, else the records'. 0 when none.
// (hole crime-owners :tags combat :sev gap :needs (crime-reads)) ownership is stored and read, but taking or using an owned thing is no crime.
owner :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> Form_ID {
	if o, ok := ws.owners[form]; ok {return o}
	return gamedb.owner_of(db, form)
}
