package worldstate

// Named formulas: the engine's progression math and zone levels, as strings a mod replaces from
// OnGameLoaded (rt.formula; the last one wins). A replacement lasts until the next new game or load,
// like a mod actor value. GMSTs come in as variables, so the defaults stay the vanilla math.

import "core:log"
import "../formula"

Formula_Name :: enum u8 {
	ZoneLevel,         // a zone's first level: pc (player level), min, max, level (the engine's clamp)
	SkillXPToNext,     // skill XP to go from `level` up one: level, mult, offset (AVSK improve), curve (fSkillUseCurve)
	SkillUseXP,        // skill XP a use gives: xp, mult, offset (AVSK use)
	PlayerXPFromSkill, // player XP when a skill reaches `level`: level, per_rank (fXPPerSkillRank)
	PlayerXPToNext,    // player XP to go from `level` up one: level, base, mult (fXPLevelUpBase, fXPLevelUpMult)
}

Formula_Def :: struct {
	vars:    []string,
	default: string,
}

FORMULAS := [Formula_Name]Formula_Def {
	.ZoneLevel         = {{"pc", "min", "max", "level"}, "level"},
	.SkillXPToNext     = {{"level", "mult", "offset", "curve"}, "mult * level ^ curve + offset"},
	.SkillUseXP        = {{"xp", "mult", "offset"}, "xp * mult + offset"},
	.PlayerXPFromSkill = {{"level", "per_rank"}, "level * per_rank"},
	.PlayerXPToNext    = {{"level", "base", "mult"}, "base + mult * level"},
}

// calc evaluates a named formula; `values` follow its variables.
calc :: proc(ws: ^World_State, name: Formula_Name, values: ..f64) -> f64 {
	return formula.eval(ws.formulas[name], values)
}

// set_formula replaces a named formula; on a bad name or source it warns and keeps the old one.
set_formula :: proc(ws: ^World_State, name: Formula_Name, src: string) -> bool {
	f, err := formula.compile(src, FORMULAS[name].vars)
	if err != "" {
		log.warnf("script: formula %v %q: %s (variables %v)", name, src, err, FORMULAS[name].vars)
		return false
	}
	formula.destroy(&ws.formulas[name])
	ws.formulas[name] = f
	return true
}

@(private)
init_formulas :: proc(o: ^Overlay) {
	for def, name in FORMULAS {
		f, err := formula.compile(def.default, def.vars)
		assert(err == "", "a default formula does not compile")
		o.formulas[name] = f
	}
}
