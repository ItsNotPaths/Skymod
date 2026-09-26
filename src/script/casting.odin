package script

// Casting: an actor uses the spell in one of its hands. Rudimentary for now: the spell lands at
// once, its cost is paid up front, a Self spell hits the caster and any other hits `target`.
// (hole spell-casting :tags (combat magic ai) :sev gap) casting is instant: no charge time, no concentration (hold, drain and reapply each second), no projectile or area, no dual cast, no cost perks, and NPCs never cast.

import "../gamedb"
import "../worldstate"

// (hole story-cast-event :tags (quest magic) :sev polish :needs (story-manager)) a cast queues no CAST story event (MG01ShoutUpdate, WICastMagic).
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
	if school, trains := spell_school(c.db, spell); trains {worldstate.advance_skill(c.ws, c.db, caster, school, cost)}
	return true
}

// spell_school is the skill a spell trains: its costliest effect's magic skill. A cast gives that
// skill XP equal to the spell's cost (UESP Skyrim:Leveling).
spell_school :: proc(db: ^gamedb.DB, spell: Form_ID) -> (skill: string, ok: bool) {
	i := gamedb.spell_costliest_effect(db, spell) or_return
	sp, _ := gamedb.spell_of(db, spell)
	m, _ := gamedb.magic_effect_of(db, sp.effects[i].effect)
	av := m.info.magic_skill
	if av < 6 || av >= 24 {return}
	return gamedb.AV_NAMES[av], true
}
