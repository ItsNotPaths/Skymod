package magictranslate

// MGEF conditions to Lua: the land gate. In an MGEF's conditions the subject is the one hit and the
// target is the caster (edges.md 3), so Subject reads e.target and Target e.caster. An Is/Has
// function answers a boolean in Lua, the rest a number (rt.odin __condition).

import "core:fmt"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// land_lua writes the land function: false from it when the conditions fail, then each dispel
// (DispelTagged); "" for none. ok=false when a condition has no Lua form.
land_lua :: proc(src: ^Source, conds: []gamedb.Condition, dispels: []string) -> (text: string, ok: bool) {
	if len(conds) == 0 && len(dispels) == 0 {return "", true}
	gate := gate_lua(src, conds) or_return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(&b, "  land = function(e)")
	switch {
	case len(dispels) == 0: fmt.sbprintfln(&b, "    return %s", gate)
	case len(conds) > 0:    fmt.sbprintfln(&b, "    if not (%s) then return false end", gate)
	}
	for d in dispels {fmt.sbprintfln(&b, "    e.target:DispelTagged(%q)", d)}
	fmt.sbprintln(&b, "  end,")
	return strings.to_string(b), true
}

// gate_lua writes a condition list as one Lua test: an AND of OR runs, one run a line.
@(private)
gate_lua :: proc(src: ^Source, conds: []gamedb.Condition) -> (text: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	group := make([dynamic]string, context.temp_allocator)
	first := true
	for c, i in conds {
		test := condition_lua(src, c) or_return
		append(&group, test)
		if .Or in c.flags && i < len(conds) - 1 {continue}
		term := strings.join(group[:], " or ", context.temp_allocator)
		if len(group) > 1 && len(conds) > len(group) {term = fmt.tprintf("(%s)", term)}
		fmt.sbprintf(&b, "%s%s", "" if first else "\n      and ", term)
		clear(&group)
		first = false
	}
	return strings.to_string(b), true
}

// condition_lua writes one condition as a Lua test.
@(private)
condition_lua :: proc(src: ^Source, c: gamedb.Condition) -> (string, bool) {
	if .Swap in c.flags || .Use_Aliases in c.flags || .Use_Pack_Data in c.flags {return "", false}
	subject: string
	#partial switch c.run_on {
	case .Subject:   subject = "e.target"
	case .Target:    subject = "e.caster"
	case .Reference: subject = fmt.tprintf("rt.ref(%q)", form_name(src, c.reference))
	case:            return "", false
	}
	info := esm.condition_function(c.function)
	if info.name == "" {return "", false}
	args := make([dynamic]string, context.temp_allocator)
	for kind, i in info.params {
		p := c.param1 if i == 0 else c.param2
		switch kind {
		case .None:
		case .String: return "", false
		case .Number:
			av := av_name(i32(p))
			append(&args, fmt.tprintf("%q", av) if strings.contains(info.name, "ActorValue") && av != "" else fmt.tprint(i32(p)))
		case .Form, .Ref:
			if p != 0 {append(&args, fmt.tprintf("%q", form_name(src, Form_ID(p))))}
		}
	}
	for len(args) > 0 && args[len(args) - 1] == "0" {pop(&args)} // a left-out parameter is 0
	call := fmt.tprintf("%s:%s(%s)", subject, info.name, strings.join(args[:], ", ", context.temp_allocator))
	value := fmt.tprintf("e.global.%s", src.edids[c.global]) if .Use_Global in c.flags else fmt.tprint(c.value)
	if strings.has_prefix(info.name, "Is") || strings.has_prefix(info.name, "Has") {
		if .Use_Global in c.flags {return "", false}
		switch truth(c.op, c.value) {
		case .Yes: return call, true
		case .No:  return fmt.tprintf("not %s", call), true
		case .Unclear: return "", false
		}
	}
	OPS := [esm.Condition_Op]string{.Equal = "==", .NotEqual = "~=", .Greater = ">", .GreaterOrEqual = ">=", .Less = "<", .LessOrEqual = "<="}
	return fmt.tprintf("%s %s %s", call, OPS[c.op], value), true
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
