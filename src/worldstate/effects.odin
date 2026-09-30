package worldstate

import "core:log"
import "core:slice"
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
	motion:    Effect_Motion `cbor:"-"`, // a cache of effect_motion; not saved, so a mod update reaches old saves
	tunables:  [MAX_TUNABLES]f32, // its definition's tunables as it landed (Effect_Def.tunables order)
}

// (hole tunables-by-name :tags (magic save) :sev polish) a running effect saves its tunables by position: a mod update that adds or renames one shifts the values of effects running in an old save.

// Effect_Motion is whether an effect's amount terms still change with time (effect_motion).
Effect_Motion :: enum u8 {
	Unknown,
	Still,
	Moving,
}

// start_effect adds an effect on `target` and returns its handle; the VM gives it its script and
// sends OnMagicEffectApply and OnEffectStart (slua.sync_refs).
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
// `hurt`: it took Health from its target this tick.
advance_effect :: proc(ws: ^World_State, db: ^gamedb.DB, h: Form_ID, dt: f32) -> (hurt: bool) {
	e := &ws.effects[h]
	if e.ended {return}
	t0 := e.elapsed
	e.elapsed += dt
	if e.motion == .Unknown {e.motion = effect_motion(ws, db, e^)}
	if !e.applied || e.motion == .Moving { // once applied, a still effect's gains are all zero
		for term in effect_terms_of(ws, db, e^) {
			if term.knob != .Amount || e.inactive {continue}
			av, ok := term_av(ws, db, e^, term)
			if !ok {continue}
			gain := term_value(ws, db, term, e^, e.elapsed)
			if e.applied {gain -= term_value(ws, db, term, e^, t0)}
			av_gain(ws, db, e.caster if term.on_caster else e.target, av, f32(gain))
			hurt ||= !term.on_caster && av == "Health" && gain < 0
		}
		e.applied = true
	}
	if !e.lasts && e.elapsed >= e.duration + e.taper {end_effect(ws, h)}
	return
}

// av_live is what the running effects on `actor` hold on `av`'s capacity now. A term may read the
// AV it feeds (Fortify Health by 10% of Health); past iEffectRecursionDepth such a read gets the AV
// without the terms still being summed.
av_live :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, av: string) -> f32 {
	key := AV_Sum{actor, av}
	if slice.count(ws.summing[:], key) >= int(gamedb.setting_int(db, "iEffectRecursionDepth", 1)) {
		if !ws.loop_warned[av] {
			ws.loop_warned[av] = true
			log.warnf("effect formula: %s reads itself through the effects %X; the read stops at iEffectRecursionDepth", av, effect_forms(ws, actor))
		}
		return 0
	}
	append(&ws.summing, key)
	defer pop(&ws.summing)
	sum: f64
	for h in effects_on(ws, actor) {
		e := ws.effects[h]
		if e.ended || e.inactive {continue}
		for term in effect_terms_of(ws, db, e) {
			name, ok := term_av(ws, db, e, term)
			if term.knob == .Capacity && !term.on_caster && ok && name == av {sum += term_value(ws, db, term, e, e.elapsed)}
		}
	}
	return f32(sum)
}

// AV_Sum is an actor value av_live is summing.
AV_Sum :: struct {
	actor: Form_ID,
	av:    string,
}

// effect_forms lists the MGEFs running on `actor`, for a warning.
@(private)
effect_forms :: proc(ws: ^World_State, actor: Form_ID) -> []Form_ID {
	out := make([dynamic]Form_ID, context.temp_allocator)
	for h in effects_on(ws, actor) {append(&out, ws.effects[h].effect)}
	return out[:]
}

// term_value is a term's formula at `t` seconds in (EFFECT_VARS); a timed effect's t stops at its end.
@(private)
term_value :: proc(ws: ^World_State, db: ^gamedb.DB, term: Effect_Term, e: Active_Effect, t: f32) -> f64 {
	t := t if e.lasts else min(t, e.duration + e.taper)
	vars := term_vars(db, e, t)
	e := e
	reads := Effect_Read{ws, db, e.caster, e.target, e.tunables[:]}
	return formula.eval(term.f, vars[:], {&reads, effect_read})
}

// effect_motion is .Moving when any amount term can change with t, given the effect's magnitude,
// duration and MGEF (formula.varies); a lasting Value Modifier's is still.
@(private)
effect_motion :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> Effect_Motion {
	vars := term_vars(db, e, 0)
	for term in effect_terms_of(ws, db, e) {
		if term.knob == .Amount && formula.varies(term.f, 0, vars[:]) {return .Moving}
	}
	return .Still
}

