package worldstate

import "core:log"
import "core:strings"
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
	magnitude: f32,  // as authored
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
		av, ok := av_name(ws, term.av)
		if term.knob != .Amount || !ok {continue}
		gain := term_value(term, e^, e.elapsed)
		if e.applied {gain -= term_value(term, e^, t0)}
		av_gain(ws, db, e.target, av, f32(gain))
	}
	e.applied = true
	if !e.lasts && e.elapsed >= e.duration {end_effect(ws, h)}
}

// av_live is what the running effects on `actor` hold on `av`'s capacity now.
av_live :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	sum: f64
	for h in effects_on(ws, actor) {
		e := ws.effects[h]
		if e.ended {continue}
		for term in effect_terms_of(ws, db, e) {
			name, ok := av_name(ws, term.av)
			if term.knob == .Capacity && ok && name == av {sum += term_value(term, e, e.elapsed)}
		}
	}
	return f32(sum)
}

// term_value is a term's formula at `t` seconds in; a timed effect's t stops at its duration.
@(private)
term_value :: proc(term: Effect_Term, e: Active_Effect, t: f32) -> f64 {
	t := t if e.lasts else min(t, e.duration)
	return formula.eval(term.f, {f64(t), f64(e.magnitude), f64(e.duration)})
}

// effect_terms_of is the __effect terms of an effect's MGEF scripts, once their classes loaded.
@(private)
effect_terms_of :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> []Effect_Term {
	out := make([dynamic]Effect_Term, context.temp_allocator)
	for s in gamedb.form_scripts(db, e.effect) {
		if terms, ok := ws.effect_terms[strings.to_lower(s.name, context.temp_allocator)]; ok {append(&out, ..terms[:])}
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

@(private)
index_effect :: proc(ws: ^World_State, h, target: Form_ID) {
	if target not_in ws.effects_on {ws.effects_on[target] = make([dynamic]Form_ID)}
	append(&ws.effects_on[target], h)
}

// Effect_Term is one formula of a script class's __effect table, over EFFECT_VARS.
Effect_Term :: struct {
	av:   string, // owned; resolved when the effect starts
	knob: Knob,
	f:    formula.Formula,
}

EFFECT_VARS := []string{"t", "m", "d"} // seconds since start, magnitude, duration

// Effect_Src is one uncompiled term: `src` is its formula string.
Effect_Src :: struct {
	av:   string,
	knob: Knob,
	src:  string,
}

// set_effect_terms compiles a class's __effect table when the class loads. A bad formula warns and
// drops only its term.
set_effect_terms :: proc(ws: ^World_State, class: string, srcs: []Effect_Src) {
	terms := make([dynamic]Effect_Term)
	for s in srcs {
		f, err := formula.compile(s.src, EFFECT_VARS)
		if err != "" {
			log.warnf("script: %s.__effect %s.%v = %q: %s (variables %v)", class, s.av, s.knob, s.src, err, EFFECT_VARS)
			continue
		}
		append(&terms, Effect_Term{strings.clone(s.av), s.knob, f})
	}
	if old, ok := &ws.effect_terms[class]; ok {
		free_effect_terms(old)
		old^ = terms
		return
	}
	ws.effect_terms[strings.clone(class)] = terms
}

@(private)
free_effect_terms :: proc(terms: ^[dynamic]Effect_Term) {
	for &t in terms {
		delete(t.av)
		formula.destroy(&t.f)
	}
	delete(terms^)
}
