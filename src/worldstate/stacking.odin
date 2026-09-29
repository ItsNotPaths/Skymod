package worldstate

// Stacking: what a new effect does to the effects already on its target, Skyrim's rules. Instant
// effects always stack; enchantments add to each other and to potions (UESP Skyrim:Enchanting_Effects),
// and different spells add. Sources: UESP Skyrim:Alchemy_Effects (one potion effect, the strongest),
// CK Magic Effect (keyword dispel; the PVM keyword rule is marked "?" there). A spell replacing its
// own running copy is unsourced for Skyrim.
// (hole stacking-meta :tags (magic mods) :sev gap :needs (rt-effect)) the stacking rules are code, and two differ from vanilla (mechanics.md): the timed-potion rule also ends Weakness potions and lingering poisons, which vanilla stacks through data (Peak Value Modifier keywords), and a recast replaces its copy whoever cast it, where vanilla restarts only the same caster's, one per hand for a Value Modifier. Wanted: sources add by default, the same caster restarts, `meta = { nostack = group }` keeps the strongest in a group across AVs, and No Recast (0x20000) is honoured.

import "core:slice"
import "../formats/esm"
import "../gamedb"

// stack_effect applies the rules before `e` starts, against the effects already running (a cast's
// own effects start after all of them are checked); false when `e` loses and must not start.
// - Its MGEF dispels with keywords: every spell with an effect sharing one ends.
// - Two Peak Value Modifiers sharing a no-stack keyword: the lower magnitude ends (a tie keeps the new).
// - A timed spell cast again replaces its running copy.
// - A timed potion: of the same effect, only the strongest runs.
stack_effect :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> bool {
	mgef, _ := gamedb.magic_effect_of(db, e.effect)
	timed := !e.lasts && e.duration > 0
	_, from_spell := gamedb.spell_of(db, e.spell)
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
