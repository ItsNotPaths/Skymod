package worldstate

import "core:math/rand"
import "../formats/esm"
import "../formid"
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
	ws.crime_members_built = 0
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
// (hole crime-alarms :tags (combat script) :sev gap :needs (ai-combat-natives)) StopCombatAlarm (84 calls) and Faction.SendAssaultAlarm do nothing: no script reaches an actor's combat state.
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
	if knower == offender || is_dead(ws, db, knower) {return false}
	f := counts(ws, db, knower, kind) or_return
	add: i32
	switch kind {
	case .Steal:      add = i32(f32(value) * f.crime.steal_multiplier)
	case .Pickpocket: add = i32(f.crime.pickpocket)
	if kind in (bit_set[Crime_Kind]{.Assault, .Murder, .Pickpocket}) {ws.crime_victims[{victim, offender}] = true}
	if unreported_against(ws, db, victim) {return .Unreported}
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
// unreported_against: `victim` (an actor, or an owner) is, or is a member of, a faction whose members'
// crimes nobody reports (FACT DATA 0x800; 33 vanilla factions, the Companions among them).
@(private = "file")
unreported_against :: proc(ws: ^World_State, db: ^gamedb.DB, victim: Form_ID) -> bool {
	if f, ok := faction(ws, db, victim); ok {return f.flags & esm.FACT_DO_NOT_REPORT_CRIMES != 0}
	for id in actor_factions_now(ws, db, victim) {
		if f, _ := faction(ws, db, id); f.flags & esm.FACT_DO_NOT_REPORT_CRIMES != 0 {return true}
	}
	return false
}

}

// shared_crime_faction is GetInSharedCrimeFaction: `a` and `b` report to one crime faction, or `b`'s
// is in `a`'s crime group. A crime group is otherwise only data scripts walk (C03RampageQuest calls
// SetPlayerEnemy on each faction in CrimeFactionsList; CK Faction page: "other purposes are
// unknown"): no bounty is shared through it.
// (hole crime-group-reading :tags combat :sev polish) unsourced: GetInSharedCrimeFaction read as "same crime faction, or in the subject's crime group"; its 13 vanilla uses are quest conditions.
shared_crime_faction :: proc(ws: ^World_State, db: ^gamedb.DB, a, b: Form_ID) -> bool {
	fa, fb := crime_faction(ws, db, a), crime_faction(ws, db, b)
	if fa == 0 || fb == 0 {return false}
	if fa == fb {return true}
	f, _ := faction(ws, db, fa)
	return f.crime_group != 0 && list_has(ws, db, f.crime_group, fb)
}

// counts is the crime faction `knower` reports `kind` to, if it tracks crime and does not ignore it.
@(private = "file")
counts :: proc(ws: ^World_State, db: ^gamedb.DB, knower: Form_ID, kind: Crime_Kind) -> (gamedb.Faction, bool) {
	f, ok := faction(ws, db, crime_faction(ws, db, knower))
	if !ok || f.flags & esm.FACT_TRACK_CRIME == 0 || f.flags & IGNORES[kind] != 0 {return {}, false}
	return f, true
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
tick_crime :: proc(ws: ^World_State, db: ^gamedb.DB, dt: f32) {
	#reverse for &w, i in ws.victim_waits {
		w.wait -= dt
		if w.wait > 0 {continue}
		witness(ws, db, w.victim, w.offender, w.kind, 0)
		ordered_remove(&ws.victim_waits, i)
	}
	warn_trespassers(ws, db, dt)
	ws.spread_in -= dt
	if ws.spread_in <= 0 {
		ws.spread_in = SPREAD_EVERY
		spread_bounties(ws, db)
	}
	escaped := make([dynamic]Form_ID, context.temp_allocator)
	for actor, &j in ws.jailed {
		in_cell := ref_cell(ws, db, actor) == j.cell
		j.arrived ||= in_cell
		if j.arrived && !in_cell {
			append(&escaped, actor)
		} else if ws.clock.hours >= j.until {
			append(&ws.jail_orders, Jail_Order{actor = actor, faction = j.faction, release = true})
		}
	}
	for actor in escaped {escape_jail(ws, db, actor)}
}

