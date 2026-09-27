package worldstate

import "../formid"
import "../gamedb"

// hostile: `actor` treats `other` as an enemy. Combat start and crime read only this. Crime turns
// to combat only here: a crime faction that marked `other` an enemy, or a known bounty at the
// attack-on-sight threshold in a faction that attacks on sight.
hostile :: proc(ws: ^World_State, db: ^gamedb.DB, actor, other: Form_ID) -> bool {
	if faction_relation(ws, db, actor, other) == .Enemy {return true}
	crime := crime_faction(ws, db, actor)
	if crime == 0 || jailed_by(ws, other, crime) {return false}
	if wanted(ws, other, crime).enemy {return true}
	f, _ := faction(ws, db, crime)
	if !f.crime.attack_on_detect {return false}
	b := bounty(ws, db, actor, other)
	return f32(b.violent) >= global_value(ws, db, formid.ATTACK_ON_SIGHT_VIOLENT) || f32(b.nonviolent) >= global_value(ws, db, formid.ATTACK_ON_SIGHT_NONVIOLENT)
}
