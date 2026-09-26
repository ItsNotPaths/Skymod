package script

// Casting: an actor uses the spell in one of its hands. Rudimentary for now: the spell lands at
// once, its cost is paid up front, a Self spell hits the caster and any other hits `target`.
// (hole spell-casting :tags (magic player ai) :sev gap) casting is instant: no charge time, no concentration (hold, drain and reapply each second), no projectile or area, no dual cast, no cost perks, no skill XP, and NPCs never cast.

import "../gamedb"
import "../worldstate"

// cast_hand casts the spell `caster` holds in `hand` at `target` (0 = nothing under the aim).
// False when the hand holds no castable spell or the caster cannot pay.
cast_hand :: proc(c: ^Call, caster: Form_ID, hand: gamedb.Slot, target: Form_ID) -> bool {
	spell := worldstate.in_slot(c.ws, c.db, caster, hand)
	sp, ok := gamedb.spell_of(c.db, spell)
	if !ok || sp.info.type == .Ability {return false}
	cost := f32(sp.info.cost)
	if worldstate.av_current(c.ws, c.db, caster, "Magicka") < cost {return false}
	worldstate.av_damage(c.ws, c.db, caster, "Magicka", cost)
	start_spell(c, spell, caster if sp.info.delivery == .Self else target, caster)
	return true
}