// term_vars are the values of EFFECT_VARS for `e` at `t`.
@(private)
term_vars :: proc(db: ^gamedb.DB, e: Active_Effect, t: f32) -> [len(EFFECT_VARS_ARRAY)]f64 {
	mgef, _ := gamedb.magic_effect_of(db, e.effect)
	info := mgef.info
	held := e.lasts || info.flags & esm.MGEF_RECOVER != 0
	sign: f64 = -1 if info.flags & esm.MGEF_DETRIMENTAL != 0 else 1
	return {f64(t), f64(e.magnitude), f64(e.duration), 1 if held else 0, sign, f64(info.second_av_weight), f64(info.taper_weight), f64(info.taper_curve), f64(info.taper_duration)}
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
	if index < 0 || int(index) >= len(esm.AV_NAMES) {return "", false}
	return esm.AV_NAMES[index], true
}

// effect_classes is the script classes an effect runs (lower case): its definition's scripts, or its
// MGEF's scripts, then its archetype's class unless one of them claims the effect (defines __effect).
effect_classes :: proc(ws: ^World_State, db: ^gamedb.DB, effect: Form_ID) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if d, ok := ws.effect_defs[effect]; ok { // a definition has no archetype
		for s in d.scripts {append(&out, strings.to_lower(s.name, context.temp_allocator))}
		return out[:]
	}
	claimed := false
	for s in gamedb.form_scripts(db, effect) {
		name := strings.to_lower(s.name, context.temp_allocator)
		append(&out, name)
		if c, ok := ws.effect_classes[name]; ok && c.claims {claimed = true}
	}
	mgef, _ := gamedb.magic_effect_of(db, effect)
	if arch := gamedb.archetype_class(mgef.info.archetype); arch != "" && !claimed {append(&out, arch)}
	return out[:]
}

// effect_terms_of is an effect's definition's terms, or the __effect terms of its classes, once
// they loaded. The terms share
// their classes' formulas.
@(private)
effect_terms_of :: proc(ws: ^World_State, db: ^gamedb.DB, e: Active_Effect) -> []Effect_Term {
	if d, ok := ws.effect_defs[e.effect]; ok {return d.terms[:]}
	if terms, ok := ws.effect_terms[e.effect]; ok {return terms}
	out := make([dynamic]Effect_Term)
	for name in effect_classes(ws, db, e.effect) {
		if c, ok := ws.effect_classes[name]; ok {append(&out, ..c.terms[:])}
	}
	ws.effect_terms[e.effect] = out[:]
	return out[:]
}

@(private)
forget_effect_terms :: proc(ws: ^World_State) {
	for _, terms in ws.effect_terms {delete(terms)}
	clear(&ws.effect_terms)
	for _, &e in ws.effects {e.motion = .Unknown}
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
		if e := ws.effects[h]; !e.finished && effect_has_keyword(ws, db, e.effect, keyword) {return true}
	}
	return false
}

// effect_has_keyword: a defined effect has the keywords its tags name (kw.<editor id>), a record
// its KWDA.
effect_has_keyword :: proc(ws: ^World_State, db: ^gamedb.DB, effect, keyword: Form_ID) -> bool {
	if _, ok := ws.effect_defs[effect]; !ok {return gamedb.has_keyword(db, effect, keyword)}
	edid := gamedb.keyword_editor_id(db, keyword)
	for t in ws.tags[effect] {
		if strings.has_prefix(t, "kw.") && strings.equal_fold(t[3:], edid) {return true}
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
EFFECT_VARS_ARRAY := [?]string{"t", "m", "d", "held", "sign", "w", "tw", "tc", "td"}
EFFECT_VARS := EFFECT_VARS_ARRAY[:]

// Effect_Src is one uncompiled term: `src` is its formula string.
Effect_Src :: struct {
	av:        string,
	knob:      Knob,
	src:       string,
	on_caster: bool,
}

// set_effect_class compiles a class's __effect table when the class loads. A bad formula warns and
// drops only its term.
set_effect_class :: proc(ws: ^World_State, db: ^gamedb.DB, class: string, srcs: []Effect_Src, claims, pure: bool) {
	forget_effect_terms(ws)
	c := Effect_Class{terms = make([dynamic]Effect_Term), claims = claims, pure = pure}
	for s in srcs {
		bind := Def_Bind{ws, db, nil}
		f, err := formula.compile(s.src, EFFECT_VARS, binder = {&bind, effect_bind})
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
