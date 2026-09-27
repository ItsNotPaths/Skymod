package worldstate

import "../formats/esm"
import "../gamedb"

// Crime is faction logic, for every actor (user, 2026-09-27). An offence gives the members of a
// crime faction who witness it a bounty on the offender. The bounty is local to the members who
// know it, and it spreads between them. It becomes faction-wide when a member who knows it sees a
// guard of the faction, or, in a faction with no guards, when half its members know it. A local
// bounty is gone when every member who knew it is dead. Combat only reads the bounty: an actor
// that knows one over the threshold is hostile (hostility.odin).
// The player-named natives (GetCrimeGold, PlayerPayCrimeGold) read ref 0x14's row.

Crime_Kind :: enum u8 {
	Steal,
	Pickpocket,
	Trespass,
	Assault,
	Murder,
	Escape,
	Werewolf,
}

VIOLENT_CRIMES :: bit_set[Crime_Kind]{.Assault, .Murder, .Escape, .Werewolf}

Bounty :: struct {
	violent, nonviolent: i32,
}

// Wanted is what a crime faction holds on an offender, faction-wide.
Wanted :: struct {
	bounty: Bounty,
	enemy:  bool, // SetPlayerEnemy: the faction attacks the offender
}

// Known_Bounty is a bounty only its knower holds, for the knower's crime faction at the time.
Known_Bounty :: struct {
	faction: Form_ID,
	bounty:  Bounty,
}

total :: proc(b: Bounty) -> i32 {return b.violent + b.nonviolent}

// higher is the bounty with the larger total: a spreading bounty overrides a lower one.
higher :: proc(a, b: Bounty) -> Bounty {return a if total(a) >= total(b) else b}

// wanted is what `faction` holds on `offender` faction-wide.
wanted :: proc(ws: ^World_State, offender, faction: Form_ID) -> Wanted {
	return ws.wanted[{offender, faction}]
}

set_wanted :: proc(ws: ^World_State, offender, faction: Form_ID, w: Wanted) {
	if w == {} {
		delete_key(&ws.wanted, [2]Form_ID{offender, faction})
		return
	}
	ws.wanted[{offender, faction}] = w
}

set_faction_bounty :: proc(ws: ^World_State, offender, faction: Form_ID, b: Bounty) {
	w := wanted(ws, offender, faction)
	w.bounty = {max(b.violent, 0), max(b.nonviolent, 0)}
	set_wanted(ws, offender, faction, w)
}

// bounty is what `knower` knows its crime faction holds on `offender`: the faction-wide bounty or
// its own local one, whichever is higher.
bounty :: proc(ws: ^World_State, db: ^gamedb.DB, knower, offender: Form_ID) -> Bounty {
	faction := crime_faction(ws, db, knower)
	if faction == 0 {return {}}
	b := wanted(ws, offender, faction).bounty
	if k, ok := ws.known_bounties[{knower, offender}]; ok && k.faction == faction {b = higher(b, k.bounty)}
	return b
}

// learn_bounty gives `knower` a local bounty on `offender`; a higher one it already knows stays.
learn_bounty :: proc(ws: ^World_State, db: ^gamedb.DB, knower, offender: Form_ID, b: Bounty) {
	faction := crime_faction(ws, db, knower)
	if faction == 0 {return}
	ws.known_bounties[{knower, offender}] = {faction, higher(bounty(ws, db, knower, offender), b)}
}

// pay_bounty clears what `faction` holds on `offender`, faction-wide and in every member's memory.
pay_bounty :: proc(ws: ^World_State, offender, faction: Form_ID) {
	w := wanted(ws, offender, faction)
	w.bounty = {}
	set_wanted(ws, offender, faction, w)
	paid := make([dynamic][2]Form_ID, context.temp_allocator)
	for k, b in ws.known_bounties {
		if k[1] == offender && b.faction == faction {append(&paid, k)}
	}
	for k in paid {delete_key(&ws.known_bounties, k)}
}

// forget_bounty drops what `knower` alone knows of `offender`.
forget_bounty :: proc(ws: ^World_State, knower, offender: Form_ID) {
	delete_key(&ws.known_bounties, [2]Form_ID{knower, offender})
}

// set_reports_crime is Game.SetPlayerReportCrime for any offender: false keeps its crimes unreported.
set_reports_crime :: proc(ws: ^World_State, offender: Form_ID, reports: bool) {
	set_in_set(&ws.unreported, offender, !reports)
}

// crime_faction is the faction an actor reports crimes to and guards for: a script's, else its CRIF.
crime_faction :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> Form_ID {
	if f, ok := ws.crime_factions[actor]; ok {return f}
	return gamedb.actor_crime_faction(db, record_of(ws, actor), actor_pick(ws, db, actor))
}

// set_crime_faction is SetCrimeFaction; 0 leaves the actor with none.
set_crime_faction :: proc(ws: ^World_State, actor, faction: Form_ID) {
	ws.crime_factions[actor] = faction
}

// VICTIM_DELAY is how long after a violent crime its victim counts as a witness (user, 2026-09-27):
// a victim killed by the next blow never reports, and no hit races the one before it.
VICTIM_DELAY :: f32(2)

// Victim_Wait is a victim that becomes a witness when `wait` runs out.
Victim_Wait :: struct {
	victim, offender: Form_ID,
	kind:             Crime_Kind,
	wait:             f32,
}

