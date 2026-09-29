package worldstate

// Effects content defines (rt.effect): the engine's table of them, keyed by form. A definition
// stands in for its form's record: its terms, scripts, tags and land replace the MGEF's archetype,
// VMAD scripts, keywords and conditions. Not saved: content defines them again as each game starts.

import "core:log"
import "core:math"
import "core:strings"
import "../formats/esm"
import "../formid"
import "../formula"
import "../gamedb"

MAX_TUNABLES :: 8

// Effect_Def is one defined effect, compiled.
Effect_Def :: struct {
	name:     string, // owned
	resist:   string, // owned: the AV that resists it (GetResistance); "" none
	stack:    Stack_Rule,
	nostack:  string, // owned: its group, where only the strongest runs; "" none
	taper:    f32,    // seconds a timed copy goes on after its duration
	terms:    [dynamic]Effect_Term,
	tunables: [dynamic]Tunable, // Active_Effect.tunables in this order
	scripts:  []esm.Script_Attach, // the moments; owned (esm.free_form_scripts shape)
}

// Stack_Rule is what a defined effect does when the same caster lands it again from the same source.
Stack_Rule :: enum u8 {
	Restart, // the running copy ends and the new one starts
	Add,     // both run (lingering poisons, weakness)
	Keep,    // the running copy stays and the new one does not land (No Recast)
}

// Tunable is a name the effect's formulas read bare: its default until land sets it.
Tunable :: struct {
	name:    string, // owned
	default: f32,
}

// Effect_Def_Src is a definition as content wrote it: formulas as strings, borrowed.
Effect_Def_Src :: struct {
	name, form: string, // form: "File.esm:012FCD" or an editor id; "" makes a Lua form
	resist:     string,
	stack:      string, // "restart" (or ""), "add", "keep"
	nostack:    string,
	taper:      string, // "1s", "20tk" or seconds
	tags:       []string,
	terms:      []Effect_Src,
	defaults:   []Tunable, // the definition's numbers
	scripts:    []esm.Script_Attach, // borrowed; cloned here
}

// Hooks are the Lua a landing and a cast run (the VM sets them). land runs the landing hooks
// (rt.hook), then the effect's own land when def has one: false, and it does not start. They may
// change m, d and the tunables. An effect never starts another: a spell names all its effects
// (user, 2026-09-28). cost runs the cost hooks: false, and the cast is refused.
Hooks :: struct {
	data: rawptr,
	land: proc(data: rawptr, def: ^Effect_Def, e: ^Active_Effect) -> bool,
	cost: proc(data: rawptr, caster, spell: Form_ID, cost: ^f32) -> bool,
}

// AV_VARS: what an effect's AV formulas see besides reads and tunables.
AV_VARS_ARRAY := [?]string{"t", "m", "d"}
AV_VARS := AV_VARS_ARRAY[:]

