package worldstate

import "core:log"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"
import "../formid"

// inv_add adjusts owner's delta of `item` from its starting contents; negative when it holds fewer
// than it started with. The caller clamps against the starting count.
inv_add :: proc(ws: ^World_State, owner, item: Form_ID, delta: i32) {
	inner := delta_upsert(&ws.inventories, owner)
	n := inner^[item] + delta
	if n == 0 {
		delete_key(inner, item)
	} else {
		inner^[item] = n
	}
}

// ref_base is a record or created ref's base form, 0 for neither.
ref_base :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> Form_ID {
	if cr, ok := ws.created[ref]; ok {return cr.base}
	r, _ := gamedb.ref_by_formid(db, ref)
	return r.base
}

// display_name is a form's name: the one an alias gave it, else its base_name.
display_name :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> string {
	if n, ok := ws.display_names[form]; ok {return n}
	return base_name(ws, db, form)
}

set_display_name :: proc(ws: ^World_State, form: Form_ID, name: string) {
	clear_display_name(ws, form)
	ws.display_names[form] = strings.clone(name)
}

clear_display_name :: proc(ws: ^World_State, form: Form_ID) {
	if n, ok := ws.display_names[form]; ok {delete(n)}
	delete_key(&ws.display_names, form)
}

// base_name is a form's own name, an actor's through its templates.
base_name :: proc(ws: ^World_State, db: ^gamedb.DB, form: Form_ID) -> string {
	if n := gamedb.name_of(db, form); n != "" {return n}
	base := ref_base(ws, db, form)
	return gamedb.actor_name(db, base if base != 0 else form, actor_pick(ws, db, form))
}

// stack_count is how many items a world item ref is: its XCNT, or a dropped stack's size.
stack_count :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> i32 {
	if cr, ok := ws.created[ref]; ok {return max(cr.count, 1)}
	r, _ := gamedb.ref_by_formid(db, ref)
	return max(r.count, 1)
}

// carry records where an item move leaves its refs (after the counts moved). A named ref goes with
// the move, or is gone when the move has no destination. A move by base takes the source's carried
// refs of that base along while they hold more than the source has left, and returns them
// (temp-allocated). A created stack that holds more than has to go splits: it stays with the rest,
// and the units that go move by count.
carry :: proc(ws: ^World_State, db: ^gamedb.DB, m: Item_Move) -> (taken: []Form_ID) {
	if m.ref != 0 {
		if m.to != 0 {ws.carried[m.ref] = m.to} else {delete_key(&ws.carried, m.ref)}
		return
	}
	if m.from == 0 {return}
	refs := carried_refs(ws, db, m.from, m.base)
	total: i32
	for r in refs {total += stack_count(ws, db, r)}
	left := inv_count(ws, db, m.from, m.base)
	i := len(refs)
	for i > 0 && total > left {
		i -= 1
		n := stack_count(ws, db, refs[i])
		if cr, ok := &ws.created[refs[i]]; ok && n > total - left {
			cr.count = n - (total - left)
			return refs[i + 1:]
		}
		total -= n
		if m.to != 0 {ws.carried[refs[i]] = m.to} else {delete_key(&ws.carried, refs[i])}
	}
	return refs[i:]
}

// carried_refs lists the refs of `base` that `holder` carries, in form order.
carried_refs :: proc(ws: ^World_State, db: ^gamedb.DB, holder, base: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for ref, h in ws.carried {
		if h == holder && ref_base(ws, db, ref) == base {append(&out, ref)}
	}
	slice.sort(out[:])
	return out[:]
}

// inv_delta returns owner's delta of item from its starting contents.
inv_delta :: proc(ws: ^World_State, owner, item: Form_ID) -> i32 {
	if inner, ok := ws.inventories[owner]; ok {
		return inner[item]
	}
	return 0
}

// inv_count is owner's count of item: its starting contents plus the delta. A leveled list is never
// an item.
inv_count :: proc(ws: ^World_State, db: ^gamedb.DB, owner, item: Form_ID) -> i32 {
	if _, leveled := gamedb.leveled_list_of(db, item); leveled {return 0}
	n := inv_delta(ws, owner, item)
	for e in inv_start(ws, db, owner) {
		if e.item == item {n += e.count}
	}
	return max(n, 0)
}

