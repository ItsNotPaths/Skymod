package script

// Actor store natives (docs/scripting-natives.md §B): actor values + faction/relationship ranks.
// `self` is the actor. Baseline faction memberships (NPC_/ACHR) and relationships aren't indexed
// yet, so those reflect runtime changes (a non-member's rank is -1, an unset relationship is 0).

import "core:log"
import "../gamedb"
import "../worldstate"

register_actor :: proc(reg: ^Registry) {
	// Actor values.
	register(reg, "Actor", "GetActorValue", n_get_av)
	register(reg, "Actor", "GetBaseActorValue", n_get_base_av)
	register(reg, "Actor", "GetActorValueMax", n_get_av_max)
	register(reg, "Actor", "GetActorValuePercentage", n_get_av_pct)
	register(reg, "Actor", "SetActorValue", n_set_av)
	register(reg, "Actor", "ModActorValue", n_mod_av)
	register(reg, "Actor", "ForceActorValue", n_force_av)
	register(reg, "Actor", "DamageActorValue", n_damage_av)
	register(reg, "Actor", "RestoreActorValue", n_restore_av)
	register(reg, "Actor", "SetActorValueCap", n_set_av_cap)

	// Perks. The store IS the whole truth — a perk is never baseline data, so presence in the
	// overlay set means having it. Also backs CTDA function 448 (src/conditions).
	register(reg, "Actor", "AddPerk", n_add_perk)
	register(reg, "Actor", "RemovePerk", n_remove_perk)
	register(reg, "Actor", "HasPerk", n_has_perk)

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
// An unknown name warns once; a read gives 0 and a write is dropped.

n_get_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return f32(0)}
	return worldstate.av_current(c.ws, c.db, c.self, av)
}

n_get_base_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return f32(0)}
	return worldstate.av_base(c.ws, c.db, c.self, av)
}

n_get_av_max :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return f32(0)}
	return worldstate.av_max(c.ws, c.db, c.self, av)
}

// GetActorValuePercentage is current / max, 1.0 when the max is 0 and always for CarryWeight.
n_get_av_pct :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return f32(0)}
	full := worldstate.av_max(c.ws, c.db, c.self, av)
	if av == "CarryWeight" || full == 0 {return f32(1)}
	return worldstate.av_current(c.ws, c.db, c.self, av) / full
}

n_set_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return nil}
	worldstate.av_set_base(c.ws, c.self, av, arg_f32(args, 1, 0))
	return nil
}

n_mod_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return nil}
	worldstate.av_mod(c.ws, c.self, av, arg_f32(args, 1, 0))
	return nil
}

n_force_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return nil}
	worldstate.av_force(c.ws, c.db, c.self, av, arg_f32(args, 1, 0))
	return nil
}

n_damage_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return nil}
	worldstate.av_damage(c.ws, c.db, c.self, av, arg_f32(args, 1, 0))
	return nil
}

// SetActorValueCap(asValueName, afCap) is ours: a pool's (a skill's) capacity, the soft cap training
// stops at. GetActorValueMax reads it.
n_set_av_cap :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if ok && !worldstate.av_set_cap(c.ws, c.self, av, arg_f32(args, 1, gamedb.SKILL_CAP)) {
		log.warnf("script: SetActorValueCap(%q): only a pool (a skill) has a cap", av)
	}
	return nil
}

n_restore_av :: proc(c: ^Call, args: []Value) -> Value {
	av, ok := av_arg(c, args)
	if !ok {return nil}
	worldstate.av_restore(c.ws, c.self, av, arg_f32(args, 1, 0))
	return nil
}

@(private)
av_arg :: proc(c: ^Call, args: []Value) -> (string, bool) {
	name := arg_str(args, 0)
	av, ok := worldstate.av_name(c.ws, name)
	if !ok && c.reg != nil {
		k := key_own("av", name, c.reg.allocator)
		if k in c.reg.warned {
			delete(string(k), c.reg.allocator)
		} else {
			c.reg.warned[k] = true
			log.warnf("script: unknown actor value %q", name)
		}
	}
	return av, ok
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

// ── perks ───────────────────────────────────────────────────────────────────

n_add_perk :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.perk_add(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_remove_perk :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.perk_remove(c.ws, c.self, arg_form(args, 0))
	return nil
}

n_has_perk :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.perk_has(c.ws, c.self, arg_form(args, 0))
}
