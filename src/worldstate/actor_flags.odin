package worldstate

import "../formats/esm"
import "../gamedb"

// Flag_Override is the ACBS bits a script set on an actor or an NPC_: `mask` says which, `value`
// their state. The rest come from the records.
Flag_Override :: struct {
	mask, value: u32,
}

// set_actor_flag is Actor.SetGhost on an actor, or SetEssential, SetProtected or SetInvulnerable on
// an NPC_.
set_actor_flag :: proc(ws: ^World_State, form: Form_ID, bit: u32, on: bool) {
	if form == 0 {return}
	o := ws.actor_flags[form]
	o.mask |= bit
	o.value = o.value | bit if on else o.value &~ bit
	ws.actor_flags[form] = o
}

// actor_flag reads an ACBS bit of an actor or an NPC_: a script's setting on the actor, its leveled
// pick or its base, else the records through the base-data template.
actor_flag :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID, bit: u32) -> bool {
	base, pick := ref_base(ws, db, form), Form_ID(0)
	if base == 0 {base = form} else {pick = actor_pick(ws, db, form)}
	for f in ([]Form_ID{form, pick, base}) {
		if o, ok := ws.actor_flags[f]; ok && o.mask & bit != 0 {return o.value & bit != 0}
	}
	return gamedb.template_part(db, base, esm.ACBS_TEMPLATE_BASE_DATA, pick).flags & bit != 0
}