// inv_items is every item owner holds, in form order: its starting contents and what changed since.
inv_items :: proc(ws: ^World_State, db: ^gamedb.DB, owner: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for e in inv_start(ws, db, owner) {
		if inv_count(ws, db, owner, e.item) > 0 {append(&out, e.item)}
	}
	if delta, ok := ws.inventories[owner]; ok {
		for item in delta {
			if !slice.contains(out[:], item) && inv_count(ws, db, owner, item) > 0 {append(&out, item)}
		}
	}
	slice.sort(out[:])
	return out[:]
}

// inv_weight is what everything owner holds weighs.
inv_weight :: proc(ws: ^World_State, db: ^gamedb.DB, owner: Form_ID) -> f32 {
	total: f32
	for item in inv_items(ws, db, owner) {
		w, _ := gamedb.weight_of(db, item)
		total += w * f32(inv_count(ws, db, owner, item))
	}
	return total
}

// (hole encumbrance :tags player :sev gap) an actor over its CarryWeight still runs: nothing reads over_encumbered to slow it.
// over_encumbered: the actor carries more than its CarryWeight.
over_encumbered :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> bool {
	return inv_weight(ws, db, actor) > av_current(ws, db, actor, "CarryWeight")
}

// record_of is the form whose records describe a ref: a created ref's base, else the ref, which
// gamedb follows to its base.
record_of :: proc(ws: ^World_State, ref: Form_ID) -> Form_ID {
	if cr, ok := ws.created[ref]; ok {return cr.base}
	return ref
}

// actor_box is an actor's bounds box at its current scale, relative to its feet.
actor_box :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> [2][3]f32 {
	box := gamedb.actor_bounds(db, record_of(ws, ref), actor_pick(ws, db, ref))
	s := ref_scale(ws, db, ref)
	return {box[0] * s, box[1] * s}
}

// ── actor values (actor -> AV name -> its parts) ──────────────────────────────────────────────
// Skyrim's model (CK wiki, Actor Value): current = base + permanent + damage, max = base +
// permanent. The temporary modifier arrives with effect magnitudes. `av` is always a canonical name
// (av_name): an AV_NAMES entry or a mod AV's name, which mod_avs owns.

Actor_Value :: struct {
	base:      Maybe(f32), // SetActorValue's base; none = the records' base
	permanent: f32,        // ModActorValue, ForceActorValue
	damage:    f32,        // DamageActorValue; never above 0
	cap:       Maybe(f32), // a pool's capacity; none = gamedb.SKILL_CAP
	pause:     f32,        // seconds before regen restores damage again (not saved)
}

@(private)
av_upsert :: proc(ws: ^World_State, actor: Form_ID, av: string) -> ^Actor_Value {
	if _, ok := ws.actor_values[actor]; !ok {
		ws.actor_values[actor] = make(map[string]Actor_Value)
	}
	inner := &ws.actor_values[actor]
	if av not_in inner {inner[av] = {}}
	return &inner[av]
}

@(private)
av_parts :: proc(ws: ^World_State, actor: Form_ID, av: string) -> Actor_Value {
	if inner, ok := ws.actor_values[actor]; ok {return inner[av]}
	return {}
}

av_base :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	if b, ok := av_parts(ws, actor, av).base.?; ok {return b}
	if m, ok := mod_av(ws, av); ok {return m.default}
	return gamedb.actor_value_base(db, record_of(ws, actor), av, actor_pick(ws, db, actor), int(player_level(ws, db)))
}

// av_max is an AV's capacity: a pool's cap, else base + permanent (GetActorValueMax).
av_max :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	p := av_parts(ws, actor, av)
	if av_kind(ws, av) == .Pool {return (p.cap.? or_else gamedb.SKILL_CAP) + av_live(ws, db, actor, av)}
	return av_base(ws, db, actor, av) + p.permanent + av_live(ws, db, actor, av)
}

// av_train_cap is the level training stops at: a pool's capacity, else the cap SetActorValueCap set.
av_train_cap :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	if av_kind(ws, av) == .Pool {return av_max(ws, db, actor, av)}
	return av_parts(ws, actor, av).cap.? or_else gamedb.SKILL_CAP
}

// av_current is an AV's value: a pool's own stock, else its capacity plus damage.
av_current :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	p := av_parts(ws, actor, av)
	if av_kind(ws, av) == .Pool {return av_base(ws, db, actor, av) + p.permanent + p.damage}
	return av_max(ws, db, actor, av) + p.damage
}

