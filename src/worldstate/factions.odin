package worldstate

import "core:strings"
import "../formid"
import "../gamedb"

// faction is a faction's data now. Every reader outside gamedb goes through here, so a faction a
// script made and a relation a script changed count everywhere a record's would.
faction :: proc(ws: ^World_State, db: ^gamedb.DB, id: Form_ID) -> (gamedb.Faction, bool) {
	if s, ok := ws.script_factions[id]; ok {return s.data, true}
	return gamedb.faction_of(db, id)
}

// Script_Faction is a faction a script made at runtime (rt.faction). It is game state: saved whole,
// its relations kept as relation deltas like any faction's.
Script_Faction :: struct {
	name: string, // owned
	data: gamedb.Faction, // ranks owned; relations stay nil
}

// make_faction is the script faction called `name`, made from `f` when there is none yet; one that
// exists comes back unchanged. `f`'s ranks become the store's.
make_faction :: proc(ws: ^World_State, name: string, f: gamedb.Faction) -> (Form_ID, bool) {
	n: u32
	for id, s in ws.script_factions {
		if strings.equal_fold(s.name, name) {
			free_ranks(f.ranks)
			return id, false
		}
		n = max(n, u32(id))
	}
	id := formid.script_faction(n + 1)
	ws.script_factions[id] = {strings.clone(name), f}
	return id, true
}

free_ranks :: proc(ranks: []gamedb.Faction_Rank) {
	for r in ranks {delete(r.male_title);delete(r.female_title)}
	delete(ranks)
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
