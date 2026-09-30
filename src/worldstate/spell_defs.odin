package worldstate

// Spells content defines (rt.spell): the charged and held castables, and enchantments (a spell
// tagged `enchantment`). A spell is data: how it is used and delivered, what it costs, and the
// effects it applies, all of them named (user, 2026-09-28). Keyed by form like effects, and not
// saved. spell_view answers for a definition or a record alike.

import "core:log"
import "core:strconv"
import "core:strings"
import "../combat"
import "../formid"
import "../gamedb"
import "../magicphys"

// Spell_Use is how a spell is used (spell-use gives each its behaviour).
Spell_Use :: enum u8 {
	Charged, // charge, then release
	Held,    // runs while held
}

Spell_Def :: struct {
	name:    string, // owned
	display: string, // owned: the name menus show
	use:     Spell_Use,
	self:    bool, // it hits the caster: no shape
	shape:   magicphys.Shape,
	anchor:  string, // owned: where on the caster it leaves; "" = the chest
	cost:    f32,
	entries: [dynamic]Spell_Entry,
}

// Spell_Entry is one effect a spell applies, with its numbers.
Spell_Entry :: struct {
	effect: Form_ID,
	m, d:   f32, // d in seconds
	area:   f32, // feet
	direct: bool, // only the actor the shape strikes (`hits = "direct"`)
}

// Spell_Def_Src is a definition as content wrote it, borrowed.
Spell_Def_Src :: struct {
	name, form, display: string,
	use, shape:          string, // shape: "self" or a primitive's name
	body:                magicphys.Shape, // the primitive's numbers; kind and held are set from shape and use
	lasts, anchor:       string,
	cost:                f32,
	tags:                []string,
	entries:             []Spell_Entry_Src,
}

Spell_Entry_Src :: struct {
	effect: string, // an effect's name (effect_by_name)
	m:      f32,
	d:      string, // "3s", "20tk" or a number of seconds
	area:   f32,
	hits:   string, // "direct", or "" / "area"
}

// SIM_HZ is how many ticks a second has, for durations in ticks ("20tk").
SIM_HZ :: 60

// set_spell_def makes a definition the one for its form, which it returns. An entry naming no
// effect warns and is dropped. Effects are defined first, so entries find them.
set_spell_def :: proc(ws: ^World_State, db: ^gamedb.DB, src: Spell_Def_Src) -> (Form_ID, bool) {
	form := formid.lua_form("spell", src.name)
	if src.form != "" {
		f, ok := form_by_name(ws, db, src.form)
		if !ok {
			log.warnf("rt.spell %s: no form %q", src.name, src.form)
			return 0, false
		}
		form = f
	}
	use: Spell_Use
	switch src.use {
	case "charged", "": use = .Charged
	case "held":        use = .Held
	case:
		log.warnf("rt.spell %s: use %q is not charged or held", src.name, src.use)
		return 0, false
	}
	shape := src.body
	kind, kok := primitive_named(src.shape)
	lasts, lok := parse_duration(src.lasts)
	if !kok || !lok {
		log.warnf("rt.spell %s: shape %q, lasts %q: not self, beam, spray, projectile or aura, or not a duration", src.name, src.shape, src.lasts)
		return 0, false
	}
	shape.kind, shape.lasts, shape.held = kind, lasts, use == .Held
	d := Spell_Def{name = strings.clone(src.name), display = strings.clone(src.display), use = use, self = src.shape == "self", shape = shape, anchor = strings.clone(src.anchor), cost = src.cost}
	for e in src.entries {
		effect, ok := effect_by_name(ws, db, e.effect)
		dur, dok := parse_duration(e.d)
		switch {
		case !ok:  log.warnf("rt.spell %s: no effect %q", src.name, e.effect)
		case !dok: log.warnf("rt.spell %s: %s d = %q is not \"3s\", \"20tk\" or seconds", src.name, e.effect, e.d)
		case:      append(&d.entries, Spell_Entry{effect, e.m, dur, e.area, e.hits == "direct"})
		}
	}
	set_tags(ws, form, src.tags)
	db.form_kinds[form] = .Spell // Spell.Cast and `as Spell` reach it

	if old, ok := &ws.spell_defs[form]; ok {
		free_spell_def(old)
		old^ = d
	} else {
		ws.spell_defs[form] = d
	}
	return form, true
}