// av_kind is an actor value's kind: the engine's, or what the mod that created it said.
av_kind :: proc(ws: ^World_State, av: string) -> gamedb.AV_Kind {
	if m, ok := mod_av(ws, av); ok {return m.kind}
	return gamedb.av_kind(av)
}

// av_set_cap sets the soft cap training stops at (a pool's capacity); false for a static AV.
av_set_cap :: proc(ws: ^World_State, actor: Form_ID, av: string, cap: f32) -> bool {
	if av_kind(ws, av) == .Static {return false}
	av_upsert(ws, actor, av).cap = cap
	return true
}

// Knob is what an effect term turns. Capacity: held while the effect runs, gone when it ends.
// Amount: a running total whose gains stay (av_gain).
Knob :: enum {
	Capacity,
	Amount,
}

// av_gain adds an effect's amount gain: to a latched AV's damage (a loss pauses regen), else to
// its permanent modifier.
av_gain :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string, gain: f32) {
	switch {
	case av_kind(ws, av) != .Latched: av_mod(ws, actor, av, gain)
	case gain < 0:                    av_damage(ws, db, actor, av, gain)
	case:                             av_restore(ws, actor, av, gain)
	}
}

// av_set_base is SetActorValue: the base changes, the modifiers stay.
av_set_base :: proc(ws: ^World_State, actor: Form_ID, av: string, value: f32) {
	av_upsert(ws, actor, av).base = value
}

// av_mod is ModActorValue: the max moves with the permanent modifier.
av_mod :: proc(ws: ^World_State, actor: Form_ID, av: string, delta: f32) {
	av_upsert(ws, actor, av).permanent += delta
}

// av_force is ForceActorValue: the permanent modifier takes what makes the current value `value`.
av_force :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string, value: f32) {
	av_mod(ws, actor, av, value - av_current(ws, db, actor, av))
}

// av_damage is DamageActorValue; a negative amount damages too. A drop pauses regen briefly, and
// longer when the value reaches 0.
av_damage :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string, amount: f32) {
	p := av_upsert(ws, actor, av)
	p.damage -= abs(amount)
	for r in REGEN {
		if r.av != av {continue}
		pause := gamedb.setting_float(db, r.pause, 1)
		if av_current(ws, db, actor, av) <= 0 {pause = gamedb.setting_float(db, r.pause_max, 5)}
		p.pause = max(p.pause, pause)
	}
}

// av_restore is RestoreActorValue: it removes damage, never past none.
av_restore :: proc(ws: ^World_State, actor: Form_ID, av: string, amount: f32) {
	p := av_upsert(ws, actor, av)
	p.damage = min(p.damage + abs(amount), 0)
}

// ── regen ──
// Damaged Health, Magicka and Stamina come back at max x Rate/100 x RateMult/100 per second of play,
// on every actor, loaded or not (sources: build/out/wsP/formulas/regen_*). A rate of 0 is no regen.
// (hole combat-regen :tags combat :sev gap) regen never applies its combat multipliers (the CombatHealthRegenMult AV, which trolls and werewolves skip; fCombatMagickaRegenRateMult; fCombatStaminaRegenRateMult): nothing is in combat.

Regen :: struct {
	av, rate, mult:   string,
	pause, pause_max: string, // GMSTs: seconds after a drop, and after reaching 0 (exe defaults 1 and 5)
}

@(private)
REGEN := [3]Regen {
	{"Health", "HealRate", "HealRateMult", "fDamagedHealthRegenDelay", "fHealthRegenDelayMax"},
	{"Magicka", "MagickaRate", "MagickaRateMult", "fDamagedMagickaRegenDelay", "fMagickaRegenDelayMax"},
	{"Stamina", "StaminaRate", "StaminaRateMult", "fDamagedStaminaRegenDelay", "fStaminaRegenDelayMax"},
}

// REGEN_TURNS: an actor outside the loaded cells regenerates in turns, once every this many ticks
// (10 Hz at 60); a loaded one every tick. Each turn group keeps the seconds it is owed since its
// last turn, so a wait's skipped hours reach every actor whichever tick they came in.
REGEN_TURNS :: 6

Regen_Turns :: struct {
	turn: u64,
	owed: [REGEN_TURNS]f32,
}