SPREAD_EVERY :: f32(1) // seconds between spreads

// spread_bounties drops what dead knowers knew, passes each local bounty to the members of its
// faction the knower detects (the higher bounty wins), and makes it faction-wide when a guard of
// the faction knows it, or, in a faction with no living guard, when half its living members do.
@(private = "file")
spread_bounties :: proc(ws: ^World_State, db: ^gamedb.DB) {
	offenders := make(map[Form_ID][dynamic]Form_ID, context.temp_allocator) // knower -> what it knows of
	gone := make([dynamic][2]Form_ID, context.temp_allocator)
	for k in ws.known_bounties {
		if is_dead(ws, db, k[0]) {append(&gone, k);continue}
		if k[0] not_in offenders {offenders[k[0]] = make([dynamic]Form_ID, context.temp_allocator)}
		append(&offenders[k[0]], k[1])
	}
	for k in gone {delete_key(&ws.known_bounties, k)}

	for pair, a in ws.awareness {
		known_of, ok := offenders[pair[0]]
		if !a.detected || !ok || is_dead(ws, db, pair[1]) {continue}
		for o in known_of {
			k := ws.known_bounties[{pair[0], o}]
			if o != pair[1] && crime_faction(ws, db, pair[1]) == k.faction {learn_bounty(ws, db, pair[1], o, k.bounty)}
		}
	}

	Spread :: struct {knowers: int, best: Bounty}
	spread := make(map[[2]Form_ID]Spread, context.temp_allocator) // {offender, faction}
	wide := make([dynamic][2]Form_ID, context.temp_allocator)
	for k, known in ws.known_bounties {
		key := [2]Form_ID{k[1], known.faction}
		s := spread[key]
		spread[key] = {s.knowers + 1, higher(s.best, known.bounty)}
		if in_faction(ws, db, k[0], formid.IS_GUARD_FACTION) {append(&wide, key)}
	}
	for key, s in spread {
		living, guards := crime_census(ws, db, key[1])
		if guards == 0 && s.knowers * 2 >= living {append(&wide, key)}
	}
	for key in wide {go_wide(ws, key[0], key[1], spread[key].best)}
}

// go_wide makes `b` what every member of `faction` knows of `offender`; the local bounties it
// covers go.
@(private = "file")
go_wide :: proc(ws: ^World_State, offender, faction: Form_ID, b: Bounty) {
	w := higher(wanted(ws, offender, faction).bounty, b)
	set_faction_bounty(ws, offender, faction, w)
	covered := make([dynamic][2]Form_ID, context.temp_allocator)
	for k, known in ws.known_bounties {
		if k[1] == offender && known.faction == faction && total(known.bounty) <= total(w) {append(&covered, k)}
	}
	for k in covered {delete_key(&ws.known_bounties, k)}
}

// crime_census counts the living members and guards of a crime faction. The member list is
// built once from every placed and created actor and every actor a script gave a crime faction,
// and again after a SetCrimeFaction.
crime_census :: proc(ws: ^World_State, db: ^gamedb.DB, faction: Form_ID) -> (living, guards: int) {
	if ws.crime_members_built != len(ws.created) + 1 {
		for _, m in ws.crime_members {delete(m)}
		clear(&ws.crime_members)
		add :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) {
			f := ws.crime_factions[actor] or_else gamedb.actor_crime_faction(db, record_of(ws, actor)) // no leveled roll for a census
			if f == 0 {return}
			if f not_in ws.crime_members {ws.crime_members[f] = make([dynamic]Form_ID)}
			append(&ws.crime_members[f], actor)
		}
		if db != nil {
			for _, refs in db.actor_refs {
				for r in refs {
					if r.form_id not_in ws.crime_factions {add(ws, db, r.form_id)}
				}
			}
			for id, c in ws.created {
				if gamedb.is_actor(db, c.base) && id not_in ws.crime_factions {add(ws, db, id)}
			}
		}
		for id in ws.crime_factions {add(ws, db, id)}
		ws.crime_members_built = len(ws.created) + 1
	}
	members, ok := ws.crime_members[faction]
	if !ok {return}
	for m in members {
		if is_dead(ws, db, m) {continue}
		living += 1
		if in_faction(ws, db, m, formid.IS_GUARD_FACTION) {guards += 1}
	}
	return
}