// Crime_Status is a story event's crime value: whether the act was a crime, and whether anyone knows.
Crime_Status :: enum i32 {
	None,
	Unreported,
	Reported,
}

// report_crime is an offence by `offender` against `victim` (an actor, or an owner for Steal and
// Trespass), worth `value` gold for a theft. Each member of a crime faction that detects the
// offender learns the bounty its faction's CRVA sets. The victim of a violent crime learns it
// VICTIM_DELAY later, if it is still alive. A hit or kill between hostile actors is no crime.
// (hole crime-alarms :tags (combat script) :sev gap :needs (combat-any-target)) SendAssaultAlarm, SendStealAlarm and StopCombatAlarm (84 calls) do nothing: an alarm is a crime reported against the player plus combat, and combat has no target but the player.
report_crime :: proc(ws: ^World_State, db: ^gamedb.DB, offender, victim: Form_ID, kind: Crime_Kind, value: i32) -> Crime_Status {
	if offender == 0 || offender == victim || offender in ws.unreported {return .None}
	if kind in VIOLENT_CRIMES && (hostile(ws, db, victim, offender) || hostile(ws, db, offender, victim)) {return .None}
	status := Crime_Status.Unreported
	for k, a in ws.awareness {
		if k[1] == offender && a.detected && witness(ws, db, k[0], offender, kind, value) {status = .Reported}
	}
	if kind in VIOLENT_CRIMES {append(&ws.victim_waits, Victim_Wait{victim, offender, kind, VICTIM_DELAY})}
	if kind == .Assault {
		queue_story_event(ws, {type = STORY_ASSAULT, ref1 = victim, ref2 = offender, location1 = ref_location(ws, db, victim), value1 = i32(status)})
	}
	return status
}

// witness gives `knower` the bounty its crime faction sets for the offence, if it counts one.
@(private = "file")
witness :: proc(ws: ^World_State, db: ^gamedb.DB, knower, offender: Form_ID, kind: Crime_Kind, value: i32) -> bool {
	if knower == offender || is_dead(ws, knower) {return false}
	crime := crime_faction(ws, db, knower)
	f, ok := faction(ws, db, crime)
	if !ok || f.flags & esm.FACT_TRACK_CRIME == 0 || f.flags & (esm.FACT_DO_NOT_REPORT_CRIMES | IGNORES[kind]) != 0 {return false}
	add: i32
	switch kind {
	case .Steal:      add = i32(f32(value) * f.crime.steal_multiplier)
	case .Pickpocket: add = i32(f.crime.pickpocket)
	case .Trespass:   add = i32(f.crime.trespass)
	case .Assault:    add = i32(f.crime.assault)
	case .Murder:     add = i32(f.crime.murder)
	case .Escape:     add = i32(f.crime.escape)
	case .Werewolf:   add = i32(f.crime.werewolf)
	}
	if add <= 0 {return false}
	b := bounty(ws, db, knower, offender)
	if kind in VIOLENT_CRIMES {b.violent += add} else {b.nonviolent += add}
	learn_bounty(ws, db, knower, offender, b)
	return true
}

// IGNORES is the FACT flag that makes a faction ignore each crime.
@(private = "file")
IGNORES := [Crime_Kind]u32 {
	.Steal      = esm.FACT_IGNORE_STEALING,
	.Pickpocket = esm.FACT_IGNORE_PICKPOCKET,
	.Trespass   = esm.FACT_IGNORE_TRESPASS,
	.Assault    = esm.FACT_IGNORE_ASSAULT,
	.Murder     = esm.FACT_IGNORE_MURDER,
	.Escape     = 0,
	.Werewolf   = esm.FACT_IGNORE_WEREWOLF,
}

// tick_crime runs crime's clocks after detection: victims turning witness, and bounties spreading.
// (hole crime-spread :tags (combat ai) :sev gap) a local bounty never moves: wanted a member who knows it passing it to a member it detects (the higher bounty wins), faction-wide when a knower sees a guard of the faction (IsGuardFaction plus CRIF) or when half the members know it in a faction with no guards, and dropped when its last knower dies.
tick_crime :: proc(ws: ^World_State, db: ^gamedb.DB, dt: f32) {
	#reverse for &w, i in ws.victim_waits {
		w.wait -= dt
		if w.wait > 0 {continue}
		witness(ws, db, w.victim, w.offender, w.kind, 0)
		ordered_remove(&ws.victim_waits, i)
	}
}

// is_trespassing: the actor stands where its owner forbids it.
// (hole trespass :tags (combat world) :sev gap) nobody trespasses: no check of owned cells (254, all interior) against the public flag (CELL DATA 0x20, 152) and locked doors, no warnings (iGuardWarnings 2, fAITrespassWarningTimer 5), no Trespass crime.
is_trespassing :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> bool {
	return false
}

// send_to_jail serves `actor`'s bounty with `faction`.
// (hole jail :tags (combat world player) :sev gap :needs (time-skip)) nobody goes to jail: wanted the move to the jail marker, the items to PLCN and stolen ones to STOL, the JOUT outfit, bounty/100 days at most 7 (UESP), skill progress lost (more skills for longer sentences, UESP), the bounty cleared and the JAIL event; SendPlayerToJail and ClearPrison are its natives. The vanilla scripts only watch; the engine does it all.
send_to_jail :: proc(ws: ^World_State, db: ^gamedb.DB, actor, faction: Form_ID) {
}
