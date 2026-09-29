package worldstate

// Resistance, Skyrim's rules (UESP Skyrim:Resist_Magic, Skyrim:Magic_Overview; CK Magic Effect and
// Spell). Only a Hostile effect is resisted, and not from a spell that ignores resistance. Resist
// Magic comes first for magic (spells, powers, shouts, scrolls, enchantments), then the effect's own
// resist; they multiply. A Poison spell is resisted by PoisonResist instead. The player caps each
// resistance at fPlayerMaxResistance; anyone else at 100, immune. A weakness (below 0) strengthens.
// (hole disease-resistance :tags (magic unclaimed) :sev gap) a Disease spell is not resisted: DiseaseResist is a chance to not catch it (UESP, unconfirmed), not a magnitude cut.

import "../formats/esm"
import "../formid"
import "../gamedb"

// resisted is magnitude `m` of a record `effect` from `source` after `target`'s resistances. A
// defined effect is resisted by the core Resist hook (rt.lua) instead.
// (hole record-resist :tags magic :sev gap :needs (magic-translate)) record effects still resist here, unlike vanilla (build/out/wsM/mechanics.md): only magnitude is cut (Resist Magic should shorten Paralysis), an alchemy poison uses its effect's resist instead of PoisonResist, worn armour enchantments are resisted, and the cap is not ResistCap. The translator makes them rt.effects and this proc goes.
resisted :: proc(ws: ^World_State, db: ^gamedb.DB, source, effect, target: Form_ID, m: f32) -> f32 {
	mgef, _ := gamedb.magic_effect_of(db, effect)
	if mgef.info.flags & esm.MGEF_HOSTILE == 0 {return m}
	resist := effect_resistance(ws, db, effect)
	magic := true
	if sp, ok := gamedb.spell_of(db, source); ok {
		if sp.info.flags & esm.SPELL_IGNORE_RESISTANCE != 0 {return m}
		#partial switch sp.info.type {
		case .Poison:  resist, magic = "PoisonResist", false
		case .Disease: return m
		}
	} else if _, potion := gamedb.potion_of(db, source); potion {
		magic = false
	}
	cap := gamedb.setting_float(db, "fPlayerMaxResistance", 85) if target == ws.player else 100
	m := m
	if magic && resist != "MagicResist" {m *= 1 - min(av_current(ws, db, target, "MagicResist"), cap) / 100}
	if resist != "" {m *= 1 - min(av_current(ws, db, target, resist), cap) / 100}
	return m
}

// create_resist_cap makes ResistCap, the most of any one resistance that counts (the Resist hook):
// 100, immune; the player's is fPlayerMaxResistance unless the save holds its own.
create_resist_cap :: proc(ws: ^World_State, db: ^gamedb.DB) {
	av_create(ws, "ResistCap", 100, .Static)
	if _, saved := av_parts(ws, ws.player, "ResistCap").base.?; !saved {
		av_set_base(ws, ws.player, "ResistCap", gamedb.setting_float(db, "fPlayerMaxResistance", 85))
	}
}
