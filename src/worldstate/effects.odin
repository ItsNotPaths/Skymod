package worldstate

import "core:log"
import "core:strings"
import "../formats/esm"
import "../formid"
import "../formula"
import "../gamedb"

// Active_Effect is one scripted magic effect on a target (docs/script-api.md section 3). Its script
// instance keys on the effect handle, and its class's __effect terms change the target's actor
// values. The instance lingers after the effect ends while its state still ticks.
Active_Effect :: struct {
	effect, spell, target, caster: Form_ID,
	lasts:     bool, // an ability or constant effect: until removed
	duration:  f32,  // real seconds
	taper:     f32,  // seconds it goes on after its duration (the MGEF's taper)
	magnitude: f32,  // as authored, then resisted
	item:      int,  // its entry in the source's effect list (gamedb.effect_items_of)
	inactive:  bool, // its entry's conditions fail now: it runs on, changing nothing
	elapsed:   f32,
	applied:   bool, // its amount terms have run once
	ended:     bool, // OnEffectFinish is due or sent
	finished:  bool, // OnEffectFinish sent
}

// start_effect adds an effect on `target` and returns its handle; the VM gives it its script and
// sends OnEffectStart (slua.sync_refs).
start_effect :: proc(ws: ^World_State, e: Active_Effect) -> Form_ID {
	ws.next_effect += 1
	h := formid.effect_handle(ws.next_effect)
	ws.effects[h] = e
	index_effect(ws, h, e.target)
	append(&ws.new_effects, h)
	return h
}

// end_effect is Dispel, RemoveSpell or a duration running out: OnEffectFinish goes out next.
end_effect :: proc(ws: ^World_State, h: Form_ID) {
	e, ok := &ws.effects[h]
	if !ok || e.ended {return}
	e.ended = true
	append(&ws.ended_effects, h)
}

// advance_effect runs an effect's clock on by `dt`. Each amount term adds what its running total
// gained since the last tick (all of it on the first); a timed effect ends at its duration.
advance_effect :: proc(ws: ^World_State, db: ^gamedb.DB, h: Form_ID, dt: f32) {
	e := &ws.effects[h]
	if e.ended {return}
	t0 := e.elapsed
	e.elapsed += dt
	for term in effect_terms_of(ws, db, e^) {
		av, ok := term_av(ws, db, e^, term)
		if term.knob != .Amount || !ok || e.inactive {continue}
		gain := term_value(db, term, e^, e.elapsed)
		if e.applied {gain -= term_value(db, term, e^, t0)}
		av_gain(ws, db, e.caster if term.on_caster else e.target, av, f32(gain))
	}
	e.applied = true
	if !e.lasts && e.elapsed >= e.duration + e.taper {end_effect(ws, h)}
}

// av_live is what the running effects on `actor` hold on `av`'s capacity now.
av_live :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	sum: f64
	for h in effects_on(ws, actor) {
		e := ws.effects[h]
		if e.ended || e.inactive {continue}
		for term in effect_terms_of(ws, db, e) {
			name, ok := term_av(ws, db, e, term)
			if term.knob == .Capacity && !term.on_caster && ok && name == av {sum += term_value(db, term, e, e.elapsed)}
		}
	}
	return f32(sum)
}

// term_value is a term's formula at `t` seconds in (EFFECT_VARS); a timed effect's t stops at its end.
@(private)
term_value :: proc(db: ^gamedb.DB, term: Effect_Term, e: Active_Effect, t: f32) -> f64 {
	mgef, _ := gamedb.magic_effect_of(db, e.effect)
	info := mgef.info
	t := t if e.lasts else min(t, e.duration + e.taper)
	held := e.lasts || info.flags & esm.MGEF_RECOVER != 0
	sign: f64 = -1 if info.flags & esm.MGEF_DETRIMENTAL != 0 else 1
	return formula.eval(term.f, {f64(t), f64(e.magnitude), f64(e.duration), 1 if held else 0, sign, f64(info.second_av_weight), f64(info.taper_weight), f64(info.taper_curve), f64(info.taper_duration)})
}

// term_av is the actor value a term moves: its own, or the MGEF's for a slot.
@(private)
term_av :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect, term: Effect_Term) -> (string, bool) {
	index: i32
	switch term.av {
	case "primary", "secondary":
		mgef, _ := gamedb.magic_effect_of(db, e.effect)
		index = mgef.info.primary_av if term.av == "primary" else mgef.info.second_av
	case:
		return av_name(ws, term.av)
	}
	if index < 0 || int(index) >= len(gamedb.AV_NAMES) {return "", false}
	return gamedb.AV_NAMES[index], true
}

// effect_classes is the script classes an effect runs (lower case): its MGEF's scripts, then its
// archetype's class unless one of them claims the effect (defines __effect).
effect_classes :: proc(ws: ^World_State, db: ^gamedb.DB, effect: Form_ID) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	claimed := false
	for s in gamedb.form_scripts(db, effect) {
		name := strings.to_lower(s.name, context.temp_allocator)
		append(&out, name)
		if c, ok := ws.effect_classes[name]; ok && c.claims {claimed = true}
	}
	mgef, _ := gamedb.magic_effect_of(db, effect)
	if arch := archetype_class(mgef.info.archetype); arch != "" && !claimed {append(&out, arch)}
	return out[:]
}

