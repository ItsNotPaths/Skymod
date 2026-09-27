package worldstate

import "../gamedb"

// faction is a faction's data now. Every reader outside gamedb goes through here, so a faction a
// mod made and a relation a script changed count everywhere a record's would.
// (hole script-factions :tags (mods script save combat) :sev gap) a mod cannot make a faction: wanted rt.faction from OnGameLoaded, get-or-create by name like rt.actor_value, a minted 0xFF form saved by name, with flags, ranks, relations and a crime table, so it can hold bounties, own things and have guards.
faction :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) -> (gamedb.Faction, bool) {
	return gamedb.faction_of(db, id)
}

// relation is how faction `from` stands toward `to`: a script's change, else its XNAM row.
relation :: proc(ws: ^World_State, db: ^gamedb.DB, from, to: Form_ID) -> (gamedb.Faction_Relation, bool) {
	if r, ok := ws.faction_relations[{from, to}]; ok {return r, true}
	f, _ := faction(ws, db, from)
	for r in f.relations {
		if r.faction == to {return r, true}
	}
	return {}, false
}

// set_relation is SetEnemy, SetAlly, SetReaction and ModReaction: one direction, from `from` to `to`.
set_relation :: proc(ws: ^World_State, from, to: Form_ID, r: gamedb.Faction_Relation) {
	r := r
	r.faction = to
	ws.faction_relations[{from, to}] = r
}
