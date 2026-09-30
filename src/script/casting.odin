package script

// Casting: an actor uses the spell in one of its hands. Rudimentary for now: its cost is paid up
// front, a Self spell hits the caster and any other goes to `target` through cast_spell.
// (hole cast-animation :tags (magic animation unclaimed) :sev gap :needs (animation)) casting is instant: no charge and release from the cast clip.
// (hole spell-use :tags (magic unclaimed) :sev gap :needs (actor-states)) one way to use a spell: pay its SPIT cost at once. Wanted: charged (a charge time, then release), held (drain while held) and item_charge (an enchanted weapon or staff spends its charge), costs as named AVs. Leaning (proposed 2026-09-30, not confirmed): a caster asks once for a Cast state (hand, spell); the state owns the timing, a charged spell releasing itself when charged (AI) or on button-up (player; early is a cancel), a held one draining until asked to leave; ai.proc_use_magic then asks for that state instead of an instant cast, CastTimeMin/Max (inputs 4, 5) as the hold time.
// (hole concentration :tags (magic unclaimed) :sev gap :needs (spell-use)) no held cast: a concentration spell should drain its cost while held and re-apply its effects once a second to what its shape touches, restarting the running copy.
// (hole dual-cast :tags (magic unclaimed) :sev gap :needs (spell-use)) no dual cast: both hands on one spell, a Can Dual Cast perk per school, fMagicDualCastingEffectivenessBase 2.2, CostMult 2.8, not with the No Dual Cast Modifications flag.

import "core:strings"
import "../audio"
import "../formats/esm"
import "../gamedb"
import "../worldstate"

// (hole noise-record-levels :tags (ai audio magic combat) :sev polish) every cast and hit makes a Normal noise: the MGEF Casting Sound Level and the WEAP Sound Level are not read.
// cast_hand casts the spell `caster` holds in `hand` at `target` (0 = nothing under the aim).
// False when the hand holds no castable spell or the caster cannot pay.
// (hole cast-facing :tags (magic ai unclaimed) :sev gap :needs (actor-states)) a cast lands whichever way the caster faces: nothing holds a cast until the caster turns to its target within an angle, so an NPC casts sideways or behind it. A cast state's rule, not a visual one.
// (hole item-charge :tags (magic combat unclaimed) :sev gap :needs (spell-use)) a staff cannot cast (a WEAP, so spell_of misses), and no enchanted item has charge: ENCH charge_amount is unused, nothing drains it on use and RightItemCharge/LeftItemCharge read nothing.
cast_hand :: proc(c: ^Call, caster: Form_ID, hand: gamedb.Slot, target: Form_ID) -> bool {
	held := worldstate.in_slot(c.ws, c.db, caster, hand)
	spell := held
	item, is_item := worldstate.item_view(c.ws, c.db, held)
	used_up := is_item && item.use == .Hand // a scroll: one per cast, no Magicka, no XP
	if used_up {
		if worldstate.inv_count(c.ws, c.db, caster, held) == 0 {return false}
		spell = item.casts
	}
	v, ok := worldstate.spell_view(c.ws, c.db, spell)
	if !ok || !(v.castable || used_up) {return false}
	school, trains := spell_school(c.ws, c.db, spell)
	cost: f32
	if !used_up {cost = worldstate.cast_cost(c.ws, c.db, caster, spell, school, v.cost) or_return}
	if worldstate.av_current(c.ws, c.db, caster, "Magicka") < cost {return false}
	worldstate.av_damage(c.ws, c.db, caster, "Magicka", cost)
	hit := caster if v.self else target
	if sp, record := gamedb.spell_of(c.db, spell); record && !v.defined {cast_sounds(c, spell, sp, caster, hit)}
	cast_spell(c, spell, hit, caster)
	append(&c.ws.casts, worldstate.Spell_Cast{caster, held})
	worldstate.make_noise(c.ws, c.db, caster, caster, worldstate.sound_level(c.db, .Normal))
	if used_up {
		move_items(c, {base = held, from = caster, count = 1})
		if worldstate.inv_count(c.ws, c.db, caster, held) == 0 {worldstate.unequip(c.ws, c.db, caster, held)}
		return true
	}
	worldstate.queue_story_event(c.ws, {type = worldstate.STORY_CAST, ref1 = caster, ref2 = hit, location1 = worldstate.ref_location(c.ws, c.db, caster), form = spell})
	if trains {worldstate.advance_skill(c.ws, c.db, caster, school, cost)}
	return true
}

// use_power uses `words` words of a defined power or shout at `target` (0 = nothing under the aim):
// a self-shaped one hits `caster`. False while it cools down.
// (hole shouts :tags (magic input player) :sev gap) nothing uses the Voice slot: no Shout action or hold to charge more words (user, 2026-09-28: tap for one, hold for more, up to the unlocked words), no SetVoiceRecoveryTime/GetVoiceRecoveryTime on the Voice timer AV, no GetCurrentShoutVariation, and record SHOUs and powers are not defined powers yet.
// (hole power-bodies :tags magic :sev gap) a power or shout lands on its target at once: it does not go through the magicphys seam, so a shout has no cone.
use_power :: proc(c: ^Call, caster, power: Form_ID, words: int, target: Form_ID) -> bool {
	entries := worldstate.power_word(c.ws, c.db, caster, power, words) or_return
	hit := caster if c.ws.power_defs[power].shape == "self" else target
	start_effects(c, power, entries, false, hit, caster)
	append(&c.ws.casts, worldstate.Spell_Cast{caster, power})
	worldstate.make_noise(c.ws, c.db, caster, caster, worldstate.sound_level(c.db, .Normal))
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

// spell_school is the skill a spell trains: a defined spell's first effect tagged school.<skill>,
// else its costliest effect's magic skill. A cast gives that skill XP equal to the spell's cost
// (UESP Skyrim:Leveling).
spell_school :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, spell: Form_ID) -> (skill: string, ok: bool) {
	if d, defined := ws.spell_defs[spell]; defined {
		for e in d.entries {
			for t in ws.tags[e.effect] {
				if strings.has_prefix(t, "school.") {return gamedb.actor_value_name(t[len("school."):])}
			}
		}
		return
	}
	i := gamedb.spell_costliest_effect(db, spell) or_return
	sp, _ := gamedb.spell_of(db, spell)
	m, _ := gamedb.magic_effect_of(db, sp.effects[i].effect)
	av := m.info.magic_skill
	if av < 6 || av >= 24 {return}
	return esm.AV_NAMES[av], true
}
