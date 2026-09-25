package worldstate

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

// inv_start is the contents owner starts with.
inv_start :: proc(ws: ^World_State, db: ^gamedb.DB, owner: Form_ID) -> []gamedb.Content_Entry {
	start, _ := gamedb.contents_of(db, record_of(ws, owner))
	return start
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
// (gamedb.actor_value_name), so the store owns no key strings.
// (hole av-regen :tags (player combat) :sev gap :needs (actor-values)) damaged Health, Magicka and Stamina never regenerate (HealRate/MagickaRate/StaminaRate % of max per second, combat multipliers, regen delays).

Actor_Value :: struct {
	base:      Maybe(f32), // SetActorValue's base; none = the records' base
	permanent: f32,        // ModActorValue, ForceActorValue
	damage:    f32,        // DamageActorValue; never above 0
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
	return gamedb.actor_value_base(db, record_of(ws, actor), av)
}

av_max :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	return av_base(ws, db, actor, av) + av_parts(ws, actor, av).permanent
}

av_current :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	return av_max(ws, db, actor, av) + av_parts(ws, actor, av).damage
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

// av_damage is DamageActorValue; a negative amount damages too.
av_damage :: proc(ws: ^World_State, actor: Form_ID, av: string, amount: f32) {
	av_upsert(ws, actor, av).damage -= abs(amount)
}

// av_restore is RestoreActorValue: it removes damage, never past none.
av_restore :: proc(ws: ^World_State, actor: Form_ID, av: string, amount: f32) {
	p := av_upsert(ws, actor, av)
	p.damage = min(p.damage + abs(amount), 0)
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