// av_regen restores `seconds` of play time of regen on every damaged actor that is not dead.
av_regen :: proc(ws: ^World_State, db: ^gamedb.DB, seconds: f32) {
	t := &ws.regen
	t.turn += 1
	due := t.turn % REGEN_TURNS
	for &o in t.owed {o += seconds}
	for actor, &vals in ws.actor_values {
		seconds := seconds
		if actor not_in ws.ai.loaded {
			if u64(actor) % REGEN_TURNS != due {continue}
			seconds = t.owed[due]
		}
		for r in REGEN {
			p, ok := &vals[r.av]
			if !ok || p.damage >= 0 {continue} // most are whole: the cheap test first
			if d, dok := ws.ref_deltas[actor]; dok && .Dead in d.live {break}
			left := seconds - p.pause
			p.pause = max(p.pause - seconds, 0)
			if left <= 0 {continue}
			per_second := av_max(ws, db, actor, r.av) * av_current(ws, db, actor, r.rate) / 100 * av_current(ws, db, actor, r.mult) / 100
			p.damage = min(p.damage + per_second * left, 0)
		}
	}
	t.owed[due] = 0
}

// ── mod actor values (ws.md, Workstream P) ──
// A mod creates one from OnGameLoaded (rt.actor_value); it lives until the next new game or load.

Mod_AV :: struct {
	name:    string, // the first creation's spelling
	default: f32,
	kind:    gamedb.AV_Kind,
}

// av_name is the canonical name of an actor value in any case: an AV_NAMES entry, else a mod AV.
av_name :: proc(ws: ^World_State, name: string) -> (string, bool) {
	if av, ok := gamedb.actor_value_name(name); ok {return av, true}
	m, ok := mod_av(ws, name)
	return m.name, ok
}

@(private)
mod_av :: proc(ws: ^World_State, name: string) -> (m: Mod_AV, ok: bool) {
	buf: [gamedb.AV_NAME_MAX]u8
	key := gamedb.av_key(name, buf[:]) or_return
	return ws.mod_avs[key]
}

// av_create gets or creates a mod actor value and binds the loaded values saved under its name.
av_create :: proc(ws: ^World_State, name: string, default: f32, kind: gamedb.AV_Kind) {
	if _, engine := gamedb.actor_value_name(name); engine {
		log.warnf("script: %q is an engine actor value, not a mod one", name)
		return
	}
	if m, ok := mod_av(ws, name); ok {
		if m.default != default || m.kind != kind {log.warnf("script: actor value %q keeps its first definition (default %v, %v)", m.name, m.default, m.kind)}
		return
	}
	buf: [gamedb.AV_NAME_MAX]u8
	key, ok := gamedb.av_key(name, buf[:])
	if !ok {
		log.warnf("script: actor value name %q is longer than %d", name, gamedb.AV_NAME_MAX)
		return
	}
	m := Mod_AV{strings.clone(name), default, kind}
	ws.mod_avs[strings.clone(key)] = m
	#reverse for a, i in ws.pending_avs {
		if !strings.equal_fold(a.name, name) {continue}
		av_bind(ws, a.actor, m.name, a)
		delete(a.name)
		unordered_remove(&ws.pending_avs, i)
	}
}

// av_bind puts saved parts in the store.
@(private)
av_bind :: proc(ws: ^World_State, actor: Form_ID, av: string, a: Saved_AV) {
	p := av_upsert(ws, actor, av)
	p^ = {permanent = a.permanent, damage = a.damage}
	if a.has_base {p.base = a.base}
	if a.has_cap {p.cap = a.cap}
}

// av_drop_pending drops the loaded values no mod created a name for, once OnGameLoaded has run.
av_drop_pending :: proc(ws: ^World_State) {
	for a in ws.pending_avs {
		log.infof("load: dropped actor value %q of %8x: no mod created it", a.name, a.actor)
		delete(a.name)
	}
	clear(&ws.pending_avs)
}

// ── faction membership/rank + relationship rank ────────────────────────────────────────────────
// Factions are the NPC_'s SNAM rows with a delta per faction; relationships are overlay-only (RELA
// is not indexed), so an unset relationship reads 0 (Acquaintance). Rank -1 is in the faction but
// not a member: 753 vanilla SNAM rows use it (40 potential followers in CurrentFollowerFaction,
// which dialogue tests only through GetInFaction), and scripts leave with SetFactionRank(-1).

