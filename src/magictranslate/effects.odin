package magictranslate

// MGEF to rt.effect: the archetype's formula with the record's flags baked in, its form, keyword
// tags, resistance, stacking and scripts.

import "core:fmt"
import "core:strings"
import "../formats/esm"
import "../gamedb"

MGEF_NO_RECAST :: 0x0002_0000

// effect_lua writes an MGEF as an effects/ file; false for one this part does not translate.
effect_lua :: proc(src: ^Source, form: Form_ID, mgef: ^gamedb.Magic_Effect) -> (string, bool) {
	info := mgef.info
	#partial switch info.archetype {
	case .Value_Modifier, .Peak_Value_Modifier, .Dual_Value_Modifier, .Absorb:
	case: return "", false
	}
	if len(mgef.conditions) > 0 {return "", false}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "-- %s MGEF %s", src.files[u32(form >> 32)], src.edids[form])
	fmt.sbprintln(&b, "local rt = require('skymod.rt')")
	fmt.sbprintln(&b, "return rt.effect {")
	fmt.sbprintfln(&b, "  form = %q,", form_ref(src, form))
	if tags := effect_tags(src, form, info); len(tags) > 0 {
		fmt.sbprint(&b, "  tags = {")
		for t, i in tags {fmt.sbprintf(&b, "%s %q", "," if i > 0 else "", t)}
		fmt.sbprintln(&b, " },")
	}
	if av := av_name(info.resist_av); av != "" {fmt.sbprintfln(&b, "  resist = %q,", av)}
	if info.flags & MGEF_NO_RECAST != 0 {fmt.sbprintln(&b, "  stack = \"keep\",")}
	if info.archetype == .Peak_Value_Modifier && mgef.related != 0 {
		fmt.sbprintfln(&b, "  nostack = %q,", gamedb.keyword_editor_id(&src.db, mgef.related))
	}
	held := info.flags & esm.MGEF_RECOVER != 0 || src.lasting[form] == {.Lasting}
	if !held && info.taper_duration > 0 && info.taper_weight != 0 {fmt.sbprintfln(&b, "  taper = \"%vs\",", info.taper_duration)}
	write_terms(&b, effect_terms(info, held))
	write_scripts(&b, src, gamedb.form_scripts(&src.db, form))
	fmt.sbprintln(&b, "}")
	return strings.to_string(b), true
}

// effect_tags: `hostile` from the Hostile flag, and a kw.<editor id> per keyword.
@(private)
effect_tags :: proc(src: ^Source, form: Form_ID, info: esm.Magic_Effect_Info) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	if info.flags & esm.MGEF_HOSTILE != 0 {append(&out, "hostile")}
	for kw in src.db.keywords[form] {
		if edid := gamedb.keyword_editor_id(&src.db, kw); edid != "" {append(&out, fmt.tprintf("kw.%s", edid))}
	}
	return out[:]
}

// Term is one formula an effect writes: on the target's AV, or the caster's (Absorb's other half).
Term :: struct {
	av, knob, f: string,
	on_caster:   bool,
}

// effect_terms is what a numeric archetype moves. Held (Recover, or only lasting sources use it):
// the magnitude sits on the capacity while the effect runs. Otherwise m a second over d, or m at
// once when d is 0, then the taper, and the change stays (archetypevaluemodifier.lua).
effect_terms :: proc(info: esm.Magic_Effect_Info, held: bool) -> []Term {
	out := make([dynamic]Term, context.temp_allocator)
	primary, second := av_name(info.primary_av), av_name(info.second_av)
	knob := "capacity" if held else "amount"
	f := value_formula(info, held)
	neg := info.flags & esm.MGEF_DETRIMENTAL != 0
	switch {
	case primary == "":
	case info.archetype == .Absorb:
		if held {break} // an Absorb moves only amounts
		append(&out, Term{primary, "amount", signed(f, neg), false}, Term{primary, "amount", signed(f, !neg), true})
	case:
		append(&out, Term{primary, knob, signed(f, neg), false})
		if info.archetype == .Dual_Value_Modifier && second != "" {
			append(&out, Term{second, knob, signed(scale(f, info.second_av_weight), neg), false})
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

// value_formula is what a Value Modifier moves, before Detrimental's sign.
@(private)
value_formula :: proc(info: esm.Magic_Effect_Info, held: bool) -> string {
	if held {return "m"}
	f := "select(d, m * min(t, d), m)"
	if td := info.taper_duration; td > 0 && info.taper_weight != 0 {
		e := info.taper_curve + 1
		f = fmt.tprintf("%s + %s * (1 - (1 - clamp(t - d, 0, %v) / %v) ^ %v)", f, scale("m", info.taper_weight * td / e), td, td, e)
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
	return gamedb.AV_NAMES[i] if i >= 0 && int(i) < len(gamedb.AV_NAMES) else ""
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
