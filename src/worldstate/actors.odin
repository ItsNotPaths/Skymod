package worldstate

import "core:log"
import "core:slice"
import "core:strings"
import "../gamedb"

@(private)
inv_upsert :: proc(ws: ^World_State, owner: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.inventories[owner]; !ok {
		ws.inventories[owner] = make(map[Form_ID]i32)
	}
	return &ws.inventories[owner]
}

// inv_add adjusts owner's delta of `item` from its starting contents; negative when it holds fewer
// than it started with. The caller clamps against the starting count.
inv_add :: proc(ws: ^World_State, owner, item: Form_ID, delta: i32) {
	inner := inv_upsert(ws, owner)
	n := inner^[item] + delta
	if n == 0 {
		delete_key(inner, item)
	} else {
		inner^[item] = n
	}
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

// record_of is the form whose records describe a ref: a created ref's base, else the ref, which
// gamedb follows to its base.
record_of :: proc(ws: ^World_State, ref: Form_ID) -> Form_ID {
	if cr, ok := ws.created[ref]; ok {return cr.base}
	return ref
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
	return gamedb.actor_value_base(db, record_of(ws, actor), av, actor_pick(ws, db, actor))
}

// av_max is an AV's capacity: a pool's cap, else base + permanent (GetActorValueMax).
av_max :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	p := av_parts(ws, actor, av)
	if av_kind(ws, av) == .Pool {return (p.cap.? or_else gamedb.SKILL_CAP) + av_live(ws, actor, av, .Capacity)}
	return av_base(ws, db, actor, av) + p.permanent + av_live(ws, actor, av, .Capacity)
}

// av_current is an AV's value: a pool's own stock, else its capacity plus damage.
av_current :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	p := av_parts(ws, actor, av)
	amount := p.damage + av_live(ws, actor, av, .Amount)
	if av_kind(ws, av) == .Pool {return av_base(ws, db, actor, av) + p.permanent + amount}
	return av_max(ws, db, actor, av) + amount
}

// av_kind is an actor value's kind: the engine's, or what the mod that created it said.
av_kind :: proc(ws: ^World_State, av: string) -> gamedb.AV_Kind {
	if m, ok := mod_av(ws, av); ok {return m.kind}
	return gamedb.av_kind(av)
}

// av_set_cap sets a pool's capacity, the soft cap training stops at; false for any other kind.
av_set_cap :: proc(ws: ^World_State, actor: Form_ID, av: string, cap: f32) -> bool {
	if av_kind(ws, av) != .Pool {return false}
	av_upsert(ws, actor, av).cap = cap
	return true
}

// Knob is what an effect turns: an AV's capacity (its max) or its amount (the value under it).
Knob :: enum {
	Capacity,
	Amount,
}

// av_live is what the live effects on `actor` add to a knob of `av` now.
// (hole av-live :tags (magic player) :sev gap :needs (effect-formulas)) no effect contributes to an actor value: the ledger (an effect handle owns its contributions, each a formula of t on a knob, gone when the effect ends; amount writes that stay go to damage) is not built.
av_live :: proc(ws: ^World_State, actor: Form_ID, av: string, knob: Knob) -> f32 {
	return 0
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
// (hole combat-regen :tags combat :sev gap :needs (combat-damage)) regen never applies its combat multipliers (the CombatHealthRegenMult AV, which trolls and werewolves skip; fCombatMagickaRegenRateMult; fCombatStaminaRegenRateMult): nothing is in combat.

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

// av_regen restores `seconds` of play time of regen on every damaged actor that is not dead.
av_regen :: proc(ws: ^World_State, db: ^gamedb.DB, seconds: f32) {
	for actor, &vals in ws.actor_values {
		if d, ok := ws.ref_deltas[actor]; ok && .Dead in d.live {continue}
		for r in REGEN {
			p, ok := &vals[r.av]
			if !ok || p.damage >= 0 {continue}
			left := seconds - p.pause
			p.pause = max(p.pause - seconds, 0)
			if left <= 0 {continue}
			per_second := av_max(ws, db, actor, r.av) * av_current(ws, db, actor, r.rate) / 100 * av_current(ws, db, actor, r.mult) / 100
			p.damage = min(p.damage + per_second * left, 0)
		}
	}
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
// Overlay-only: baseline faction memberships (NPC_/ACHR) + relationships aren't indexed, so these
// see only runtime changes; a non-member reads rank -1, an unset relationship reads 0 (Acquaintance).

@(private)
faction_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.factions[actor]; !ok {
		ws.factions[actor] = make(map[Form_ID]i32)
	}
	return &ws.factions[actor]
}

// faction_set_rank sets actor's rank in faction — also the "add to faction" verb (membership =
// presence of the entry, so setting a rank adds the actor).
faction_set_rank :: proc(ws: ^World_State, actor, faction: Form_ID, rank: i32) {
	inner := faction_upsert(ws, actor)
	inner^[faction] = rank
}

// faction_rank returns (rank, member?). A non-member's rank is meaningless (callers use -1).
faction_rank :: proc(ws: ^World_State, actor, faction: Form_ID) -> (i32, bool) {
	if inner, ok := ws.factions[actor]; ok {
		if r, has := inner[faction]; has {
			return r, true
		}
	}
	return 0, false
}

faction_remove :: proc(ws: ^World_State, actor, faction: Form_ID) {
	if inner, ok := &ws.factions[actor]; ok {
		delete_key(inner, faction)
	}
}

faction_remove_all :: proc(ws: ^World_State, actor: Form_ID) {
	if inner, ok := &ws.factions[actor]; ok {
		clear(inner)
	}
}

// ── perk store (actor FormID -> the perks it has taken) ────────────────────────────────────────
// Overlay-only, and the whole truth: a perk is never baseline data. An NPC_ gets its perks from its
// PERK entries at load and the player takes them at the stats menu, so presence in this set IS
// having the perk. Backs Actor.AddPerk / HasPerk / RemovePerk and CTDA function 448.

@(private)
perk_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[Form_ID]bool {
	if _, ok := ws.perks[actor]; !ok {
		ws.perks[actor] = make(map[Form_ID]bool)
	}
	return &ws.perks[actor]
}

// perk_add gives actor a perk. Taking a perk twice is a no-op, not a second rank — Skyrim models
// ranks as separate PERK records linked by NNAM, so rank 2 is its own form.
perk_add :: proc(ws: ^World_State, actor, perk: Form_ID) {
	inner := perk_upsert(ws, actor)
	inner^[perk] = true
}

// perk_has reports whether actor has taken perk.
perk_has :: proc(ws: ^World_State, actor, perk: Form_ID) -> bool {
	if inner, ok := ws.perks[actor]; ok {
		return inner[perk]
	}
	return false
}

perk_remove :: proc(ws: ^World_State, actor, perk: Form_ID) {
	if inner, ok := &ws.perks[actor]; ok {
		delete_key(inner, perk)
	}
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
rel_set :: proc(ws: ^World_State, a, b: Form_ID, rank: i32) {
	ia := rel_upsert(ws, a)
	ia^[b] = rank
	ib := rel_upsert(ws, b)
	ib^[a] = rank
}

// rel_rank returns a's relationship rank toward b (0 = Acquaintance/neutral if unset).
rel_rank :: proc(ws: ^World_State, a, b: Form_ID) -> i32 {
	if inner, ok := ws.relationships[a]; ok {
		return inner[b]
	}
	return 0
}
