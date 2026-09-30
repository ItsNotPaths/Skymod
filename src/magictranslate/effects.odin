package magictranslate

// MGEF to rt.effect: the archetype's formula with the record's flags baked in, its form, keyword
// tags, resistance, stacking and scripts.

import "core:fmt"
import "core:reflect"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// effect_lua writes an MGEF as an effects/ file; false when one of its conditions has no Lua form.
// With `entry` it is a copy for a spell entry with those conditions: a Lua form, the entry's
// conditions in its start gate.
effect_lua :: proc(src: ^Source, form: Form_ID, mgef: ^gamedb.Magic_Effect, entry: []gamedb.Condition = nil) -> (text: string, ok: bool) {
	info := mgef.info
	status, is_status := status_of(info.archetype)
	gates := make([dynamic]string, context.temp_allocator)
	if g := archetype_gate(info.archetype); g != "" {append(&gates, g)}
	if len(entry) > 0 {
		g := gate_lua(src, entry, MGEF_WHO, "\n        and ") or_return
		append(&gates, fmt.tprintf("(%s)", g) if strings.contains(g, " or ") else g)
	}
	land := land_lua(src, mgef.conditions, dispels(src, form, info), strings.join(gates[:], "\n        and ", context.temp_allocator)) or_return
	b := strings.builder_make(context.temp_allocator)
	write_head(&b, src, form, fmt.tprintf("MGEF %s", src.edids[form]), "effect", entry == nil)
	write_tags(&b, effect_tags(src, form, info)[:])
	if av := av_name(info.resist_av); av != "" {fmt.sbprintfln(&b, "  resist = %q,", av)}
	if info.flags & esm.MGEF_NO_RECAST != 0 {fmt.sbprintln(&b, "  stack = \"keep\",")}
	if info.archetype == .Peak_Value_Modifier && mgef.related != 0 {
		fmt.sbprintfln(&b, "  nostack = %q,", gamedb.keyword_editor_id(&src.db, mgef.related))
	}
	if info.taper_duration > 0 {fmt.sbprintfln(&b, "  taper = \"%vs\",", info.taper_duration)}
	scripts := make([dynamic]esm.Script_Attach, context.temp_allocator)
	#partial switch info.archetype {
	case .Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier, .Absorb, .Enhance_Weapon, .Accumulate_Magnitude:
		held := info.flags & esm.MGEF_RECOVER != 0 || src.lasting[form] == {.Lasting}
		write_terms(&b, effect_terms(info, held))
	case:
		if is_status {write_terms(&b, {{status.av, "capacity", status.f, false}})}
		if class := gamedb.archetype_class(info.archetype); class != "" {append(&scripts, archetype_script(class, info.archetype, mgef.related))}
	}
	strings.write_string(&b, land)
	append(&scripts, ..gamedb.form_scripts(&src.db, form))
	write_scripts(&b, src, scripts[:])
	fmt.sbprintln(&b, "}")
	return strings.to_string(b), true
}

// Status is what a status archetype holds on its target's AV while it runs.
Status :: struct {
	av, f: string,
}

// status_of: calm and frenzy move Aggression past its range (below 0 is calmed, combat.odin), fear
// and rally Confidence; paralysis and invisibility set their AV.
@(private)
status_of :: proc(a: esm.Effect_Archetype) -> (Status, bool) {
	#partial switch a {
	case .Calm:         return {"Aggression", "-3"}, true
	case .Frenzy:       return {"Aggression", "3"}, true
	case .Demoralize:   return {"Confidence", "-4"}, true
	case .Turn_Undead:  return {"Confidence", "-4"}, true
	case .Rally:        return {"Confidence", "4"}, true
	case .Paralysis:    return {"Paralysis", "1"}, true
	case .Invisibility: return {"Invisibility", "1"}, true
	}
	return {}, false
}

// archetype_gate is the test an archetype adds to its effect's start: the magnitude is the highest
// level it reaches (CK), or an immunity keyword.
@(private)
archetype_gate :: proc(a: esm.Effect_Archetype) -> string {
	#partial switch a {
	case .Calm, .Frenzy, .Demoralize, .Turn_Undead, .Rally, .Reanimate, .Command_Summoned, .Banish:
		return "e.target.av.Level.value <= e.m.value"
	case .Paralysis:
		return "not e.target:HasKeyword(\"ImmuneParalysis\")"
	}
	return ""
}

// archetype_script is an archetype's class with the MGEF's associated item as its property: the
// actor a summon places, the bound weapon, the spell a cloak casts.
@(private)
archetype_script :: proc(class: string, a: esm.Effect_Archetype, related: Form_ID) -> esm.Script_Attach {
	s := esm.Script_Attach{name = class}
	name: string
	#partial switch a {
	case .Summon_Creature: name = "Summon"
	case .Bound_Weapon:    name = "Weapon"
	case .Cloak:           name = "Spell"
	}
	if name != "" && related != 0 {
		props := make([]esm.Script_Prop, 1, context.temp_allocator)
		props[0] = {name = name, kind = .Object, status = 1, value = esm.Prop_Object{form = related, alias = -1}}
		s.props = props
	}
	return s
}

