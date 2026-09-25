package worldstate

import "core:strings"

@(private)
inv_upsert :: proc(ws: ^World_State, owner: Form_ID) -> ^map[Form_ID]i32 {
	if _, ok := ws.inventories[owner]; !ok {
		ws.inventories[owner] = make(map[Form_ID]i32)
	}
	return &ws.inventories[owner]
}

// inv_add adjusts owner's count of `item` by `delta` (negative removes); the entry is dropped at or
// below 0 (can't hold a negative count). AddItem/RemoveItem both route here.
inv_add :: proc(ws: ^World_State, owner, item: Form_ID, delta: i32) {
	inner := inv_upsert(ws, owner)
	n := inner^[item] + delta
	if n <= 0 {
		delete_key(inner, item)
	} else {
		inner^[item] = n
	}
}

// inv_count returns owner's count of item (0 if none / owner untouched).
inv_count :: proc(ws: ^World_State, owner, item: Form_ID) -> i32 {
	if inner, ok := ws.inventories[owner]; ok {
		return inner[item]
	}
	return 0
}

// (hole container-baseline :tags (records player) :sev gap) the ESM baseline contents of a container are never indexed, so every inventory count here is a DELTA from an unknown start. GetItemCount reads 0 on a fresh game for a chest that is visibly full.
// inv_clear empties owner's inventory overlay (RemoveAllItems' local half).
inv_clear :: proc(ws: ^World_State, owner: Form_ID) {
	if inner, ok := &ws.inventories[owner]; ok {
		clear(inner)
	}
}

// ── actor-value store (actor -> AV name -> value) ──────────────────────────────────────────────
// AV names are case-insensitive → keys are lowercased + owned by the store.
// (hole actor-values :tags (player combat magic) :sev blocker) base actor values are never read: an unset AV reads 0 and there is no base, current or max, so Health, skills and attributes have no real value.

@(private)
av_upsert :: proc(ws: ^World_State, actor: Form_ID) -> ^map[string]f32 {
	if _, ok := ws.actor_values[actor]; !ok {
		ws.actor_values[actor] = make(map[string]f32)
	}
	return &ws.actor_values[actor]
}

// av_set stores `value` for actor's AV `name` (case-folded); clones the key on first insert (the
// existing owned key is kept + reused on overwrite, since string map keys compare by content).
av_set :: proc(ws: ^World_State, actor: Form_ID, name: string, value: f32) {
	inner := av_upsert(ws, actor)
	key := strings.to_lower(name, context.temp_allocator)
	if _, ok := inner^[key]; ok {
		inner^[key] = value
	} else {
		inner^[strings.clone(key)] = value
	}
}

// av_get returns actor's AV value (ok=false if unset).
av_get :: proc(ws: ^World_State, actor: Form_ID, name: string) -> (f32, bool) {
	if inner, ok := ws.actor_values[actor]; ok {
		key := strings.to_lower(name, context.temp_allocator)
		if v, has := inner[key]; has {
			return v, true
		}
	}
	return 0, false
}

// av_mod adds `delta` to actor's AV (Mod/Damage/Restore all bottom out here).
av_mod :: proc(ws: ^World_State, actor: Form_ID, name: string, delta: f32) {
	cur, _ := av_get(ws, actor, name)
	av_set(ws, actor, name, cur + delta)
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
