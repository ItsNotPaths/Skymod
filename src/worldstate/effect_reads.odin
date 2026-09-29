package worldstate

// What an effect formula may read (formula.Read): caster.X and target.X (an actor value, or Level),
// global.X (a GLOB by editor id), and condition functions by name, `HasPerk(caster, X)`. A call's
// first argument may name its subject (caster or target; target when left out); its form arguments
// are editor ids or "File.esm:012FCD", and a trailing one left out is 0.

import "core:strconv"
import "core:strings"
import "../formats/esm"
import "../formula"
import "../gamedb"

// condition_call answers a condition function run on `subject`; the conditions package sets it,
// since it sits above worldstate. Nil reads 0.
condition_call: proc(ws: ^World_State, db: ^gamedb.DB, c: gamedb.Condition, subject, target: Form_ID) -> f32

// Read_Kind is a bound read's bound[0].
@(private)
Read_Kind :: enum u64 {
	Target, // target.X, or a call run on the target
	Caster,
	Global, // bound[1]: the GLOB
}

// A call's bound: [0] its subject, [1] 1 + the function's index, [2] and [3] its parameters.
@(private)
effect_bind :: proc(data: rawptr, r: ^formula.Read) -> string {
	db := cast(^gamedb.DB)data
	if r.object != "" {
		switch r.object {
		case "caster": r.bound[0] = u64(Read_Kind.Caster)
		case "target": r.bound[0] = u64(Read_Kind.Target)
		case "global":
			g, ok := gamedb.global_by_editor_id(db, r.name)
			if !ok {return "unknown global"}
			r.bound = {u64(Read_Kind.Global), u64(g), 0, 0}
		case: return "unknown subject: use caster, target or global"
		}
		return ""
	}
	fn := -1
	for f, i in esm.CONDITION_FUNCTIONS {
		if f.name != "" && strings.equal_fold(f.name, r.name) {fn = i}
	}
	if fn < 0 {return "unknown function"}
	args := r.args
	if len(args) > 0 && (args[0] == "caster" || args[0] == "target") {
		r.bound[0] = u64(Read_Kind.Caster if args[0] == "caster" else Read_Kind.Target)
		args = args[1:]
	}
	r.bound[1] = u64(fn + 1)
	n := 0
	for kind, i in esm.CONDITION_FUNCTIONS[fn].params {
		if kind == .None {break}
		n += 1
		if i >= len(args) {continue} // a left-out parameter is 0
		switch kind {
		case .None:
		case .String: return "a function taking a string cannot be called from a formula"
		case .Number:
			v, ok := param_number(args[i])
			if !ok {return "expected a number or an actor value name"}
			r.bound[2 + i] = v
		case .Form, .Ref:
			f, ok := form_arg(db, args[i])
			if !ok {return "unknown form"}
			r.bound[2 + i] = u64(f)
		}
	}
	if len(args) > n {return "too many arguments"}
	return ""
}

// param_number reads a number parameter: a number, or an actor value's index (GetActorValuePercent).
@(private)
param_number :: proc(text: string) -> (v: u64, ok: bool) {
	if v, ok := strconv.parse_i64(text); ok {return u64(v), true}
	name := gamedb.actor_value_name(text) or_return
	for av, i in gamedb.AV_NAMES {
		if av == name {return u64(i), true}
	}
	return 0, false
}

// form_arg is the form an argument names: "File.esm:012FCD", or an editor id.
@(private)
form_arg :: proc(db: ^gamedb.DB, text: string) -> (f: Form_ID, ok: bool) {
	if file, colon, local := strings.partition(text, ":"); colon != "" {
		v := strconv.parse_u64(local, 16) or_return
		return gamedb.form_from_file(db, u32(v), file)
	}
	return gamedb.form_by_editor_id(db, text)
}

// Effect_Read is what an effect formula's reads see.
@(private)
Effect_Read :: struct {
	ws:             ^World_State,
	db:             ^gamedb.DB,
	caster, target: Form_ID,
}

@(private)
effect_read :: proc(data: rawptr, r: formula.Read) -> f64 {
	x := cast(^Effect_Read)data
	subject, other := x.target, x.caster
	switch Read_Kind(r.bound[0]) {
	case .Target:
	case .Caster: subject, other = x.caster, x.target
	case .Global: return f64(global_value(x.ws, x.db, Form_ID(r.bound[1])))
	}
	if r.bound[1] > 0 {
		if condition_call == nil {return 0}
		c := gamedb.Condition{function = u16(r.bound[1] - 1), param1 = r.bound[2], param2 = r.bound[3], param3 = -1}
		return f64(condition_call(x.ws, x.db, c, subject, other))
	}
	if r.name == "Level" {return f64(actor_level(x.ws, x.db, subject))}
	av, ok := av_name(x.ws, r.name) // a mod's AV may not exist in this game: 0
	return f64(av_current(x.ws, x.db, subject, av)) if ok else 0
}