// dispels are the tags a Dispel With Keywords effect clears as it lands: its keywords.
@(private)
dispels :: proc(src: ^Source, form: Form_ID, info: esm.Magic_Effect_Info) -> []string {
	if info.flags & esm.MGEF_DISPEL_WITH_KEYWORDS == 0 {return nil}
	return keyword_tags(src, form)[:]
}

// effect_tags are an effect's tags: hostile, then what it is (its archetype, school, tier, element,
// poison, disease, status, restore, summon, power.duration), then a kw.<editor id> per keyword.
@(private)
effect_tags :: proc(src: ^Source, form: Form_ID, info: esm.Magic_Effect_Info) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	uses := src.lasting[form]
	hostile := info.flags & esm.MGEF_HOSTILE != 0
	if hostile {append(&out, "hostile")}
	append(&out, archetype_tag(info.archetype))
	switch s := av_name(info.magic_skill); s {
	case "Alteration", "Conjuration", "Destruction", "Illusion", "Restoration":
		append(&out, fmt.tprintf("school.%s", strings.to_lower(s, context.temp_allocator)))
		TIERS := [?]string{"novice", "apprentice", "adept", "expert", "master"}
		append(&out, fmt.tprintf("tier.%s", TIERS[min(info.skill_level / 25, 4)]))
	}
	kws := keyword_tags(src, form)
	switch {
	case av_name(info.resist_av) == "FireResist" || slice.contains(kws[:], "kw.MagicDamageFire"):     append(&out, "magic.fire")
	case av_name(info.resist_av) == "FrostResist" || slice.contains(kws[:], "kw.MagicDamageFrost"):   append(&out, "magic.frost")
	case av_name(info.resist_av) == "ElectricResist" || slice.contains(kws[:], "kw.MagicDamageShock"): append(&out, "magic.shock")
	}
	if .Poison in uses {append(&out, "poison")}
	if .Disease in uses {append(&out, "disease")}
	if hostile && .Long in uses {append(&out, "status")}
	#partial switch info.archetype {
	case .Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier:
		switch av_name(info.primary_av) {
		case "Health", "Magicka", "Stamina": if !hostile && info.flags & (esm.MGEF_DETRIMENTAL | esm.MGEF_RECOVER) == 0 {append(&out, "restore")}
		}
	case .Summon_Creature, .Reanimate:
		append(&out, "summon")
	}
	if info.flags & (esm.MGEF_POWER_AFFECTS_DURATION | esm.MGEF_POWER_AFFECTS_MAGNITUDE) == esm.MGEF_POWER_AFFECTS_DURATION {append(&out, "power.duration")}
	append(&out, ..kws[:])
	return out
}

// archetype_tag names the record archetype an effect came from (archetype.calm), so one hook reaches
// every effect of it.
@(private)
archetype_tag :: proc(a: esm.Effect_Archetype) -> string {
	name, _ := reflect.enum_name_from_value(a)
	return fmt.tprintf("archetype.%s", strings.to_lower(name, context.temp_allocator))
}

// keyword_tags is a kw.<editor id> tag per keyword of `form`.
@(private)
keyword_tags :: proc(src: ^Source, form: Form_ID) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for kw in src.db.keywords[form] {
		if edid := gamedb.keyword_editor_id(&src.db, kw); edid != "" {append(&out, fmt.tprintf("kw.%s", edid))}
	}
	return out
}

// write_head opens a definition file: the record it came from, then `return rt.<call> {` and its
// form, unless it is a Lua form.
@(private)
write_head :: proc(b: ^strings.Builder, src: ^Source, form: Form_ID, what, call: string, with_form := true) {
	fmt.sbprintfln(b, "-- %s %s", src.files[u32(form >> 32)], what)
	fmt.sbprintln(b, "local rt = require('skymod.rt')")
	fmt.sbprintfln(b, "return rt.%s {{", call)
	if with_form {fmt.sbprintfln(b, "  form = %q,", form_ref(src, form))}
}

@(private)
write_tags :: proc(b: ^strings.Builder, tags: []string) {
	if len(tags) == 0 {return}
	fmt.sbprint(b, "  tags = {")
	for t, i in tags {fmt.sbprintf(b, "%s %q", "," if i > 0 else "", t)}
	fmt.sbprintln(b, " },")
}

// Term is one formula an effect writes: on the target's AV, or the caster's (Absorb's other half).
Term :: struct {
	av, knob, f: string,
	on_caster:   bool,
}