// archetype_class is the class that plays an archetype: a pure-formula script in the core scripts
// mod (src/script/effects), which a mod replaces like any script. "" for one no class plays.
// (hole other-archetypes :tags magic :sev gap) only Value Modifier, Peak Value Modifier, Dual Value Modifier and Absorb have a class; summon, paralysis, invisibility, cloak, bound weapon, calm/frenzy and the rest start an effect that does nothing.
archetype_class :: proc(a: esm.Effect_Archetype) -> string {
	#partial switch a {
	case .Value_Modifier:      return "archetypevaluemodifier"
	case .Peak_Value_Modifier: return "archetypepeakvaluemodifier"
	case .Dual_Value_Modifier: return "archetypedualvaluemodifier"
	case .Absorb:              return "archetypeabsorb"
	}
	return ""
}

// effect_terms_of is the __effect terms of an effect's classes, once they loaded.
@(private)
effect_terms_of :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> []Effect_Term {
	out := make([dynamic]Effect_Term, context.temp_allocator)
	for name in effect_classes(ws, db, e.effect) {
		if c, ok := ws.effect_classes[name]; ok {append(&out, ..c.terms[:])}
	}
	return out[:]
}

// remove_effect drops an ended effect whose instance has stopped ticking.
remove_effect :: proc(ws: ^World_State, h: Form_ID) {
	e, ok := ws.effects[h]
	if !ok {return}
	if list, has := &ws.effects_on[e.target]; has {
		for i := len(list) - 1; i >= 0; i -= 1 {
			if list[i] == h {ordered_remove(list, i)}
		}
		if len(list) == 0 {
			delete(list^)
			delete_key(&ws.effects_on, e.target)
		}
	}
	delete_key(&ws.effects, h)
}

// effects_on lists the live effects on `target` (the handles its events also reach).
effects_on :: proc(ws: ^World_State, target: Form_ID) -> []Form_ID {
	list, _ := ws.effects_on[target]
	return list[:]
}

// has_effect is HasMagicEffect: a running effect of that MGEF on the target.
has_effect :: proc(ws: ^World_State, target, effect: Form_ID) -> bool {
	for h in effects_on(ws, target) {
		if e := ws.effects[h]; e.effect == effect && !e.finished {return true}
	}
	return false
}

// has_effect_keyword is HasMagicEffectWithKeyword: a running effect on the target whose MGEF has
// the keyword.
has_effect_keyword :: proc(ws: ^World_State, db: ^gamedb.DB, target, keyword: Form_ID) -> bool {
	for h in effects_on(ws, target) {
		if e := ws.effects[h]; !e.finished && gamedb.has_keyword(db, e.effect, keyword) {return true}
	}
	return false
}

@(private)
index_effect :: proc(ws: ^World_State, h, target: Form_ID) {
	if target not_in ws.effects_on {ws.effects_on[target] = make([dynamic]Form_ID)}
	append(&ws.effects_on[target], h)
}

// Effect_Class is what the engine keeps of a script class that defines __effect: its terms, and
// whether it needs no instance (pure: no functions anywhere in its chain), so the engine runs it
// alone.
Effect_Class :: struct {
	terms:  [dynamic]Effect_Term,
	claims: bool, // it stands in for its MGEF's archetype (the default; __claims_archetype = false opts out)
	pure:   bool,
}

// Effect_Term is one formula of a class's __effect table, over EFFECT_VARS.
Effect_Term :: struct {
	av:        string, // owned: an actor value's name, or the slot "primary" / "secondary"
	knob:      Knob,
	f:         formula.Formula,
	on_caster: bool, // from the table's `caster` part (Absorb's other half); amount only
}

// EFFECT_VARS: seconds since start, magnitude, duration, 1 when held (Recover or lasting), -1 when
// Detrimental else 1, the dual weight, and the taper's weight, curve and duration.
EFFECT_VARS := []string{"t", "m", "d", "held", "sign", "w", "tw", "tc", "td"}

// Effect_Src is one uncompiled term: `src` is its formula string.
Effect_Src :: struct {
	av:        string,
	knob:      Knob,
	src:       string,
	on_caster: bool,
}

// set_effect_class compiles a class's __effect table when the class loads. A bad formula warns and
// drops only its term.
set_effect_class :: proc(ws: ^World_State, class: string, srcs: []Effect_Src, claims, pure: bool) {
	c := Effect_Class{terms = make([dynamic]Effect_Term), claims = claims, pure = pure}
	for s in srcs {
		f, err := formula.compile(s.src, EFFECT_VARS)
		if err != "" {
			log.warnf("script: %s.__effect %s.%v = %q: %s (variables %v)", class, s.av, s.knob, s.src, err, EFFECT_VARS)
			continue
		}
		append(&c.terms, Effect_Term{av = strings.clone(s.av), knob = s.knob, f = f, on_caster = s.on_caster})
	}
	if old, ok := &ws.effect_classes[class]; ok {
		free_effect_class(old)
		old^ = c
		return
	}
	ws.effect_classes[strings.clone(class)] = c
}

@(private)
free_effect_class :: proc(c: ^Effect_Class) {
	for &t in c.terms {
		delete(t.av)
		formula.destroy(&t.f)
	}
	delete(c.terms)
}
