package worldstate

// Resistance, Skyrim's rules (UESP Skyrim:Resist_Magic, Skyrim:Magic_Overview; CK Magic Effect and
// Spell). Only a Hostile effect is resisted, and not from a spell that ignores resistance. Resist
// Magic comes first for magic (spells, powers, shouts, scrolls, enchantments), then the effect's own
// resist; they multiply. A Poison spell is resisted by PoisonResist instead. The player caps each
// resistance at fPlayerMaxResistance; anyone else at 100, immune. A weakness (below 0) strengthens.
// (hole spell-absorption :tags magic :sev gap) Spell Absorption (AbsorbChance, checked before Resist Magic; the spell is nullified and its cost restores the target's Magicka) is not rolled.
// (hole disease-resistance :tags magic :sev gap) a Disease spell is not resisted: DiseaseResist is a chance to not catch it (UESP, unconfirmed), not a magnitude cut.
// (hole resist-paralysis-duration :tags magic :sev polish :needs (other-archetypes)) Resist Magic also shortens Paralysis (UESP Skyrim:Resist_Magic); only magnitudes are cut.

import "../formats/esm"
import "../formid"
import "../gamedb"

// resisted is magnitude `m` of `effect` from `source` after `target`'s resistances.
resisted :: proc(ws: ^World_State, db: ^gamedb.DB, source, effect, target: Form_ID, m: f32) -> f32 {
	mgef, _ := gamedb.magic_effect_of(db, effect)
	if mgef.info.flags & esm.MGEF_HOSTILE == 0 {return m}
	i := mgef.info.resist_av
	resist := gamedb.AV_NAMES[i] if i >= 0 && int(i) < len(gamedb.AV_NAMES) else ""
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
	cap := gamedb.setting_float(db, "fPlayerMaxResistance", 85) if target == formid.PLAYER else 100
	m := m
	if magic && resist != "MagicResist" {m *= 1 - min(av_current(ws, db, target, "MagicResist"), cap) / 100}
	if resist != "" {m *= 1 - min(av_current(ws, db, target, resist), cap) / 100}
	return m
}
