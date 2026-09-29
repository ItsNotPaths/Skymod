package script

// Magic effects, the script lifecycle only (docs/script-api.md section 3): a spell's scripted
// effects start on a target, run their duration and end. Each is an effect instance keyed by
// its handle (worldstate.Active_Effect).
// (hole brew-enchant-perks :tags (magic player) :sev gap :needs (crafting-screen)) potions and enchantments take no perks: Mod Alchemy Effectiveness and Mod Enchantment Power scale them when brewed or enchanted, and nothing brews or enchants yet (UESP Skyrim:Alchemy_Effects).
// (hole effect-fx :tags (magic vfx unclaimed) :sev gap :needs (particles)) an effect's art, shaders and light (its MGEF's hit art, casting art) do not show.
// (hole effect-sounds :tags (magic audio unclaimed) :sev gap :needs (cast-animation concentration)) an effect's charge, ready, cast-loop and draw/sheathe sounds do not play: casting is instant. Release and on-hit play (casting.odin).

import "core:slice"
import "../conditions"
import "../formid"
import "../gamedb"
import "../magic"
import "../worldstate"

// (hole soul-gems :tags magic :sev gap :needs (other-archetypes)) soul trap fills no gem: Actor.TrapSoul is not a native, SLGM capacity and fill are not indexed, an inventory stack holds no soul and the Soul Trap perk entries are unread; nothing recharges an item.
// (hole magic-natives :tags (magic script) :sev gap) not natives: Actor.Resurrect, Actor.DoCombatSpellApply (26 calls), Actor.SetAlpha (144: invisibility effects), ObjectReference.InterruptCast (11) and KnockAreaEffect (27). Reanimation and quests that revive an actor do nothing.
register_magic :: proc(reg: ^Registry) {
	register(reg, "Actor", "AddSpell", n_add_spell)
	register(reg, "Actor", "RemoveSpell", n_remove_spell)
	register(reg, "Actor", "DispelSpell", n_dispel_spell)
	register(reg, "Actor", "HasSpell", n_has_spell)
	register(reg, "Actor", "AddShout", n_add_shout)
	register(reg, "Actor", "RemoveShout", n_remove_shout)
	register(reg, "Game", "TeachWord", n_teach_word)
	register(reg, "Game", "UnlockWord", n_unlock_word)
	register(reg, "Game", "IsWordUnlocked", n_is_word_unlocked)
	register(reg, "Game", "SetBeastForm", n_set_beast_form)
	register(reg, "Actor", "SendVampirismStateChanged", n_vampirism_changed)
	register(reg, "Actor", "SendLycanthropyStateChanged", n_lycanthropy_changed)
	register(reg, "Actor", "DispelAllSpells", n_dispel_all_spells)
	register(reg, "Spell", "Cast", n_spell_cast)
	register(reg, "Spell", "RemoteCast", n_spell_remote_cast)
	register(reg, "ActiveMagicEffect", "Dispel", n_effect_dispel)
	register(reg, "ActiveMagicEffect", "SetActive", n_effect_set_active)
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

// (hole disease-effects :tags magic :sev gap) a caught disease does nothing: AddSpell and sync_constant_effects start abilities only, so a Disease spell sits in the list with GetDisease 1 and no penalty; no hit passes one on.
// AddSpell: the actor learns the spell; an ability starts. False when it already knew it.
n_add_spell :: proc(c: ^Call, args: []Value) -> Value {
	spell := arg_form(c, args, 0)
	if !worldstate.give_spell(c.ws, c.db, c.self, spell) {return false}
	if is_ability(c.db, spell) {start_spell(c, spell, c.self, c.self)}
	return true
}

// RemoveSpell: the actor forgets the spell and its effects end. False when it did not know it.
n_remove_spell :: proc(c: ^Call, args: []Value) -> Value {
	spell := arg_form(c, args, 0)
	if !worldstate.remove_spell(c.ws, c.db, c.self, spell) {return false}
	for h in spell_effects(c.ws, c.self, spell) {worldstate.end_effect(c.ws, h)}
	return true
}

// DispelSpell ends the spell's effects; the actor still knows it. True when it had any.
n_dispel_spell :: proc(c: ^Call, args: []Value) -> Value {
	effects := spell_effects(c.ws, c.self, arg_form(c, args, 0))
	for h in effects {worldstate.end_effect(c.ws, h)}
	return len(effects) > 0
}

n_has_spell :: proc(c: ^Call, args: []Value) -> Value {return worldstate.has_spell(c.ws, c.db, c.self, arg_form(c, args, 0))}
n_add_shout :: proc(c: ^Call, args: []Value) -> Value {return worldstate.give_spell(c.ws, c.db, c.self, arg_form(c, args, 0))}
n_remove_shout :: proc(c: ^Call, args: []Value) -> Value {return worldstate.remove_spell(c.ws, c.db, c.self, arg_form(c, args, 0))}

// The player's words of power: taught is not unlocked (Game.TeachWord / UnlockWord).
n_teach_word :: proc(c: ^Call, args: []Value) -> Value {worldstate.teach_word(c.ws, c.ws.player, arg_form(c, args, 0)); return nil}
n_unlock_word :: proc(c: ^Call, args: []Value) -> Value {worldstate.unlock_word(c.ws, c.ws.player, arg_form(c, args, 0)); return nil}
n_is_word_unlocked :: proc(c: ^Call, args: []Value) -> Value {return worldstate.word_unlocked(c.ws, c.ws.player, arg_form(c, args, 0))}

n_set_beast_form :: proc(c: ^Call, args: []Value) -> Value {c.ws.beast_form = arg_bool(args, 0, false); return nil}
n_vampirism_changed :: proc(c: ^Call, args: []Value) -> Value {worldstate.set_in_set(&c.ws.vampires, c.self, arg_bool(args, 0, false)); return nil}
n_lycanthropy_changed :: proc(c: ^Call, args: []Value) -> Value {worldstate.set_in_set(&c.ws.werewolves, c.self, arg_bool(args, 0, false)); return nil}

// sync_constant_effects starts `actor`'s constant effects that are not running and ends the ones
// whose source it no longer has: the abilities in its spell list and its perks' ability entries,
// and the constant-effect enchantments of what it wears. After a mod update, on load or attach, and when its gear changes.
// (hole weapon-enchantments :tags (magic combat) :sev gap :needs (combat-damage)) a melee weapon's enchantment (a Contact effect on hit) never applies; projectile hits and worn constant effects do.
// (hole twin-enchantments :tags magic :sev polish) two worn items carrying the same ENCH form run it once; Skyrim adds enchantments.
// (hole passive-effects :tags magic :sev gap) an ability is a spell here; it should be an effect given with d = -1 (user, 2026-09-28: the active effects menu is the same), on a list like spells: the records' abilities plus a saved delta, with its live conditions in the effect's own script.
sync_constant_effects :: proc(c: ^Call, actor: Form_ID) {
	sources := make([dynamic]Form_ID, context.temp_allocator)
	for s in worldstate.spell_list(c.ws, c.db, actor) {
		if is_ability(c.db, s) {append(&sources, s)}
	}
	for perk in worldstate.perk_list(c.ws, c.db, actor) {
		p, _ := gamedb.perk_of(c.db, perk)
		for e in p.entries {
			if e.kind == .Ability && is_ability(c.db, e.form) {append(&sources, e.form)}
		}
	}
	for w in worldstate.equipment(c.ws, c.db, actor).worn {
		slot, _ := gamedb.equip_slot_of(c.db, w.item)
		if is_constant_enchantment(c.db, slot.enchantment) {append(&sources, slot.enchantment)}
	}
	for h in worldstate.effects_on(c.ws, actor) {
		e := c.ws.effects[h]
		constant := is_ability(c.db, e.spell) || is_constant_enchantment(c.db, e.spell)
		if !e.ended && constant && !slice.contains(sources[:], e.spell) {worldstate.end_effect(c.ws, h)}
	}
	for s in sources {
		if len(spell_effects(c.ws, actor, s)) > 0 {continue}
		if ench, ok := gamedb.enchantment_of(c.db, s); ok {
			start_effects(c, s, ench.effects, true, actor, actor)
		} else {
			start_spell(c, s, actor, actor)
		}
	}
}

@(private)
is_ability :: proc(db: ^gamedb.DB, spell: Form_ID) -> bool {
	sp, ok := gamedb.spell_of(db, spell)
	return ok && sp.info.type == .Ability
}

@(private)
is_constant_enchantment :: proc(db: ^gamedb.DB, form: Form_ID) -> bool {
	e, ok := gamedb.enchantment_of(db, form)
	return ok && e.info.cast_type == .Constant_Effect
}

// (hole death-dispel :tags magic :sev gap) a death ends no effect: vanilla dispels every effect on a dying actor unless its MGEF has No Death Dispel (0x10000000); OnEffectFinish then reaches soul trap and ash pile scripts with the dead target still valid.
// DispelAllSpells ends every effect with a duration; abilities stay.
n_dispel_all_spells :: proc(c: ^Call, args: []Value) -> Value {
	for h in worldstate.effects_on(c.ws, c.self) {
		if !c.ws.effects[h].lasts {worldstate.end_effect(c.ws, h)}
	}
	return nil
}

// recheck_effect re-tests a running effect's own conditions (tick_effects, each second). A defined
// effect's scripts switch it instead (SetActive).
recheck_effect :: proc(c: ^Call, h: Form_ID) {
	e := &c.ws.effects[h]
	if e.effect in c.ws.effect_defs {return}
	items := gamedb.effect_items_of(c.db, e.spell)
	if e.ended || e.item >= len(items) {return}
	ctx := condition_context(c, e.target, e.caster)
	e.inactive = !conditions.all(&ctx, items[e.item].conditions)
}

// Cast(akSource, akTarget): the spell hits at once, with no projectile. No target hits the source.
// An ability does nothing: it applies only from a spell list (CK wiki, Spell).
n_spell_cast :: proc(c: ^Call, args: []Value) -> Value {
	if is_ability(c.db, c.self) {return nil}
	source := arg_form(c, args, 0)
	target := arg_form(c, args, 1)
	start_spell(c, c.self, target if target != 0 else source, source)
	return nil
}

// RemoteCast(akSource, akBlameActor, akTarget): the blamed actor is the caster.
n_spell_remote_cast :: proc(c: ^Call, args: []Value) -> Value {
	if is_ability(c.db, c.self) {return nil}
	source, blame, target := arg_form(c, args, 0), arg_form(c, args, 1), arg_form(c, args, 2)
	start_spell(c, c.self, target if target != 0 else source, blame if blame != 0 else source)
	return nil
}

n_effect_dispel :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.end_effect(c.ws, c.self)
	return nil
}

