package magictranslate

// Ability SPEL to rt.effect: a passive is one effect at the ability's form (user, 2026-09-29), so
// lists, AddSpell and HasSpell reach it as before, granted at m = 1. Conditions on the spell's
// entries are live: a gate script switches the effect each second.

import "core:fmt"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// Ability is an ability's translation: its effect file, and its gate script when it has one.
Ability :: struct {
	effect, gate, gate_class: string,
}

// Parts is what an ability's entries add up to as one effect.
@(private)
Parts :: struct {
	terms:   [dynamic]Term,
	scripts: [dynamic]esm.Script_Attach,
	tags:    [dynamic]string,
	start:   []gamedb.Condition, // the one part's MGEF conditions
	nostack: string,
	live:    []gamedb.Condition, // the entries' conditions, the same on each
}

// ability_lua translates an ability; false when its parts cannot merge into one effect.
ability_lua :: proc(src: ^Source, form: Form_ID, sp: gamedb.Spell) -> (out: Ability, ok: bool) {
	edid := src.edids[form]
	p := ability_parts(src, sp) or_return
	land := land_lua(src, p.start, nil) or_return
	if len(p.live) > 0 {
		out.gate_class = fmt.tprintf("%sGate", edid)
		out.gate = gate_script(src, form, out.gate_class, p.live) or_return
		append(&p.scripts, esm.Script_Attach{name = out.gate_class})
	}
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("SPEL %s, an ability", edid), "effect")
	write_tags(&b, p.tags[:])
	if p.nostack != "" {fmt.sbprintfln(&b, "  nostack = %q,", p.nostack)}
	write_terms(&b, merge_terms(p.terms[:]))
	strings.write_string(&b, land)
	write_scripts(&b, src, p.scripts[:])
	fmt.sbprintln(&b, "}")
	out.effect = strings.to_string(b)
	return out, true
}

// ability_parts merges an ability's entries: each numeric part's terms with its magnitude baked in,
// every part's scripts and keyword tags. False when a start gate or a live switch would cover only
// some parts, or two parts name different nostack groups.
@(private)
ability_parts :: proc(src: ^Source, sp: gamedb.Spell) -> (p: Parts, ok: bool) {
	if len(sp.effects) == 0 {return}
	p.terms = make([dynamic]Term, context.temp_allocator)
	p.scripts = make([dynamic]esm.Script_Attach, context.temp_allocator)
	p.tags = make([dynamic]string, context.temp_allocator)
	p.live = sp.effects[0].conditions
	for e in sp.effects {
		mgef := src.db.magic_effects[e.effect] or_else {}
		info := mgef.info
		if !same_conditions(e.conditions, p.live) {return}
		if len(mgef.conditions) > 0 && len(sp.effects) > 1 {return}
		#partial switch info.archetype {
		case .Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier, .Absorb:
			append(&p.terms, ..effect_terms(info, true, e.magnitude))
		case:
			if class := gamedb.archetype_class(info.archetype); class != "" {append(&p.scripts, esm.Script_Attach{name = class})}
		}
		append(&p.scripts, ..gamedb.form_scripts(&src.db, e.effect))
		for t in keyword_tags(src, e.effect) {
			if !slice.contains(p.tags[:], t) {append(&p.tags, t)}
		}
		if len(mgef.conditions) > 0 {p.start = mgef.conditions}
		if info.archetype == .Peak_Value_Modifier && mgef.related != 0 {
			group := gamedb.keyword_editor_id(&src.db, mgef.related)
			if p.nostack != "" && p.nostack != group {return}
			p.nostack = group
		}
	}
	return p, true
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
