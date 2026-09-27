package script

// Casting: an actor uses the spell in one of its hands. Rudimentary for now: the spell lands at
// once, its cost is paid up front, a Self spell hits the caster and any other hits `target`.
// (hole spell-casting :tags (combat magic ai) :sev gap) casting is instant: no charge time, no concentration (hold, drain and reapply each second), no projectile or area, no dual cast, no cost perks, and NPCs never cast.

import "../audio"
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
	hit := caster if sp.info.delivery == .Self else target
	cast_sounds(c, spell, sp, caster, hit)
	start_spell(c, spell, hit, caster)
	worldstate.queue_story_event(c.ws, {type = worldstate.STORY_CAST, ref1 = caster, ref2 = hit, location1 = worldstate.ref_location(c.ws, c.db, caster), form = spell})
	if school, trains := spell_school(c.db, spell); trains {worldstate.advance_skill(c.ws, c.db, caster, school, cost)}
	return true
}

// cast_sounds plays a cast's sounds: the costliest effect's release at the caster, and each
// effect's on-hit at what it hits.
@(private = "file")
cast_sounds :: proc(c: ^Call, spell: Form_ID, sp: gamedb.Spell, caster, hit: Form_ID) {
	if c.audio == nil {return}
	if i, ok := gamedb.spell_costliest_effect(c.db, spell); ok {
		m, _ := gamedb.magic_effect_of(c.db, sp.effects[i].effect)
		audio.play_descriptor(c.audio, c.vfs, c.db, m.sounds[.Release], worldstate.ref_pos(c.ws, c.db, caster), c.ws, caster)
	}
	if hit == 0 {return}
	for e in sp.effects {
		m, _ := gamedb.magic_effect_of(c.db, e.effect)
		audio.play_descriptor(c.audio, c.vfs, c.db, m.sounds[.On_Hit], worldstate.ref_pos(c.ws, c.db, hit), c.ws, hit)
	}
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