// is_trespassing: the actor is in an owned interior that is not its to use and not public, while
// its owner has the load doors locked (LockDoors); a prisoner in its cell is not.
// (hole trespass-rule-source :tags (combat world) :sev polish) unsourced: trespass as "owned, not public, a load door locked" is read off the data (254 owned cells, all interior; the LockDoors procedure); the CK names no rule.
is_trespassing :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> bool {
	cell := ref_cell(ws, db, actor)
	c, ok := gamedb.cell_by_formid(db, cell)
	if !ok || !c.interior || c.public || actor in ws.jailed {return false}
	o := owner(ws, db, cell)
	if o == 0 || owns(ws, db, actor, o) {return false}
	for r in gamedb.refs_of(db, cell) {
		if r.teleport.door != 0 && gamedb.is_door(db, r.base) && is_locked(ws, db, r.form_id) {return true}
	}
	return false
}

// Trespass_Warning is how far `warner` has got warning a trespasser away.
Trespass_Warning :: struct {
	level:    i32, // GetTrespassWarningLevel: the warning it is on
	wait:     f32, // seconds to the next warning
	started:  bool,
	reported: bool,
}

// warn_trespassers has each actor that counts trespass warn the trespassers it detects: a TRES line
// every fAITrespassWarningTimer, iGuardWarnings times, then the Trespass crime. Leaving ends it.
@(private = "file")
warn_trespassers :: proc(ws: ^World_State, db: ^gamedb.DB, dt: f32) {
	trespassing := make(map[Form_ID]bool, context.temp_allocator)
	still := make(map[[2]Form_ID]bool, context.temp_allocator)
	for k, a in ws.awareness {
		warner, target := k[0], k[1]
		if !a.detected || is_dead(ws, db, warner) {continue}
		t, cached := trespassing[target]
		if !cached {
			t = is_trespassing(ws, db, target)
			trespassing[target] = t
		}
		if !t {continue}
		if _, ok := counts(ws, db, warner, .Trespass); !ok || hostile(ws, db, warner, target) {continue}
		still[k] = true
		w := ws.trespass_warnings[k]
		w.wait -= dt
		if w.wait <= 0 {
			w.wait = gamedb.setting_float(db, "fAITrespassWarningTimer", 5)
			if w.started {w.level += 1}
			w.started = true
			if w.level <= i32(gamedb.setting_int(db, "iGuardWarnings", 2)) {
				append(&ws.barks, Bark{speaker = warner, to = target, subtype = SUBTYPE_TRESPASS})
			} else if !w.reported {
				w.reported = true
				report_crime(ws, db, target, owner(ws, db, ref_cell(ws, db, target)), .Trespass, 0)
			}
		}
		ws.trespass_warnings[k] = w
	}
	gone := make([dynamic][2]Form_ID, context.temp_allocator)
	for k in ws.trespass_warnings {
		if k not_in still {append(&gone, k)}
	}
	for k in gone {delete_key(&ws.trespass_warnings, k)}
}

// trespass_warning is GetTrespassWarningLevel: the warning `warner` is on with `target`.
trespass_warning :: proc(ws: ^World_State, warner, target: Form_ID) -> i32 {
	return ws.trespass_warnings[{warner, target}].level
}

// Jailed is an actor serving a sentence. Its gear waits in the faction's evidence chest.
Jailed :: struct {
	faction: Form_ID,
	cell:    Form_ID, // the cell it was put in; leaving it is an escape
	arrived: bool, // it has stood in `cell`; before that no escape counts
	until:   f64, // game hours when the sentence is served
	outfit:  Form_ID, // the script outfit it wore before, 0 for its records'
}

