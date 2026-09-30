package magictranslate

// MGEF conditions to Lua: the magichit gate. In an MGEF's conditions the subject is the one hit and the
// target is the caster (edges.md 3), so Subject reads e.target and Target e.actor. An Is/Has
// function answers a boolean in Lua, the rest a number (rt.odin __condition).

import "core:fmt"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// Who names, in Lua, the context a gate runs in and the refs a condition's Subject and Target are;
// "" where that run-on has no Lua form. On a perk's spell tab, `tagged` is the ref whose tags answer
// the spell tests (EPMagic_SpellHasKeyword, EPMagic_SpellHasSkill, HasKeyword).
Who :: struct {
	ctx, subject, target, tagged: string,
}

// MGEF_WHO: an effect's magichit, where Subject is the one hit and Target the caster.
MGEF_WHO :: Who{"e", "e.target", "e.actor", ""}

// land_lua writes an effect's own magichit hook: false from it when the `extra` test or the
// conditions fail, then each dispel (DispelTagged); "" for none. ok=false when a condition has no
// Lua form.
land_lua :: proc(src: ^Source, conds: []gamedb.Condition, dispels: []string, extra := "") -> (text: string, ok: bool) {
	if len(conds) == 0 && len(dispels) == 0 && extra == "" {return "", true}
	tests := make([dynamic]string, context.temp_allocator)
	if extra != "" {append(&tests, extra)}
	if len(conds) > 0 {
		gate := gate_lua(src, conds, MGEF_WHO, "\n        and ") or_return
		if extra != "" && strings.contains(gate, " or ") {gate = fmt.tprintf("(%s)", gate)}
		append(&tests, gate)
	}
	test := strings.join(tests[:], "\n        and ", context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "  hooks = {")
	fmt.sbprintln(&b, "    magichit = function(e)")
	switch {
	case len(dispels) == 0: fmt.sbprintfln(&b, "      return %s", test)
	case len(tests) > 0:    fmt.sbprintfln(&b, "      if not (%s) then return false end", test)
	}
	for d in dispels {fmt.sbprintfln(&b, "      e.target:DispelTagged(%q)", d)}
	fmt.sbprintln(&b, "    end,")
	fmt.sbprintln(&b, "  },")
	return strings.to_string(b), true
}

// gate_lua writes a condition list as one Lua test: an AND of OR runs, joined by `and_`.
@(private)
gate_lua :: proc(src: ^Source, conds: []gamedb.Condition, who: Who, and_: string) -> (text: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	group := make([dynamic]string, context.temp_allocator)
	first := true
	for c, i in conds {
		test := condition_lua(src, c, who) or_return
		append(&group, test)
		if .Or in c.flags && i < len(conds) - 1 {continue}
		term := strings.join(group[:], " or ", context.temp_allocator)
		if len(group) > 1 && len(conds) > len(group) {term = fmt.tprintf("(%s)", term)}
		fmt.sbprintf(&b, "%s%s", "" if first else and_, term)
		clear(&group)
		first = false
	}
	return strings.to_string(b), true
}

// condition_lua writes one condition as a Lua test.
@(private)
condition_lua :: proc(src: ^Source, c: gamedb.Condition, who: Who) -> (text: string, ok: bool) {
	if .Swap in c.flags || .Use_Aliases in c.flags || .Use_Pack_Data in c.flags {return "", false}
	info := esm.condition_function(c.function)
	if who.tagged != "" {
		test, spell_test := spell_test_lua(src, c, info, who)
		if spell_test {
			switch truth(c.op, c.value) {
			case .Yes:     return test, test != ""
			case .No:      return fmt.tprintf("not %s", test), test != ""
			case .Unclear: return "", false
			}
		}
	}
	call := call_lua(src, c, info, who) or_return
	global := .Use_Global in c.flags
	if esm.condition_answers_bool(info.name) {
		switch truth(c.op, c.value) {
		case .Yes:     return call, !global
		case .No:      return fmt.tprintf("not %s", call), !global
		case .Unclear: return "", false
		}
	}
	OPS := [esm.Condition_Op]string{.Equal = "==", .NotEqual = "~=", .Greater = ">", .GreaterOrEqual = ">=", .Less = "<", .LessOrEqual = "<="}
	value := fmt.tprintf("%s.global.%s", who.ctx, src.edids[c.global]) if global else fmt.tprint(c.value)
	return fmt.tprintf("%s %s %s", call, OPS[c.op], value), true
}