// FACTION_REMOVED is a faction delta that takes the actor out of a baseline faction.
FACTION_REMOVED :: min(i32)

@(private)
faction_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.factions[actor]; !ok {
		ws.factions[actor] = make(map[Form_ID]i32)
	}
	return &ws.factions[actor]
}

// faction_set_rank sets actor's rank in faction — also the "add to faction" verb.
faction_set_rank :: proc(ws: ^World_State, actor, faction: Form_ID, rank: i32) {
	faction_upsert(ws, actor)^[faction] = rank
}

// faction_rank is actor's rank in faction: its delta, else its NPC_'s row; an alias that holds it
// and lists the faction makes it a member at rank 0 or above. ok=false when it is not in the faction.
// (hole alias-faction-removal :tags quest :sev polish) NOT VANILLA (user choice 2026-09-26): an alias's factions count only while it holds the actor. Vanilla calls RemoveFromFaction when the alias clears, which also drops a membership the actor had on its own (CK wiki bug); a script relying on that removal behaves differently here.
faction_rank :: proc(ws: ^World_State, db: ^gamedb.DB, actor, faction: Form_ID) -> (i32, bool) {
	r, ok := stored_faction_rank(ws, db, actor, faction)
	if !ok || r < 0 {
		for a in holder_aliases(ws, db, actor) {
			if slice.contains(a.factions, faction) {return max(r, 0) if ok else 0, true}
		}
	}
	return r, ok
}

@(private = "file")
stored_faction_rank :: proc(ws: ^World_State, db: ^gamedb.DB, actor, faction: Form_ID) -> (i32, bool) {
	if inner, ok := ws.factions[actor]; ok {
		if r, has := inner[faction]; has {return r, r != FACTION_REMOVED}
	}
	r, ok := gamedb.actor_faction_rank(db, record_of(ws, actor), faction, actor_pick(ws, db, actor))
	return i32(r), ok
}

// in_faction is membership: in the faction at rank 0 or above.
in_faction :: proc(ws: ^World_State, db: ^gamedb.DB, actor, faction: Form_ID) -> bool {
	r, ok := faction_rank(ws, db, actor, faction)
	return ok && r >= 0
}

// (hole flight :tags (animation combat unclaimed) :sev gap) the flag is stored, and nothing flies to obey it.
set_allow_flying :: proc(ws: ^World_State, actor: Form_ID, allow: bool) {
	set_in_set(&ws.grounded, actor, !allow)
}

allowed_to_fly :: proc(ws: ^World_State, actor: Form_ID) -> bool {
	return actor not_in ws.grounded
}

// faction_relation is how one of `actor`'s factions stands toward one of `other`'s (XNAM, or a
// script's change). The first relation found answers; none is Neutral.
faction_relation :: proc(ws: ^World_State, db: ^gamedb.DB, actor, other: Form_ID) -> esm.Combat_Reaction {
	theirs := actor_factions_now(ws, db, other)
	for mine in actor_factions_now(ws, db, actor) {
		for t in theirs {
			if r, ok := relation(ws, db, mine, t); ok {return r.combat}
		}
	}
	return .Neutral
}

// actor_factions_now is every faction `actor` is a member of now: its NPC_'s and a script's.
actor_factions_now :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for m in gamedb.actor_factions(db, record_of(ws, actor), actor_pick(ws, db, actor)) {
		if in_faction(ws, db, actor, m.faction) {append(&out, m.faction)}
	}
	if own, ok := ws.factions[actor]; ok {
		for f in own {
			if in_faction(ws, db, actor, f) && !slice.contains(out[:], f) {append(&out, f)}
		}
	}
	return out[:]
}

faction_remove :: proc(ws: ^World_State, actor, faction: Form_ID) {
	faction_upsert(ws, actor)^[faction] = FACTION_REMOVED
}

faction_remove_all :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) {
	inner := faction_upsert(ws, actor)
	for f in inner {inner[f] = FACTION_REMOVED}
	for m in gamedb.actor_factions(db, record_of(ws, actor), actor_pick(ws, db, actor)) {inner[m.faction] = FACTION_REMOVED}
}

// ── perks ─────────────────────────────────────────────────────────────────────────────────────
// An actor's perks are its NPC_'s PRKR list with a delta per perk, like its spells. A rank is its
// own PERK form (NNAM chain), so taking a perk twice is a no-op. Backs Actor.AddPerk / HasPerk /
// RemovePerk and CTDA function 448.