// Jail_Order is a move into or out of jail for the app to carry out: the actor, its gear, its outfit.
Jail_Order :: struct {
	actor, faction, guard: Form_ID,
	release:               bool,
}

// jailed_by: `actor` serves a sentence for `faction`, whose members leave it be.
jailed_by :: proc(ws: ^World_State, actor, faction: Form_ID) -> bool {
	j, ok := ws.jailed[actor]
	return ok && j.faction == faction
}

// escape_jail is a prisoner out of its cell (user, 2026-09-27): no longer jailed, its bounty and
// the gear in the evidence chest stay, and the ESJA event goes out.
escape_jail :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) {
	j := ws.jailed[actor]
	delete_key(&ws.jailed, actor)
	f, _ := faction(ws, db, j.faction)
	queue_story_event(ws, {type = STORY_ESCAPE_JAIL, location1 = ref_location(ws, db, actor), form = f.crime_group})
}

// Jail_Spot is a place a jail puts an actor.
Jail_Spot :: struct {
	cell:     Form_ID,
	pos, rot: [3]f32,
}

// jail_spots are a faction's jail cell and its way out. Its two PrisonMarkers link to each other
// like load doors, and as with a door each spot is the arrival the partner marker's link sets.
jail_spots :: proc(ws: ^World_State, db: ^gamedb.DB, crime: Form_ID) -> (inside, outside: Jail_Spot, ok: bool) {
	f, _ := faction(ws, db, crime)
	out_marker := gamedb.ref_by_formid(db, f.jail) or_return
	in_marker := gamedb.ref_by_formid(db, out_marker.teleport.door) or_return
	if !out_marker.has_tp || !in_marker.has_tp {return}
	inside = {ref_cell(ws, db, in_marker.form_id), out_marker.teleport.pos, out_marker.teleport.rot}
	outside = {ref_cell(ws, db, out_marker.form_id), in_marker.teleport.pos, in_marker.teleport.rot}
	return inside, outside, true
}

// jail_days is the sentence for a bounty: 1 day per 100 gold, at most 7 (UESP).
jail_days :: proc(b: Bounty) -> i32 {
	return clamp(total(b) / 100, 1, 7)
}

// send_to_jail jails `actor` for its bounty with `faction`, whose jail's exterior marker (FACT
// JAIL) leads to the prison marker inside the cell. A faction with no jail jails nobody.
// (hole jail-escape :tags (combat player) :sev gap :needs (lockpicking)) no jailbreak bounty (CRVA escape) when a jail door is picked. SendPlayerToJail's abRealJail is read as true.
send_to_jail :: proc(ws: ^World_State, db: ^gamedb.DB, actor, crime, guard: Form_ID) -> bool {
	f, _ := faction(ws, db, crime)
	if f.jail == 0 || actor in ws.jailed {return false}
	append(&ws.jail_orders, Jail_Order{actor = actor, faction = crime, guard = guard})
	return true
}

// serve_time is ServeTime and a jailed actor's bed: the clock skips to the end of the sentence.
// Only the player's controller asks: a jailed NPC waits its days out on the running clock.
// (hole jail-bed-prompt :tags (ui combat) :sev polish :needs (message-box-screen)) the bed serves the sentence at once: no JailBedMsg (MESG 0x3403D) asks first.
serve_time :: proc(ws: ^World_State, actor: Form_ID) {
	if j, ok := ws.jailed[actor]; ok {skip_game_time(ws, j.until - ws.clock.hours)}
}

// lose_skill_progress clears the progress toward the next level of random skills: all 18 for a
// 7-day sentence, proportionally fewer for a shorter one (UESP).
lose_skill_progress :: proc(ws: ^World_State, actor: Form_ID, days: i32) {
	skills := gamedb.AV_NAMES[6:24]
	order := rand.perm(len(skills), context.temp_allocator)
	for i in order[:min(len(skills), int((i32(len(skills)) * days + 6) / 7))] {
		if advance, ok := gamedb.skill_advance_av(skills[i]); ok {av_set_base(ws, actor, advance, 0)}
	}
}
