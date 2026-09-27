package worldstate

import "../gamedb"

// hostile: `actor` treats `other` as an enemy. Combat start, crime and the Enemy conditions read
// only this.
// (hole hostility :tags (ai combat) :sev gap :needs (faction-reactions)) only an XNAM Enemy relation is hostile: no actor that knows a bounty on `other` over the threshold (CrimeArrestOnSight: 999 violent, 1000 nonviolent), no crime faction enemy flag (SetPlayerEnemy), no victim remembering who hit it, no StartCombat target.
hostile :: proc(ws: ^World_State, db: ^gamedb.DB, actor, other: Form_ID) -> bool {
	return faction_relation(ws, db, actor, other) == .Enemy
}
