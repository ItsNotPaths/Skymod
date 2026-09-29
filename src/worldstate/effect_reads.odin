package worldstate

// What an effect formula may read (formula.Read), by the naming rule (ws.md Workstream M, Naming):
// <actor>.av.<Name>.value, .capacity or .amount for caster and target (an engine actor value, a
// perk's rank by its editor id, Level, or a mod's actor value), global.<Name> (a GLOB by editor
// id), and <actor>:Fn(args), a condition function run on that actor. A call's form argument is a
// quoted editor id or "File.esm:012FCD", a bare caster or target is that actor, and a trailing one
// left out is 0. A defined effect's formulas read its tunables by bare name (effect_defs.odin).

import "core:strconv"
import "core:strings"
import "../formats/esm"
import "../formid"
import "../formula"
import "../gamedb"

// condition_call answers a condition function run on `subject`; the conditions package sets it,
// since it sits above worldstate. Nil reads 0.
condition_call: proc(ws: ^World_State, db: ^gamedb.DB, c: gamedb.Condition, subject, target: Form_ID) -> f32

// Read_Kind is a bound read's bound[0]. A perk read's bound[2] is the perk.
@(private)
Read_Kind :: enum u64 {
	Target, // target.X, or a call run on the target
	Caster,
	Global, // bound[1]: the GLOB
	Tunable, // bound[1]: its index in Active_Effect.tunables
}

// A call's Ref argument naming the caster or the target (GetDistance(target, caster)).
@(private)
ARG_CASTER :: max(u64)
@(private)
ARG_TARGET :: max(u64) - 1

// AV_Part is which part of an actor value a read wants (a formula read's bound[3]).
AV_Part :: enum u64 {
	Value,
	Capacity,
	Amount,
}

// An AV read's bound: [0] its actor, [2] the perk it names, [3] its part. A call's: [0] its
// subject, [1] 1 + the function's index, [2] and [3] its parameters.
@(private)
effect_bind :: proc(data: rawptr, r: ^formula.Read) -> string {
	b := cast(^Def_Bind)data
	db := b.db
	switch r.object {
	case "": return "unknown variable" // a definition's tunables: def_bind
	case "global":
		g, ok := gamedb.global_by_editor_id(db, r.name)
		if r.call || !ok {return "unknown global"}
		r.bound = {u64(Read_Kind.Global), u64(g), 0, 0}
		return ""
	case "caster": r.bound[0] = u64(Read_Kind.Caster)
	case "target": r.bound[0] = u64(Read_Kind.Target)
	case: return "unknown subject: use caster, target or global"
	}
	if !r.call {return bind_av(db, r)}
	fn := -1
	for f, i in esm.CONDITION_FUNCTIONS {
		if f.name != "" && strings.equal_fold(f.name, r.name) {fn = i}
	}
	if fn < 0 {return "unknown function"}
	r.bound[1] = u64(fn + 1)
	n := 0
	for kind, i in esm.CONDITION_FUNCTIONS[fn].params {
		if kind == .None {break}
		n += 1
		if i >= len(r.args) {continue} // a left-out parameter is 0
		arg, quoted := r.args[i], i in r.quoted
		switch kind {
		case .None:
		case .String: return "a function taking a string cannot be called from a formula"
		case .Number:
			v, ok := param_number(arg)
			if !ok {return "expected a number or an actor value name"}
			r.bound[2 + i] = v
		case .Form, .Ref:
			switch {
			case quoted:
				f, ok := form_by_name(b.ws, db, arg)
				if !ok {return "unknown form"}
				r.bound[2 + i] = u64(f)
			case kind == .Ref && (arg == "caster" || arg == "target"):
				r.bound[2 + i] = ARG_CASTER if arg == "caster" else ARG_TARGET
			case: return "a form argument is a quoted editor id, or caster or target"
			}
		}
	}
	if len(r.args) > n {return "too many arguments"}
	return ""
}

