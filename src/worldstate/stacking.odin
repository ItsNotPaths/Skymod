package worldstate

// Stacking: what a new effect does to the effects already on its target. A defined effect (user,
// 2026-09-28): different sources add; the same caster landing it again from the same source
// restarts it, adds, or keeps the running one, by its `stack`; in a `nostack` group, across effects
// and AVs, only the strongest runs (a weaker one does not land; CK Magic Effect, vanilla's Peak
// Value Modifier keywords). Dispelling by tag is the effect's land (DispelTagged).
// (hole stack-per-hand :tags magic :sev gap :needs (spell-use)) a cast does not know its hand, so Flames in each hand restarts one copy; vanilla runs one per hand for a Value Modifier.

import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// stack_effect applies the rules before `e` starts, against the effects already running (a cast's
// own effects start after all of them are checked); false when `e` loses and must not start.
stack_effect :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> bool {
	d, defined := ws.effect_defs[e.effect]
	if !defined {return stack_record(ws, db, e)}
	for h in effects_on(ws, e.target) {
		old := ws.effects[h]
		if old.ended {continue}
		if d.nostack != "" {
			if od, ok := ws.effect_defs[old.effect]; ok && strings.equal_fold(od.nostack, d.nostack) {
				if old.magnitude > e.magnitude {return false}
				end_effect(ws, h)
				continue
			}
		}
		if old.effect != e.effect || old.caster != e.caster || old.spell != e.spell {continue}
		switch d.stack {
		case .Restart: end_effect(ws, h)
		case .Add:
		case .Keep:    return false
		}
	}
	return true
}

// stack_record is a record effect's stacking, Skyrim's rules as code. Instant effects always stack;
// enchantments add to each other and to potions (UESP Skyrim:Enchanting_Effects), and different
// spells add. Sources: UESP Skyrim:Alchemy_Effects, CK Magic Effect (keyword dispel; the PVM keyword
// rule is marked "?" there).
// (hole record-stacking :tags magic :sev gap :needs (magic-translate)) record effects still stack by this code, unlike vanilla (mechanics.md): the timed-potion rule also ends Weakness potions and lingering poisons, a recast replaces its copy whoever cast it, and No Recast (0x20000) is ignored. The translator gives them stack and nostack (PVM keywords to groups, No Recast to keep) and this goes.
// - Its MGEF dispels with keywords: every spell with an effect sharing one ends.
// - Two Peak Value Modifiers sharing a no-stack keyword: the lower magnitude ends (a tie keeps the new).
// - A timed spell cast again replaces its running copy.
// - A timed potion: of the same effect, only the strongest runs.
@(private = "file")
stack_record :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> bool {
	mgef, _ := gamedb.magic_effect_of(db, e.effect)
	timed := !e.lasts && e.duration > 0
	_, from_spell := spell_view(ws, db, e.spell)
	_, from_potion := gamedb.potion_of(db, e.spell)
	for h in effects_on(ws, e.target) {
		old := ws.effects[h]
		if old.ended {continue}
		old_mgef, _ := gamedb.magic_effect_of(db, old.effect)
		switch {
		case mgef.info.flags & esm.MGEF_DISPEL_WITH_KEYWORDS != 0 && shares_keyword(db, e.effect, old.effect):
			dispel_spell(ws, e.target, old.spell)
		case mgef.info.archetype == .Peak_Value_Modifier && mgef.related != 0 && old_mgef.info.archetype == .Peak_Value_Modifier && old_mgef.related == mgef.related:
			if old.magnitude > e.magnitude {return false}
			end_effect(ws, h)
		case timed && old.effect == e.effect && (from_spell && old.spell == e.spell || from_potion && is_potion(db, old.spell)):
			if from_potion && old.magnitude > e.magnitude {return false}
			end_effect(ws, h)
		}
	}
	return true
}

@(private)
shares_keyword :: proc(db: ^gamedb.DB, a, b: Form_ID) -> bool {
	for k in gamedb.keywords_of(db, a) {
		if slice.contains(gamedb.keywords_of(db, b), k) {return true}
	}
	return false
}

// dispel_tagged ends, on `target`, every spell with an effect tagged `pattern`, and every effect so
// tagged that no spell gave (ApplyEffect).
dispel_tagged :: proc(ws: ^World_State, db: ^gamedb.DB, target: Form_ID, pattern: string) {
	for h in effects_on(ws, target) {
		e := ws.effects[h]
		if e.ended || !has_tag(ws, db, e.effect, pattern) {continue}
		if e.spell != 0 {dispel_spell(ws, target, e.spell)} else {end_effect(ws, h)}
	}
}

@(private)
dispel_spell :: proc(ws: ^World_State, target, spell: Form_ID) {
	for h in effects_on(ws, target) {
		if ws.effects[h].spell == spell {end_effect(ws, h)}
	}
}

@(private)
is_potion :: proc(db: ^gamedb.DB, form: Form_ID) -> bool {
	_, ok := gamedb.potion_of(db, form)
	return ok
}