// primitive_named is a shape's kind by its content name; "self" and "" have none.
@(private)
primitive_named :: proc(name: string) -> (magicphys.Primitive, bool) {
	switch name {
	case "", "self":   return .None, true
	case "beam":       return .Beam, true
	case "spray":      return .Spray, true
	case "projectile": return .Projectile, true
	case "aura":       return .Aura, true
	}
	return .None, false
}

// parse_duration reads "3s", "20tk" (ticks) or a plain number of seconds; "" is 0.
parse_duration :: proc(s: string) -> (f32, bool) {
	switch {
	case s == "":                     return 0, true
	case strings.has_suffix(s, "tk"): v, ok := strconv.parse_f32(s[:len(s) - 2]); return v / SIM_HZ, ok
	case strings.has_suffix(s, "s"):  return strconv.parse_f32(s[:len(s) - 1])
	}
	return strconv.parse_f32(s)
}

// cast_cost runs the magiccost hooks (rt.hook) on a spell's cost as `caster` casts it: false, and
// the cast is refused.
cast_cost :: proc(ws: ^World_State, caster, spell: Form_ID, cost: f32) -> (f32, bool) {
	cost := cost
	if ws.hooks.magic_cost != nil && !ws.hooks.magic_cost(ws.hooks.data, caster, spell, &cost) {return 0, false}
	return max(cost, 0), true
}

// weapon_cost runs the meleecost hooks, or archcost for a shot (rt.hook), on the Stamina an attack
// costs `actor`: false, and it is refused.
weapon_cost :: proc(ws: ^World_State, actor, weapon: Form_ID, kind: combat.Attack_Kind, ranged: bool, cost: f32) -> (f32, bool) {
	cost := cost
	if ws.hooks.weapon_cost != nil && !ws.hooks.weapon_cost(ws.hooks.data, actor, weapon, kind, ranged, &cost) {return 0, false}
	return max(cost, 0), true
}

// Spell_View is what casting reads of a spell, from its definition or its record.
Spell_View :: struct {
	castable: bool, // a hand can cast it: not an ability or a power
	passive:  bool, // an ability or a constant effect: its effects last until removed
	self:     bool, // its shape hits the caster
	cost:     f32,
	entries:  []gamedb.Magic_Effect_Ref, // a definition's are in the temp allocator
	defined:  bool,
}

spell_view :: proc(ws: ^World_State, db: ^gamedb.DB, spell: Form_ID) -> (v: Spell_View, ok: bool) {
	if d, has := ws.spell_defs[spell]; has {
		return {castable = true, self = d.self, cost = d.cost, entries = entry_refs(d.entries[:]), defined = true}, true
	}
	if d, has := ws.power_defs[spell]; has { // Spell.Cast: its first word, with no cooldown
		entries := entry_refs(d.words[0].entries[:]) if len(d.words) > 0 else nil
		return {self = d.shape == "self", entries = entries, defined = true}, true
	}
	sp := gamedb.spell_of(db, spell) or_return
	if _, effect := ws.effect_defs[spell]; effect && sp.info.type == .Ability { // a translated ability is one effect
		entries := make([]gamedb.Magic_Effect_Ref, 1, context.temp_allocator)
		entries[0] = {effect = spell, magnitude = 1}
		return {passive = true, self = true, entries = entries, defined = true}, true
	}
	passive := sp.info.type == .Ability || sp.info.cast_type == .Constant_Effect
	return {castable = sp.info.type != .Ability, passive = passive, self = sp.info.delivery == .Self, cost = f32(sp.info.cost), entries = sp.effects}, true
}

@(private)
free_spell_def :: proc(d: ^Spell_Def) {
	delete(d.name)
	delete(d.display)
	delete(d.anchor)
	delete(d.entries)
}
