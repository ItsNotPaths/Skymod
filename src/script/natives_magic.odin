package script

// Magic effects, the script lifecycle only (docs/script-api.md section 3): a spell's scripted
// effects start on a target, run their duration and end. Each is an effect instance keyed by
// its handle (worldstate.Active_Effect).
// (hole effect-magnitudes :tags (magic player) :sev gap ) an effect carries its authored magnitude only: no perk scales it (Mod Spell Magnitude and the rest multiply, UESP Skyrim:Alchemy_Effects), and no resistance cuts it (Resist Magic, then the element's, multiplied; the player caps at 85%, fPlayerMaxResistance; UESP Skyrim:Resist_Magic). Its visuals and sounds do not run.
// (hole effect-condition-recheck :tags (magic script) :sev gap :needs (effect-magnitudes)) an effect's conditions (CTDA) will be checked once, when it starts; Skyrim re-checks them while it runs (about once a second, unsourced). Research with the conditions workstream.

import "core:slice"
import "../conditions"
import "../gamedb"
import "../worldstate"

register_magic :: proc(reg: ^Registry) {
	register(reg, "Actor", "AddSpell", n_add_spell)
	register(reg, "Actor", "RemoveSpell", n_remove_spell)
	register(reg, "Actor", "DispelSpell", n_dispel_spell)
	register(reg, "Actor", "HasSpell", n_has_spell)
	register(reg, "Actor", "AddShout", n_add_shout)
	register(reg, "Actor", "RemoveShout", n_remove_shout)
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

// AddSpell: the actor learns the spell; an ability starts. False when it already knew it.
n_add_spell :: proc(c: ^Call, args: []Value) -> Value {
	spell := arg_form(args, 0)
	if !worldstate.give_spell(c.ws, c.db, c.self, spell) {return false}
	if is_ability(c.db, spell) {start_spell(c, spell, c.self, c.self)}
	return true
}

// RemoveSpell: the actor forgets the spell and its effects end. False when it did not know it.
n_remove_spell :: proc(c: ^Call, args: []Value) -> Value {
	spell := arg_form(args, 0)
	if !worldstate.remove_spell(c.ws, c.db, c.self, spell) {return false}
	for h in spell_effects(c.ws, c.self, spell) {worldstate.end_effect(c.ws, h)}
	return true
}

// DispelSpell ends the spell's effects; the actor still knows it. True when it had any.
n_dispel_spell :: proc(c: ^Call, args: []Value) -> Value {
	effects := spell_effects(c.ws, c.self, arg_form(args, 0))
	for h in effects {worldstate.end_effect(c.ws, h)}
	return len(effects) > 0
}

n_has_spell :: proc(c: ^Call, args: []Value) -> Value {return worldstate.has_spell(c.ws, c.db, c.self, arg_form(args, 0))}
n_add_shout :: proc(c: ^Call, args: []Value) -> Value {return worldstate.give_spell(c.ws, c.db, c.self, arg_form(args, 0))}
n_remove_shout :: proc(c: ^Call, args: []Value) -> Value {return worldstate.remove_spell(c.ws, c.db, c.self, arg_form(args, 0))}

// sync_abilities starts the abilities in `actor`'s spell list that have no effects on it and ends
// the ability effects whose spell the list no longer holds: after a mod update, on load or attach.
sync_abilities :: proc(c: ^Call, actor: Form_ID) {
	known := worldstate.spell_list(c.ws, c.db, actor)
	for h in worldstate.effects_on(c.ws, actor) {
		e := c.ws.effects[h]
		if !e.ended && is_ability(c.db, e.spell) && !slice.contains(known, e.spell) {worldstate.end_effect(c.ws, h)}
	}
	for s in known {
		if is_ability(c.db, s) && len(spell_effects(c.ws, actor, s)) == 0 {start_spell(c, s, actor, actor)}
	}
}

@(private)
is_ability :: proc(db: ^gamedb.DB, spell: Form_ID) -> bool {
	sp, ok := gamedb.spell_of(db, spell)
	return ok && sp.info.type == .Ability
}

// DispelAllSpells ends every effect with a duration; abilities stay.
n_dispel_all_spells :: proc(c: ^Call, args: []Value) -> Value {
	for h in worldstate.effects_on(c.ws, c.self) {
		if !c.ws.effects[h].lasts {worldstate.end_effect(c.ws, h)}
	}
	return nil
}

// Cast(akSource, akTarget): the spell hits at once, with no projectile. No target hits the source.
// An ability does nothing: it applies only from a spell list (CK wiki, Spell).
n_spell_cast :: proc(c: ^Call, args: []Value) -> Value {
	if is_ability(c.db, c.self) {return nil}
	source := arg_form(args, 0)
	target := arg_form(args, 1)
	start_spell(c, c.self, target if target != 0 else source, source)
	return nil
}

// RemoteCast(akSource, akBlameActor, akTarget): the blamed actor is the caster.
n_spell_remote_cast :: proc(c: ^Call, args: []Value) -> Value {
	if is_ability(c.db, c.self) {return nil}
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

// start_spell starts a spell's effects. An ability or a constant effect lasts until removed; any
// other lasts its authored duration.
start_spell :: proc(c: ^Call, spell, target, caster: Form_ID) {
	sp, ok := gamedb.spell_of(c.db, spell)
	if !ok {return}
	start_effects(c, spell, sp.effects, sp.info.type == .Ability || sp.info.cast_type == .Constant_Effect, target, caster)
}

// drink uses up one of `actor`'s potions or food and starts its effects on it (EquipItem, the
// inventory menu): OnItemRemoved, then OnObjectEquipped. False for a poison, which goes on a weapon.
drink :: proc(c: ^Call, actor, item: Form_ID) -> bool {
	p, ok := gamedb.potion_of(c.db, item)
	if !ok || p.poison || worldstate.inv_count(c.ws, c.db, actor, item) == 0 {return false}
	move_items(c, {base = item, from = actor, count = 1})
	append(&c.ws.equip_changes, worldstate.Equip_Change{actor, item, true})
	start_effects(c, item, p.effects, false, actor, actor)
	return true
}

// start_effects starts each effect of `source` whose conditions pass: the source's for that effect,
// then the MGEF's. They run on the target, with the caster as the condition target, and stack by
// worldstate.stack_effect. A timed effect goes on for its MGEF's taper after its duration.
@(private)
start_effects :: proc(c: ^Call, source: Form_ID, effects: []gamedb.Magic_Effect_Ref, lasts: bool, target, caster: Form_ID) {
	if target == 0 {return}
	ctx := conditions.Context{db = c.db, ws = c.ws, subject = target, target = caster}
	starting := make([dynamic]worldstate.Active_Effect, context.temp_allocator)
	for e in effects {
		mgef, _ := gamedb.magic_effect_of(c.db, e.effect)
		if !conditions.all(&ctx, e.conditions) || !conditions.all(&ctx, mgef.conditions) {continue}
		taper := 0 if lasts else mgef.info.taper_duration
		eff := worldstate.Active_Effect{effect = e.effect, spell = source, target = target, caster = caster, lasts = lasts, duration = f32(e.duration), taper = taper, magnitude = e.magnitude}
		if worldstate.stack_effect(c.ws, c.db, eff) {append(&starting, eff)}
	}
	for eff in starting {worldstate.start_effect(c.ws, eff)}
}

// spell_effects lists the live effects `spell` put on `target`.
spell_effects :: proc(ws: ^worldstate.World_State, target, spell: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for h in worldstate.effects_on(ws, target) {
		if e := ws.effects[h]; e.spell == spell && !e.ended {append(&out, h)}
	}
	return out[:]
}

