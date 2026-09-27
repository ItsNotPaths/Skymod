package worldstate

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

// bounty is what `knower` knows its crime faction holds on `offender`: the faction-wide bounty,
// else its own local one.
// (hole crime-store :tags (combat save) :sev gap) no bounty store: nobody knows any bounty. Wanted: per (offender, crime faction) a faction-wide violent and nonviolent bounty, per knower a local one, infamy, the enemy and expelled flags, shared through the crime group (CRGR), saved.
bounty :: proc(ws: ^World_State, knower, offender: Form_ID) -> Bounty {
	return {}
}

// crime_faction is the faction an actor reports crimes to and guards for.
// (hole actor-crime-faction :tags (records script save combat) :sev gap) NPC_ CRIF is not decoded (1429 of 6362 NPC_ set one; all 477 guards; follow the factions template) and SetCrimeFaction has no store; a hold's LCTN FNAM (9, the "unreported crime faction") is unread, so GetCrimeFactionForHold has nothing.
crime_faction :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> Form_ID {
	return 0
}

// report_crime is an offence by `offender` against `victim` (an actor, or an owner for Steal and
// Trespass), worth `value` gold for a theft.
// (hole crime-report :tags (combat ai) :sev gap :needs (crime-store actor-crime-faction hostility)) an offence reaches nobody: wanted each member of a crime faction that has detected the offender to know the CRVA bounty (assault 40, murder 1000, theft value x0.5, pickpocket 25, trespass 5, escape 100, werewolf 1000; horse theft iCrimeGoldStealHorse 100) unless the faction ignores that crime, and the ASSU event. SendAssaultAlarm, SendStealAlarm and StopCombatAlarm (84 calls) do nothing. A hit or kill between hostile actors is no crime.
report_crime :: proc(ws: ^World_State, db: ^gamedb.DB, offender, victim: Form_ID, kind: Crime_Kind, value: i32) {
}

// spread_crime passes local bounties between the members of a crime faction, after detection.
// (hole crime-spread :tags (combat ai) :sev gap :needs (crime-store crime-report)) a local bounty never moves: wanted a member who knows it passing it to a member it detects (the higher bounty wins), faction-wide when a knower sees a guard of the faction (IsGuardFaction plus CRIF) or when half the members know it in a faction with no guards, and dropped when its last knower dies.
spread_crime :: proc(ws: ^World_State, db: ^gamedb.DB) {
}

// is_trespassing: the actor stands where its owner forbids it.
// (hole trespass :tags (combat world) :sev gap :needs (crime-report)) nobody trespasses: no check of owned cells (254, all interior) against the public flag (CELL DATA 0x20, 152) and locked doors, no warnings (iGuardWarnings 2, fAITrespassWarningTimer 5), no Trespass crime.
is_trespassing :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> bool {
	return false
}

// send_to_jail serves `actor`'s bounty with `faction`.
// (hole jail :tags (combat world player) :sev gap :needs (crime-store fact-crime-fields time-skip)) nobody goes to jail: wanted the move to the jail marker, the items to PLCN and stolen ones to STOL, the JOUT outfit, bounty/100 days at most 7 (UESP), skill progress lost (more skills for longer sentences, UESP), the bounty cleared and the JAIL event; SendPlayerToJail and ClearPrison are its natives. The vanilla scripts only watch; the engine does it all.
send_to_jail :: proc(ws: ^World_State, db: ^gamedb.DB, actor, faction: Form_ID) {
}
