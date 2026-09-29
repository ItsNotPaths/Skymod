package magictranslate

// Ability SPEL to rt.effect: a passive is one effect at the ability's form (user, 2026-09-29), so
// lists, AddSpell and HasSpell reach it as before. Its entries merge: each numeric part's terms with
// its magnitude baked in (m = 1 as granted), every part's scripts, one start gate. Conditions on the
// spell's entries are live: a gate script switches the effect each second.

import "core:fmt"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"
import "../worldstate"

// Ability is an ability's translation: its effect file, and its gate script when it has one.
Ability :: struct {
	effect, gate, gate_class: string,
}

// ability_lua translates an ability; false when its parts cannot merge into one effect.
ability_lua :: proc(src: ^Source, form: Form_ID, sp: gamedb.Spell) -> (out: Ability, ok: bool) {
	edid := src.edids[form]
	terms := make([dynamic]Term, context.temp_allocator)
	scripts := make([dynamic]esm.Script_Attach, context.temp_allocator)
	tags := make([dynamic]string, context.temp_allocator)
	start: []gamedb.Condition
	nostack := ""
	for e in sp.effects {
		mgef := src.db.magic_effects[e.effect] or_else {}
		info := mgef.info
		#partial switch info.archetype {
		case .Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier, .Absorb:
			append(&terms, ..effect_terms(info, true, e.magnitude))
		case:
			if class := worldstate.archetype_class(info.archetype); class != "" {append(&scripts, esm.Script_Attach{name = class})}
		}
		append(&scripts, ..gamedb.form_scripts(&src.db, e.effect))
		for t in effect_tags(src, e.effect, info) {
			if t != "hostile" && !slice.contains(tags[:], t) {append(&tags, t)}
		}
		if len(mgef.conditions) > 0 {
			if len(sp.effects) > 1 {return} // one part's start gate cannot gate the whole
			start = mgef.conditions
		}
		if info.archetype == .Peak_Value_Modifier && mgef.related != 0 {
			group := gamedb.keyword_editor_id(&src.db, mgef.related)
			if nostack != "" && nostack != group {return}
			nostack = group
		}
	}
	if len(sp.effects) == 0 {return}
	live := sp.effects[0].conditions
	for e in sp.effects[1:] {
		if !same_conditions(e.conditions, live) {return} // one switch for the whole effect
	}
	land := land_lua(src, start, nil) or_return
	if len(live) > 0 {
		out.gate_class = fmt.tprintf("%sGate", edid)
		out.gate = gate_script(src, form, out.gate_class, live) or_return
		append(&scripts, esm.Script_Attach{name = out.gate_class})
	}

	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "-- %s SPEL %s, an ability", src.files[u32(form >> 32)], edid)
	fmt.sbprintln(&b, "local rt = require('skymod.rt')")
	fmt.sbprintln(&b, "return rt.effect {")
	fmt.sbprintfln(&b, "  form = %q,", form_ref(src, form))
	if len(tags) > 0 {
		fmt.sbprint(&b, "  tags = {")
		for t, i in tags {fmt.sbprintf(&b, "%s %q", "," if i > 0 else "", t)}
		fmt.sbprintln(&b, " },")
	}
	if nostack != "" {fmt.sbprintfln(&b, "  nostack = %q,", nostack)}
	write_terms(&b, merge_terms(terms[:]))
	strings.write_string(&b, land)
	write_scripts(&b, src, scripts[:])
	fmt.sbprintln(&b, "}")
	out.effect = strings.to_string(b)
	return out, true
}

// merge_terms sums the terms that move the same knob of the same AV on the same side.
@(private)
merge_terms :: proc(terms: []Term) -> []Term {
	out := make([dynamic]Term, context.temp_allocator)
	outer: for t in terms {
		for &o in out {
			if o.av == t.av && o.knob == t.knob && o.on_caster == t.on_caster {
				o.f = fmt.tprintf("%s + %s", o.f, t.f)
				continue outer
			}
		}
		append(&out, t)
	}
	return out[:]
}

// gate_script writes the script that switches an ability by its entries' conditions, each second.
@(private)
gate_script :: proc(src: ^Source, form: Form_ID, class: string, conds: []gamedb.Condition) -> (text: string, ok: bool) {
	gate := gate_lua(src, conds) or_return
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "-- %s SPEL %s: on while its conditions hold, checked each second.", src.files[u32(form >> 32)], src.edids[form])
	fmt.sbprintln(&b, "local rt = require('skymod.rt')")
	fmt.sbprintfln(&b, "local C = rt.class(%q, nil)", class)
	fmt.sbprintln(&b, "C.__vars = { TickRate = rt.float(1) }")
	fmt.sbprintln(&b, "C.__fn[\"ontick\"] = function(self)")
	fmt.sbprintln(&b, "  local e = { target = self:GetTargetActor(), caster = self:GetCasterActor(), global = rt.global }")
	gate, _ = strings.replace_all(gate, "\n      ", "\n    ", context.temp_allocator)
	fmt.sbprintfln(&b, "  self:SetActive(%s)", gate)
	fmt.sbprintln(&b, "end")
	fmt.sbprintln(&b, "return C")
	return strings.to_string(b), true
}

@(private)
same_conditions :: proc(a, b: []gamedb.Condition) -> bool {
	if len(a) != len(b) {return false}
	for x, i in a {
		y := b[i]
		if x.function != y.function || x.op != y.op || x.flags != y.flags || x.value != y.value || x.global != y.global || x.param1 != y.param1 || x.param2 != y.param2 || x.run_on != y.run_on || x.reference != y.reference {return false}
	}
	return true
}