// SetActive(abActive) is not Papyrus: a defined effect's moment script switches it on and off
// (rt.effect); an inactive effect runs on, changing nothing.
n_effect_set_active :: proc(c: ^Call, args: []Value) -> Value {
	if e, ok := &c.ws.effects[c.self]; ok {e.inactive = !arg_bool(args, 0, true)}
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

// (hole weapon-poison :tags (magic combat) :sev gap) a poison goes on no weapon: no poisoned state or dose count (Mod_Poison_Dose_Count) and no apply on hit.
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

// start_effects starts each effect of `source` whose MGEF's conditions pass. The source's own
// conditions for that effect decide whether it is active, now and at each second's recheck (CK
// wiki, Magic Effect: Target Conditions). They run on the target, with the caster as the condition
// target. A spell's magnitude and duration go through the caster's Mod Spell perks and the
// target's Mod Incoming Spell perks, then resistance (worldstate.resisted); effects stack by
// worldstate.stack_effect. A timed effect goes on for its MGEF's taper after its duration.
// (hole concentration-conditions :tags magic :sev polish :needs (concentration)) a concentration spell inverts the checks: its spell-side conditions once at the cast start, its effect-side each second as the effect reapplies. Both run the fire-and-forget way.
@(private)
start_effects :: proc(c: ^Call, source: Form_ID, effects: []gamedb.Magic_Effect_Ref, lasts: bool, target, caster: Form_ID) {
	if target == 0 {return}
	hit := magic.Hit{source, caster, target, true}
	if !hit_lands(c, hit) {return}
	ctx := condition_context(c, target, caster)
	_, is_spell := gamedb.spell_of(c.db, source)
	starting := make([dynamic]worldstate.Active_Effect, context.temp_allocator)
	for e, i in effects {
		mgef, _ := gamedb.magic_effect_of(c.db, e.effect)
		_, defined := c.ws.effect_defs[e.effect] // its land stands in for the MGEF's conditions
		if !defined && !conditions.all(&ctx, mgef.conditions) {continue}
		taper := 0 if lasts else mgef.info.taper_duration
		magnitude, duration := e.magnitude, f32(e.duration)
		// (hole spell-perk-sources :tags magic :sev gap :needs (landing-hooks)) Mod Spell Magnitude and Duration reach spells only; vanilla applies them to potions and enchantments too (mechanics.md: the Fortify Restoration loop runs through it). Landing hooks run for every source.
		if is_spell {
			magnitude = perk_value(c, .Mod_Spell_Magnitude, caster, magnitude, source, target)
			magnitude = perk_value(c, .Mod_Incoming_Spell_Magnitude, target, magnitude, source)
			duration = perk_value(c, .Mod_Spell_Duration, caster, duration, source, target)
			duration = perk_value(c, .Mod_Incoming_Spell_Duration, target, duration, source)
		}
		m := worldstate.resisted(c.ws, c.db, source, e.effect, target, magnitude)
		m, duration = effect_numbers(c, hit, e.effect, m, duration)
		eff := worldstate.Active_Effect{effect = e.effect, spell = source, target = target, caster = caster, lasts = lasts, duration = duration, taper = taper, magnitude = m, item = i}
		eff.inactive = !conditions.all(&ctx, e.conditions)
		if !worldstate.land_effect(c.ws, c.db, &eff) {continue}
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

