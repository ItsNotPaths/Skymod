package worldstate

import "../gamedb"

// faction is a faction's data now. Every reader outside gamedb goes through here, so a faction a
// mod made and a relation a script changed count everywhere a record's would.
// (hole script-factions :tags (mods script save combat) :sev gap) a mod cannot make a faction: wanted rt.faction from OnGameLoaded, get-or-create by name like rt.actor_value, a minted 0xFF form saved by name, with flags, ranks, relations and a crime table, so it can hold bounties, own things and have guards.
faction :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) -> (gamedb.Faction, bool) {
	return gamedb.faction_of(db, id)
}