// spell_test_lua writes a perk's spell-tab test by tags: a keyword of the effect (the spell's, for a
// cost), its school, the half-cost perk the spell counts as, or which spell it is. An EPMagic_ test
// with none is "" (not translated).
@(private)
spell_test_lua :: proc(src: ^Source, c: gamedb.Condition, info: esm.Condition_Function, who: Who) -> (test: string, is_spell_test: bool) {
	switch info.name {
	case "EPMagic_SpellHasKeyword", "HasKeyword": return fmt.tprintf("%s:HasTag(\"kw.%s\")", who.tagged, src.edids[Form_ID(c.param1)]), true
	case "EPMagic_SpellHasSkill":                 return fmt.tprintf("%s:HasTag(\"school.%s\")", who.tagged, strings.to_lower(av_name(i32(c.param1)), context.temp_allocator)), true
	case "SpellHasCastingPerk":                   return fmt.tprintf("%s:HasTag(\"casting.%s\")", who.subject, src.edids[Form_ID(c.param1)]), true
	case "GetIsID":                               return fmt.tprintf("%s == rt.ref(%q)", who.subject, form_name(src, Form_ID(c.param1))), true
	}
	return "", strings.has_prefix(info.name, "EPMagic_")
}

// call_lua writes the function a condition asks, called on its subject; a global by the naming rule.
@(private)
call_lua :: proc(src: ^Source, c: gamedb.Condition, info: esm.Condition_Function, who: Who) -> (text: string, ok: bool) {
	if info.name == "GetGlobalValue" {return fmt.tprintf("%s.global.%s", who.ctx, src.edids[Form_ID(c.param1)]), true}
	subject: string
	#partial switch c.run_on {
	case .Subject:   subject = who.subject
	case .Target:    subject = who.target
	case .Reference: subject = fmt.tprintf("rt.ref(%q)", form_name(src, c.reference))
	}
	if subject == "" {return "", false}
	args := args_lua(src, c, info) or_return
	return fmt.tprintf("%s:%s(%s)", subject, info.name, strings.join(args, ", ", context.temp_allocator)), info.name != ""
}

// args_lua writes a condition's parameters: forms by name, an actor value by its name, and no
// trailing zeros (a left-out parameter is 0).
@(private)
args_lua :: proc(src: ^Source, c: gamedb.Condition, info: esm.Condition_Function) -> ([]string, bool) {
	args := make([dynamic]string, context.temp_allocator)
	for kind, i in info.params {
		p := c.param1 if i == 0 else c.param2
		av := av_name(i32(p))
		switch kind {
		case .None:
		case .String: return nil, false
		case .Number: append(&args, fmt.tprintf("%q", av) if strings.contains(info.name, "ActorValue") && av != "" else fmt.tprint(i32(p)))
		case .Form, .Ref: append(&args, fmt.tprintf("%q", form_name(src, Form_ID(p))) if p != 0 else "0")
		}
	}
	for len(args) > 0 && args[len(args) - 1] == "0" {pop(&args)}
	return args[:], true
}

@(private)
Truth :: enum {Unclear, Yes, No}

// truth is what a comparison against a 0-or-1 answer asks for.
@(private)
truth :: proc(op: esm.Condition_Op, v: f32) -> Truth {
	holds := [2]bool{esm.condition_holds({op = op, value = v}, 0), esm.condition_holds({op = op, value = v}, 1)}
	switch holds {
	case {false, true}: return .Yes
	case {true, false}: return .No
	}
	return .Unclear
}
