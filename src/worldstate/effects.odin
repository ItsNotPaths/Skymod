package worldstate

import "core:log"
import "core:strings"
import "../formid"
import "../formula"

// Active_Effect is one scripted magic effect on a target (docs/script-api.md section 3). Its script
// instance keys on the effect handle. Only the script lifecycle is modelled: no magnitude, no
// actor value change. The instance lingers after the effect ends while its state still ticks.
Active_Effect :: struct {
	effect, spell, target, caster: Form_ID,
	lasts:    bool, // an ability or constant effect: until removed
	duration: f32,  // real seconds
	elapsed:  f32,
	ended:    bool, // OnEffectFinish is due or sent
	finished: bool, // OnEffectFinish sent
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