// set_effect_def compiles a definition and makes it the one for its form, which it returns. A bare
// name in a formula is a tunable. A bad formula warns and drops only its term.
set_effect_def :: proc(ws: ^World_State, db: ^gamedb.DB, src: Effect_Def_Src) -> (Form_ID, bool) {
	form := formid.lua_form("effect", src.name)
	if src.form != "" {
		f, ok := form_by_name(ws, db, src.form)
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

	d := Effect_Def{name = strings.clone(src.name), resist = strings.clone(src.resist), nostack = strings.clone(src.nostack)}
	switch src.stack {
	case "restart", "": d.stack = .Restart
	case "add":         d.stack = .Add
	case "keep":        d.stack = .Keep
	case:               log.warnf("rt.effect %s: stack %q is not restart, add or keep", src.name, src.stack)
	}
	if taper, ok := parse_duration(src.taper); ok {
		d.taper = taper
	} else {
		log.warnf("rt.effect %s: taper %q is not \"1s\", \"20tk\" or seconds", src.name, src.taper)
	}
	for t in src.defaults {add_tunable(&d, t.name, t.default)}
	bind := Def_Bind{ws, db, &d}
	for s in src.terms {
		f, err := formula.compile(s.src, AV_VARS, binder = {&bind, def_bind})
		if err != "" {
			log.warnf("rt.effect %s: %s = %q: %s", src.name, s.av, s.src, err)
			continue
		}
		append(&d.terms, Effect_Term{av = strings.clone(s.av), knob = s.knob, f = f, on_caster = s.on_caster})
	}
	d.scripts = clone_scripts(src.scripts)
	set_tags(ws, form, src.tags)
	db.form_kinds[form] = .MagicEffect // `as MagicEffect` and its natives

	if old, ok := &ws.effect_defs[form]; ok {
		free_effect_def(old)
		old^ = d
	} else {
		ws.effect_defs[form] = d
	}
	return form, true
}

// land_effect sets a defined effect's tunables to their defaults, then runs the landing hooks and
// its land. False, and the effect does not start.
land_effect :: proc(ws: ^World_State, db: ^gamedb.DB, e: ^Active_Effect) -> bool {
	d, defined := &ws.effect_defs[e.effect]
	if defined {
		for t, i in d.tunables {e.tunables[i] = t.default}
	} else {
		d = nil
	}
	if ws.hooks.land == nil {return true}
	ok := ws.hooks.land(ws.hooks.data, d, e)
	if math.is_nan(e.duration) || math.is_inf(e.duration) { // a timed effect must end: only its source makes one last
		log.warnf("effect %X: landing set d to %v; it applies once", e.effect, e.duration)
		e.duration = 0
	}
	return ok
}

// effect_resistance is the AV that resists `effect`: its definition's, else its record's; "" none.
effect_resistance :: proc(ws: ^World_State, db: ^gamedb.DB, effect: Form_ID) -> string {
	if d, ok := ws.effect_defs[effect]; ok {return d.resist}
	mgef, _ := gamedb.magic_effect_of(db, effect)
	i := mgef.info.resist_av
	return gamedb.AV_NAMES[i] if i >= 0 && int(i) < len(gamedb.AV_NAMES) else ""
}

// effect_by_name is the effect a name means: a defined one, else a record's by editor id or as
// "File.esm:012FCD".
effect_by_name :: proc(ws: ^World_State, db: ^gamedb.DB, name: string) -> (Form_ID, bool) {
	if f, ok := defined_by_name(ws.effect_defs, "effect", name); ok {return f, true}
	if strings.contains(name, ":") {return form_by_name(ws, db, name)}
	return gamedb.form_by_editor_id(db, name)
}

@(private)
add_tunable :: proc(d: ^Effect_Def, name: string, default: f32) -> (int, bool) {
	for t, i in d.tunables {
		if t.name == name {return i, true}
	}
	if len(d.tunables) == MAX_TUNABLES {return 0, false}
	append(&d.tunables, Tunable{strings.clone(name), default})
	return len(d.tunables) - 1, true
}

// effect_scripts are the scripts an effect's instance runs: its definition's, else its record's.
effect_scripts :: proc(ws: ^World_State, db: ^gamedb.DB, effect: Form_ID) -> []esm.Script_Attach {
	if d, ok := ws.effect_defs[effect]; ok {return d.scripts}
	return gamedb.form_scripts(db, effect)
}

// Def_Bind is what binding an effect's formulas sees; a definition's may also read its tunables,
// any bare name (def nil: an archetype class's may not).
@(private)
Def_Bind :: struct {
	ws:  ^World_State,
	db:  ^gamedb.DB,
	def: ^Effect_Def,
}

@(private)
def_bind :: proc(data: rawptr, r: ^formula.Read) -> string {
	b := cast(^Def_Bind)data
	if r.object == "" && !r.call {
		i, ok := add_tunable(b.def, r.name, 0)
		if !ok {return "too many tunables"}
		r.bound = {u64(Read_Kind.Tunable), u64(i), 0, 0}
		return ""
	}
	return effect_bind(b, r)
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
	delete(d.resist)
	delete(d.nostack)
	for &t in d.terms {
		delete(t.av)
		formula.destroy(&t.f)
	}
	delete(d.terms)
	for t in d.tunables {delete(t.name)}
	delete(d.tunables)
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