perk_add :: proc(ws: ^World_State, actor, perk: Form_ID) {
	delta_upsert(&ws.perks, actor)[perk] = GIVEN
}

perk_remove :: proc(ws: ^World_State, actor, perk: Form_ID) {
	delta_upsert(&ws.perks, actor)[perk] = REMOVED
}

perk_has :: proc(ws: ^World_State, db: ^gamedb.DB, actor, perk: Form_ID) -> bool {
	if delta, ok := ws.perks[actor]; ok {
		switch delta[perk] {
		case GIVEN:
			return true
		case REMOVED:
			return false
		}
	}
	return slice.contains(gamedb.record_perks(db, record_of(ws, actor), actor_pick(ws, db, actor)), perk)
}

// perk_list is every perk `actor` has: its records' then the ones it was given.
perk_list :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> []Form_ID {
	delta, _ := ws.perks[actor]
	return with_delta(gamedb.record_perks(db, record_of(ws, actor), actor_pick(ws, db, actor)), delta)
}

@(private)
rel_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.relationships[actor]; !ok {
		ws.relationships[actor] = make(map[Form_ID]i32)
	}
	return &ws.relationships[actor]
}

// rel_set stores the relationship rank for the (a,b) pair. Skyrim relationships are symmetric (one
// RELA record per pair), so we mirror it both ways → GetRelationshipRank works from either actor.
// A change is a story event (CHRR).
rel_set :: proc(ws: ^World_State, db: ^gamedb.DB, a, b: Form_ID, rank: i32) {
	if old := rel_rank(ws, db, a, b); old != rank {queue_story_event(ws, {type = STORY_RELATIONSHIP, ref1 = a, ref2 = b, value1 = old, value2 = rank})}
	ia := rel_upsert(ws, a)
	ia^[b] = rank
	ib := rel_upsert(ws, b)
	ib^[a] = rank
}

// rel_rank is a's relationship rank toward b: a script's SetRelationshipRank, else the RELA between
// their NPC_s, else 0 (Acquaintance).
rel_rank :: proc(ws: ^World_State, db: ^gamedb.DB, a, b: Form_ID) -> i32 {
	if inner, ok := ws.relationships[a]; ok {
		if rank, set := inner[b]; set {return rank}
	}
	r, _ := gamedb.relationship(db, rel_base(ws, db, a), rel_base(ws, db, b))
	return r.rank
}

// rel_association is the kind of tie (ASTP) between two actors' NPC_s; 0 when none.
rel_association :: proc(ws: ^World_State, db: ^gamedb.DB, a, b: Form_ID) -> Form_ID {
	r, _ := gamedb.relationship(db, rel_base(ws, db, a), rel_base(ws, db, b))
	return r.association
}

// rel_is_parent reports whether a ParentChild relationship makes `parent`'s NPC_ the parent of `child`'s.
rel_is_parent :: proc(ws: ^World_State, db: ^gamedb.DB, parent, child: Form_ID) -> bool {
	me := rel_base(ws, db, parent)
	r, ok := gamedb.relationship(db, me, rel_base(ws, db, child))
	return ok && r.association == formid.ASSOC_PARENT_CHILD && r.parent == me
}

// rel_rank_range is the lowest and highest rank of `actor`'s ties, 0 for none. A script's rank
// replaces the records' for the same NPC_.
rel_rank_range :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> (lowest, highest: i32) {
	ranks := make(map[Form_ID]i32, context.temp_allocator)
	me := rel_base(ws, db, actor)
	for p, r in db.relationships {
		if p[0] == me {ranks[p[1]] = r.rank} else if p[1] == me {ranks[p[0]] = r.rank}
	}
	if inner, ok := ws.relationships[actor]; ok {
		for other, rank in inner {ranks[rel_base(ws, db, other)] = rank}
	}
	first := true
	for _, r in ranks {
		if first {lowest, highest = r, r}
		lowest, highest, first = min(lowest, r), max(highest, r), false
	}
	return
}

@(private = "file")
rel_base :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID) -> Form_ID {
	if db == nil {return actor}
	if pick := actor_pick(ws, db, actor); pick != 0 {return pick}
	base := ref_base(ws, db, actor)
	return base if base != 0 else actor
}
