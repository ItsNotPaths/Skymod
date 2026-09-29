package worldstate

// Effects content defines (rt.effect): the engine's table of them, keyed by form. A definition
// stands in for its form's record: its terms, scripts, tags and `when` replace the MGEF's archetype,
// VMAD scripts, keywords and conditions. Not saved: content defines them again as each game starts.

import "core:log"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../formid"
import "../formula"
import "../gamedb"

MAX_TUNABLES :: 8

// Effect_Def is one defined effect, compiled.
Effect_Def :: struct {
	name:     string, // owned
	terms:    [dynamic]Effect_Term,
	landing:  [dynamic]Effect_Landing,
	tunables: [dynamic]string, // owned, sorted: Active_Effect.tunables in this order
	gate:     Maybe(formula.Formula), // `when`: checked once as it lands
	scripts:  []esm.Script_Attach, // the moments; owned (esm.free_form_scripts shape)
}

// Effect_Landing is a number worked out once as the effect lands: m, d, or a tunable.
Effect_Landing :: struct {
	name: string, // owned
	f:    formula.Formula,
}

// Effect_Def_Src is a definition as content wrote it: formulas as strings, borrowed.
Effect_Def_Src :: struct {
	name, form: string, // form: "File.esm:012FCD" or an editor id; "" makes a Lua form
	tags:       []string,
	terms:      []Effect_Src,
	landing:    [][2]string, // {name, formula}
	gate:       string, // `when`
	scripts:    []esm.Script_Attach, // borrowed; cloned here
}

// LANDING_VARS: what landing formulas and `when` see as the effect lands.
LANDING_VARS_ARRAY := [?]string{"t", "m", "d"}
LANDING_VARS := LANDING_VARS_ARRAY[:]

// set_effect_def compiles a definition and makes it the one for its form, which it returns. A bad
// formula warns and drops only its part.
set_effect_def :: proc(ws: ^World_State, db: ^gamedb.DB, src: Effect_Def_Src) -> (Form_ID, bool) {
	form := formid.lua_form(src.name)
	if src.form != "" {
		f, ok := form_arg(db, src.form)
		if !ok {
			log.warnf("rt.effect %s: no form %q", src.name, src.form)
			return 0, false
		}
		form = f
	}
	if old, ok := &ws.effect_defs[form]; ok && !strings.equal_fold(old.name, src.name) {
		log.warnf("rt.effect %s: its form is %s's too; %s wins", src.name, old.name, src.name)
	}
	forget_effect_terms(ws)

	d := Effect_Def{name = strings.clone(src.name)}
	warn :: proc(name, part, src, err: string) {log.warnf("rt.effect %s: %s = %q: %s", name, part, src, err)}
	for l in src.landing {
		if l[0] == "m" || l[0] == "d" {continue}
		if len(d.tunables) == MAX_TUNABLES {
			warn(src.name, l[0], l[1], "too many tunables")
			continue
		}
		append(&d.tunables, strings.clone(l[0]))
	}
	slice.sort(d.tunables[:])
	none := Def_Bind{db = db}
	with := Def_Bind{db = db, tunables = d.tunables[:]}
	for l in src.landing {
		if l[0] != "m" && l[0] != "d" && !slice.contains(d.tunables[:], l[0]) {continue}
		f, err := formula.compile(l[1], LANDING_VARS, binder = {&none, def_bind})
		if err != "" {warn(src.name, l[0], l[1], err); continue}
		append(&d.landing, Effect_Landing{strings.clone(l[0]), f})
	}
	for s in src.terms {
		f, err := formula.compile(s.src, LANDING_VARS, binder = {&with, def_bind})
		if err != "" {warn(src.name, s.av, s.src, err); continue}
		append(&d.terms, Effect_Term{av = strings.clone(s.av), knob = s.knob, f = f, on_caster = s.on_caster})
	}
	if src.gate != "" {
		if f, err := formula.compile(src.gate, LANDING_VARS, binder = {&with, def_bind}); err != "" {
			warn(src.name, "when", src.gate, err)
		} else {
			d.gate = f
		}
	}
	d.scripts = clone_scripts(src.scripts)
	set_tags(ws, form, src.tags)

	if old, ok := &ws.effect_defs[form]; ok {
		free_effect_def(old)
		old^ = d
	} else {
		ws.effect_defs[form] = d
	}
	return form, true
}