// effect_terms is what a numeric archetype moves, k times its magnitude. Held (Recover, or only
// lasting sources use it): the magnitude sits on the capacity while the effect runs. Otherwise m a
// second over d, or m at once when d is 0, then the taper, and the change stays
// (archetypevaluemodifier.lua).
effect_terms :: proc(info: esm.Magic_Effect_Info, held: bool, k: f32 = 1) -> []Term {
	out := make([dynamic]Term, context.temp_allocator)
	primary, second := av_name(info.primary_av), av_name(info.second_av)
	knob := "capacity" if held else "amount"
	neg := info.flags & esm.MGEF_DETRIMENTAL != 0
	f := value_formula(info, held, k)
	switch {
	case primary == "" || k == 0:
	case info.archetype == .Absorb:
		if held {break} // an Absorb moves only amounts
		append(&out, Term{primary, "amount", signed(f, neg), false}, Term{primary, "amount", signed(f, !neg), true})
	case:
		append(&out, Term{primary, knob, signed(f, neg), false})
		if info.archetype == .Dual_Value_Modifier && second != "" {
			append(&out, Term{second, knob, signed(value_formula(info, held, k * info.second_av_weight), neg), false})
		}
	}
	return out[:]
}

@(private)
write_terms :: proc(b: ^strings.Builder, terms: []Term) {
	for side in ([]bool{false, true}) {
		first := true
		for t in terms {
			if t.on_caster != side {continue}
			open := ", " if !first else "  caster = { " if side else "  av = { "
			fmt.sbprintf(b, "%s%s = {{ %s = %q }", open, t.av, t.knob, t.f)
			first = false
		}
		if !first {fmt.sbprintln(b, " },")}
	}
}

// value_formula is what a Value Modifier moves, k times its magnitude, before Detrimental's sign.
@(private)
value_formula :: proc(info: esm.Magic_Effect_Info, held: bool, k: f32) -> string {
	if held {return scale("m", k)}
	f := scale("select(d, m * min(t, d), m)", k)
	if td := info.taper_duration; td > 0 && info.taper_weight != 0 {
		e := info.taper_curve + 1
		f = fmt.tprintf("%s + %s * (1 - (1 - clamp(t - d, 0, %v) / %v) ^ %v)", f, scale("m", k * info.taper_weight * td / e), td, td, e)
	}
	return f
}

@(private)
signed :: proc(f: string, neg: bool) -> string {
	if !neg {return f}
	return fmt.tprintf("-(%s)", f) if strings.contains(f, " + ") else fmt.tprintf("-%s", f)
}

@(private)
scale :: proc(f: string, k: f32) -> string {
	if k == 1 {return f}
	return fmt.tprintf("%v * (%s)", k, f) if strings.contains(f, " + ") else fmt.tprintf("%v * %s", k, f)
}

@(private)
av_name :: proc(i: i32) -> string {
	return esm.AV_NAMES[i] if i >= 0 && int(i) < len(esm.AV_NAMES) else ""
}

// write_scripts writes an effect's VMAD scripts as its moment scripts and their properties.
@(private)
write_scripts :: proc(b: ^strings.Builder, src: ^Source, scripts: []esm.Script_Attach) {
	kept := make([dynamic]esm.Script_Attach, context.temp_allocator)
	for s in scripts {if s.status != 3 {append(&kept, s)}}
	switch len(kept) {
	case 0:
	case 1:
		fmt.sbprint(b, "  script = ")
		write_script(b, src, kept[0], "  ")
		fmt.sbprintln(b, ",")
	case:
		fmt.sbprintln(b, "  script = {")
		for s in kept {
			fmt.sbprint(b, "    ")
			write_script(b, src, s, "    ")
			fmt.sbprintln(b, ",")
		}
		fmt.sbprintln(b, "  },")
	}
}

// write_script writes one script: its name, or a table of its name and properties.
@(private)
write_script :: proc(b: ^strings.Builder, src: ^Source, s: esm.Script_Attach, indent: string) {
	props := make([dynamic]string, context.temp_allocator)
	for p in s.props {
		if v := prop_lua(src, p.value); p.status != 3 && v != "" {append(&props, fmt.tprintf("%s = %s", p.name, v))}
	}
	if len(props) == 0 {
		fmt.sbprintf(b, "%q", s.name)
		return
	}
	fmt.sbprintfln(b, "{{ %q,", s.name)
	for p in props {fmt.sbprintfln(b, "%s  %s,", indent, p)}
	fmt.sbprintf(b, "%s}", indent)
}

// prop_lua writes a property value; "" for a form that is none.
@(private)
prop_lua :: proc(src: ^Source, v: esm.Prop_Value) -> string {
	switch x in v {
	case esm.Prop_Object: return fmt.tprintf("rt.ref(%q)", form_ref(src, x.form)) if x.form != 0 else ""
	case string:          return fmt.tprintf("%q", x)
	case i32:             return fmt.tprint(x)
	case f32:             return fmt.tprintf("%v", x) if x != f32(i32(x)) else fmt.tprintf("%v.0", i32(x))
	case bool:            return fmt.tprint(x)
	case []esm.Prop_Object: return list_lua(src, x)
	case []string:        return list_lua(src, x)
	case []i32:           return list_lua(src, x)
	case []f32:           return list_lua(src, x)
	case []bool:          return list_lua(src, x)
	}
	return ""
}

@(private)
list_lua :: proc(src: ^Source, xs: []$T) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	for x, i in xs {
		v := prop_lua(src, x)
		fmt.sbprintf(&b, "%s %s", "," if i > 0 else "", v if v != "" else "false")
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}
