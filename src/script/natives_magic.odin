package script

// Magic effects, the script lifecycle only (docs/script-api.md section 3): a spell's scripted
// effects start on a target, run their duration and end. Each is an effect instance keyed by
// its handle (worldstate.Active_Effect).
// (hole effect-magnitudes :tags (magic player) :sev gap :needs (actor-values)) effects have no magnitude and change no actor value; their visuals, sounds and conditions (CTDA) do not run.
// (hole spell-lists :tags (magic player) :sev gap) race and NPC spell lists (SPLO), enchantments and potions start no effects; only AddSpell, Cast and RemoteCast do.

import "../gamedb"
import "../worldstate"

register_magic :: proc(reg: ^Registry) {
	register(reg, "Actor", "AddSpell", n_add_spell)
	register(reg, "Actor", "RemoveSpell", n_end_spell)
	register(reg, "Actor", "DispelSpell", n_end_spell)
	register(reg, "Actor", "DispelAllSpells", n_dispel_all_spells)
	register(reg, "Spell", "Cast", n_spell_cast)
	register(reg, "Spell", "RemoteCast", n_spell_remote_cast)
	register(reg, "ActiveMagicEffect", "Dispel", n_effect_dispel)
	register(reg, "ActiveMagicEffect", "GetBaseObject", n_effect_base)
	register(reg, "ActiveMagicEffect", "GetTargetActor", n_effect_target)
	register(reg, "ActiveMagicEffect", "GetCasterActor", n_effect_caster)
	register(reg, "ActiveMagicEffect", "RegisterForSingleUpdate", n_register_single_update)
	register(reg, "ActiveMagicEffect", "RegisterForUpdate", n_register_update)
	register(reg, "ActiveMagicEffect", "UnregisterForUpdate", n_unregister_for_update)
	register(reg, "ActiveMagicEffect", "RegisterForSingleUpdateGameTime", n_register_single_update_game_time)
	register(reg, "ActiveMagicEffect", "RegisterForUpdateGameTime", n_register_update_game_time)
	register(reg, "ActiveMagicEffect", "UnregisterForUpdateGameTime", n_unregister_for_update_game_time)
	register(reg, "ActiveMagicEffect", "RegisterForAnimationEvent", n_register_anim_event)
	register(reg, "ActiveMagicEffect", "UnregisterForAnimationEvent", n_unregister_anim_event)
}

// AddSpell: false when the target already has the spell.
n_add_spell :: proc(c: ^Call, args: []Value) -> Value {
	spell := arg_form(args, 0)
	if len(spell_effects(c.ws, c.self, spell)) > 0 {return false}
	start_spell(c, spell, c.self, c.self)
	return true
}

// RemoveSpell / DispelSpell: true when the spell had effects on the target.
n_end_spell :: proc(c: ^Call, args: []Value) -> Value {
	effects := spell_effects(c.ws, c.self, arg_form(args, 0))
	for h in effects {worldstate.end_effect(c.ws, h)}
	return len(effects) > 0
}

// DispelAllSpells ends every effect with a duration; abilities stay.
n_dispel_all_spells :: proc(c: ^Call, args: []Value) -> Value {
	for h in worldstate.effects_on(c.ws, c.self) {
		if !c.ws.effects[h].lasts {worldstate.end_effect(c.ws, h)}
	}
	return nil
}

// Cast(akSource, akTarget): the spell hits at once, with no projectile. No target hits the source.
n_spell_cast :: proc(c: ^Call, args: []Value) -> Value {
	source := arg_form(args, 0)
	target := arg_form(args, 1)
	start_spell(c, c.self, target if target != 0 else source, source)
	return nil
}

// RemoteCast(akSource, akBlameActor, akTarget): the blamed actor is the caster.
n_spell_remote_cast :: proc(c: ^Call, args: []Value) -> Value {
	source, blame, target := arg_form(args, 0), arg_form(args, 1), arg_form(args, 2)
	start_spell(c, c.self, target if target != 0 else source, blame if blame != 0 else source)
	return nil
}

n_effect_dispel :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.end_effect(c.ws, c.self)
	return nil
}

n_effect_base :: proc(c: ^Call, args: []Value) -> Value {return form_or_none(c.ws.effects[c.self].effect)}
n_effect_target :: proc(c: ^Call, args: []Value) -> Value {return form_or_none(c.ws.effects[c.self].target)}
n_effect_caster :: proc(c: ^Call, args: []Value) -> Value {return form_or_none(c.ws.effects[c.self].caster)}

// start_spell starts each of the spell's effects that carries a script. An ability or a constant
// effect lasts until removed; any other lasts its authored duration.
start_spell :: proc(c: ^Call, spell, target, caster: Form_ID) {
	sp, ok := gamedb.spell_of(c.db, spell)
	if !ok || target == 0 {return}
	lasts := sp.info.type == .Ability || sp.info.cast_type == .Constant_Effect
	for e in sp.effects {
		if len(gamedb.form_scripts(c.db, e.effect)) == 0 {continue}
		worldstate.start_effect(c.ws, {effect = e.effect, spell = spell, target = target, caster = caster, lasts = lasts, duration = f32(e.duration)})
	}
}

// spell_effects lists the live effects `spell` put on `target`.
spell_effects :: proc(ws: ^worldstate.World_State, target, spell: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for h in worldstate.effects_on(ws, target) {
		if e := ws.effects[h]; e.spell == spell && !e.ended {append(&out, h)}
	}
	return out[:]
}