// (hole effect-land :tags (magic script) :sev gap) an effect decides at landing with formula strings (m, d, tunables, `when`); it should be Lua, `land = function(e)`: return false to not start, set e.d, capture tunables, e:apply riders (user, 2026-09-28). Needs a VM callback on script.Call, as quest_vars is.
// land_effect works out a defined effect's landing numbers and checks its `when`: false, and the
// effect does not start. An effect with no definition always lands.
land_effect :: proc(ws: ^World_State, db: ^gamedb.DB, e: ^Active_Effect) -> bool {
	d, ok := ws.effect_defs[e.effect]
	if !ok {return true}
	reads := Effect_Read{ws, db, e.caster, e.target, nil}
	vars := [3]f64{0, f64(e.magnitude), f64(e.duration)}
	m, dur := e.magnitude, e.duration
	for l in d.landing {
		v := f32(formula.eval(l.f, vars[:], {&reads, effect_read}))
		switch l.name {
		case "m": m = v
		case "d": dur = v
		case:
			if i, found := slice.linear_search(d.tunables[:], l.name); found {e.tunables[i] = v}
		}
	}
	e.magnitude, e.duration = m, dur
	w, has := d.gate.?
	if !has {return true}
	reads.tunables = e.tunables[:]
	vars = {0, f64(m), f64(dur)}
	return formula.eval(w, vars[:], {&reads, effect_read}) != 0
}

// effect_scripts are the scripts an effect's instance runs: its definition's, else its record's.
effect_scripts :: proc(ws: ^World_State, db: ^gamedb.DB, effect: Form_ID) -> []esm.Script_Attach {
	if d, ok := ws.effect_defs[effect]; ok {return d.scripts}
	return gamedb.form_scripts(db, effect)
}

// Def_Bind is what a definition's formulas may read besides effect_bind's: its tunables.
@(private)
Def_Bind :: struct {
	db:       ^gamedb.DB,
	tunables: []string,
}

@(private)
def_bind :: proc(data: rawptr, r: ^formula.Read) -> string {
	b := cast(^Def_Bind)data
	if r.object == "" && !r.call {
		i, ok := slice.linear_search(b.tunables, r.name)
		if !ok {return "unknown variable or tunable"}
		r.bound = {u64(Read_Kind.Tunable), u64(i), 0, 0}
		return ""
	}
	return effect_bind(b.db, r)
}

@(private)
clone_scripts :: proc(src: []esm.Script_Attach) -> []esm.Script_Attach {
	out := make([]esm.Script_Attach, len(src))
	for s, i in src {
		out[i] = {name = strings.clone(s.name), status = s.status, props = make([]esm.Script_Prop, len(s.props))}
		for p, j in s.props {
			v := p.value
			if str, is := v.(string); is {v = strings.clone(str)}
			out[i].props[j] = {name = strings.clone(p.name), kind = p.kind, status = p.status, value = v}
		}
	}
	return out
}

@(private)
free_effect_def :: proc(d: ^Effect_Def) {
	delete(d.name)
	for &t in d.terms {
		delete(t.av)
		formula.destroy(&t.f)
	}
	delete(d.terms)
	for &l in d.landing {
		delete(l.name)
		formula.destroy(&l.f)
	}
	delete(d.landing)
	for t in d.tunables {delete(t)}
	delete(d.tunables)
	if w, ok := &d.gate.?; ok {formula.destroy(w)}
	for s in d.scripts {
		delete(s.name)
		for p in s.props {
			delete(p.name)
			if str, is := p.value.(string); is {delete(str)}
		}
		delete(s.props)
	}
	delete(d.scripts)
}
