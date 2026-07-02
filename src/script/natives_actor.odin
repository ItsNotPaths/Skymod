package script

// Actor store natives (docs/scripting-natives.md §B): actor values + faction/relationship ranks.
// `self` is the actor. All overlay-only: base AV defaults (ActorBase), baseline faction memberships
// (NPC_/ACHR) and relationships aren't indexed yet, so these reflect runtime changes from the baseline
// (an unset AV reads 0, a non-member's rank is -1, an unset relationship is 0 = Acquaintance).

import "../worldstate"

register_actor :: proc(reg: ^Registry) {
	// Actor values.
	register(reg, "Actor", "GetActorValue", n_get_av)
	register(reg, "Actor", "GetBaseActorValue", n_get_av) // no base/current split yet — same store
	register(reg, "Actor", "SetActorValue", n_set_av)
	register(reg, "Actor", "ForceActorValue", n_set_av) // Force = Set without clamping (we don't clamp)
	register(reg, "Actor", "ModActorValue", n_mod_av)
	register(reg, "Actor", "DamageActorValue", n_damage_av)
	register(reg, "Actor", "RestoreActorValue", n_mod_av) // Restore = add (no max to clamp to)
	register(reg, "Actor", "GetActorValuePercentage", n_get_av_pct)

	// Faction membership + rank.
	register(reg, "Actor", "IsInFaction", n_is_in_faction)
	register(reg, "Actor", "SetFactionRank", n_set_faction_rank)
	register(reg, "Actor", "ModFactionRank", n_mod_faction_rank)
	register(reg, "Actor", "GetFactionRank", n_get_faction_rank)
	register(reg, "Actor", "RemoveFromFaction", n_remove_from_faction)
	register(reg, "Actor", "RemoveFromAllFactions", n_remove_from_all_factions)

	// Relationship rank.
	register(reg, "Actor", "GetRelationshipRank", n_get_rel_rank)
	register(reg, "Actor", "SetRelationshipRank", n_set_rel_rank)
}

// ── actor values ─────────────────────────────────────────────────────────────

n_get_av :: proc(c: ^Call, args: []Value) -> Value {
	v, _ := worldstate.av_get(c.ws, c.self, arg_str(args, 0))
	return v
}

n_set_av :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.av_set(c.ws, c.self, arg_str(args, 0), arg_f32(args, 1, 0))
	return nil
}

n_mod_av :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.av_mod(c.ws, c.self, arg_str(args, 0), arg_f32(args, 1, 0))
	return nil
}

n_damage_av :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.av_mod(c.ws, c.self, arg_str(args, 0), -arg_f32(args, 1, 0))
	return nil
}

// GetActorValuePercentage -> current/max, 0..1. We hold no max, so a set AV reads as full (1.0) and an
// unset one as 0 — a placeholder until the actor phase brings base/max AV data. (Callers gating on
// "< 1.0" for damaged actors won't fire; documented limitation.)
n_get_av_pct :: proc(c: ^Call, args: []Value) -> Value {
	if _, ok := worldstate.av_get(c.ws, c.self, arg_str(args, 0)); ok {
		return f32(1)
	}
	return f32(0)
}

// ── faction membership + rank ──────────────────────────────────────────────────

n_is_in_faction :: proc(c: ^Call, args: []Value) -> Value {
	_, ok := worldstate.faction_rank(c.ws, c.self, arg_form(args, 0))
	return ok
}

// SetFactionRank(akFaction, aiRank) — also the "add to faction" verb (there is no AddToFaction native;
// setting a rank makes the actor a member).
n_set_faction_rank :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.faction_set_rank(c.ws, c.self, arg_form(args, 0), arg_i32(args, 1, 0))
	return nil
}

// ModFactionRank(akFaction, aiRankMod) — adjust the rank (adding the actor at rank aiRankMod if not
// already a member, i.e. from a base of 0).
n_mod_faction_rank :: proc(c: ^Call, args: []Value) -> Value {
	faction := arg_form(args, 0)
	cur, _ := worldstate.faction_rank(c.ws, c.self, faction)
	worldstate.faction_set_rank(c.ws, c.self, faction, cur + arg_i32(args, 1, 0))
	return nil
}

// GetFactionRank -> rank, or -1 if not in the faction (per overlay).
n_get_faction_rank :: proc(c: ^Call, args: []Value) -> Value {
	if r, ok := worldstate.faction_rank(c.ws, c.self, arg_form(args, 0)); ok {
		return r
	}
	return i32(-1)
}

n_remove_from_faction :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.faction_remove(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_remove_from_all_factions :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.faction_remove_all(c.ws, c.self)
	return nil
}

// ── relationship rank ──────────────────────────────────────────────────────────

n_get_rel_rank :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.rel_rank(c.ws, c.self, arg_form(args, 0))
}

n_set_rel_rank :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.rel_set(c.ws, c.self, arg_form(args, 0), arg_i32(args, 1, 0))
	return nil
}