// bind_av checks av.<Name>.<part> and leaves the actor value's name in r.name.
@(private)
bind_av :: proc(db: ^gamedb.DB, r: ^formula.Read) -> string {
	ns, _, rest := strings.partition(r.name, ".")
	av, _, part := strings.partition(rest, ".")
	switch part {
	case "value":    r.bound[3] = u64(AV_Part.Value)
	case "capacity": r.bound[3] = u64(AV_Part.Capacity)
	case "amount":   r.bound[3] = u64(AV_Part.Amount)
	case:            ns = ""
	}
	if ns != "av" || av == "" {return "read an actor value as <actor>.av.<Name>.value, .capacity or .amount"}
	if _, engine := gamedb.actor_value_name(av); !engine {
		if f, ok := gamedb.form_by_editor_id(db, av); ok {
			if _, perk := gamedb.perk_of(db, f); perk {r.bound[2] = u64(f)}
		}
	}
	r.name = av
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

// form_by_name is the form a string names: "File.esm:012FCD", or an editor id, where a defined
// spell's or effect's name counts as one.
form_by_name :: proc(ws: ^World_State, db: ^gamedb.DB, text: string) -> (f: Form_ID, ok: bool) {
	if file, colon, local := strings.partition(text, ":"); colon != "" {
		v := strconv.parse_u64(local, 16) or_return
		return gamedb.form_from_file(db, u32(v), file)
	}
	if f, ok = defined_by_name(ws.spell_defs, "spell", text); ok {return}
	if f, ok = defined_by_name(ws.effect_defs, "effect", text); ok {return}
	return gamedb.form_by_editor_id(db, text)
}

// defined_by_name finds a definition by its name: at its Lua form, or at the record form it claims.
@(private)
defined_by_name :: proc(defs: map[Form_ID]$T, kind, name: string) -> (Form_ID, bool) {
	if f := formid.lua_form(kind, name); f in defs {return f, true}
	for f, d in defs {
		if strings.equal_fold(d.name, name) {return f, true}
	}
	return 0, false
}

// Effect_Read is what an effect formula's reads see.
@(private)
Effect_Read :: struct {
	ws:             ^World_State,
	db:             ^gamedb.DB,
	caster, target: Form_ID,
	tunables:       []f32,
}

@(private)
effect_read :: proc(data: rawptr, r: formula.Read) -> f64 {
	x := cast(^Effect_Read)data
	subject, other := x.target, x.caster
	switch Read_Kind(r.bound[0]) {
	case .Target:
	case .Caster: subject, other = x.caster, x.target
	case .Global: return f64(global_value(x.ws, x.db, Form_ID(r.bound[1])))
	case .Tunable: return f64(x.tunables[r.bound[1]]) if int(r.bound[1]) < len(x.tunables) else 0
	}
	if r.bound[1] > 0 {
		if condition_call == nil {return 0}
		param :: proc(x: ^Effect_Read, p: u64) -> u64 {
			switch p {
			case ARG_CASTER: return u64(x.caster)
			case ARG_TARGET: return u64(x.target)
			}
			return p
		}
		c := gamedb.Condition{function = u16(r.bound[1] - 1), param1 = param(x, r.bound[2]), param2 = param(x, r.bound[3]), param3 = -1}
		return f64(condition_call(x.ws, x.db, c, subject, other))
	}
	part := AV_Part(r.bound[3])
	if perk := Form_ID(r.bound[2]); perk != 0 {return f64(perk_part(x.ws, x.db, subject, perk, part))}
	return f64(av_part(x.ws, x.db, subject, r.name, part))
}

// av_part reads a part of `actor`'s actor value `name` (the naming rule's <actor>.av.<Name>.<part>):
// an engine or mod actor value, Level, or a perk by its editor id. An unknown name reads 0.
av_part :: proc(ws: ^World_State, db: ^gamedb.DB, actor: Form_ID, name: string, part: AV_Part) -> f32 {
	if name == "Level" {return f32(actor_level(ws, db, actor))}
	if av, ok := av_name(ws, name); ok {
		switch part {
		case .Value:    return av_current(ws, db, actor, av)
		case .Capacity: return av_max(ws, db, actor, av)
		case .Amount:   return av_amount(ws, db, actor, av)
		}
	}
	if f, ok := gamedb.form_by_editor_id(db, name); ok {
		if _, perk := gamedb.perk_of(db, f); perk {return perk_part(ws, db, actor, f, part)}
	}
	return 0
}

// perk_part is a perk read as an actor value: its value and amount the ranks held, its capacity
// the ranks its chain has.
@(private)
perk_part :: proc(ws: ^World_State, db: ^gamedb.DB, actor, perk: Form_ID, part: AV_Part) -> f32 {
	if part == .Capacity {return f32(gamedb.perk_ranks(db, perk))}
	return f32(perk_rank(ws, db, actor, perk))
}
