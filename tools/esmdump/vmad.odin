package main

// --vmad: survey every VMAD field in a plugin through the real decoder (src/formats/esm,
// records_scripts.odin). A raw walk, not a gamedb build, so it also covers the record types
// the database does not index yet (INFO, SCEN, PACK).
//
// This is the step-4 survey from docs/records.md: the totals here are what a layout change has
// to keep matching, and `failed` must stay 0 on every plugin.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../../src/formats/esm"

Vmad_Tally :: struct {
	records:       int,
	scripts:       int,
	props:         int,
	fragments:     int,
	aliases:       int,
	alias_scripts: int,
	removed:       int, // attachments marking an inherited script removed (status 3)
	failed:        int,
}

Vmad_Survey :: struct {
	by_type:    map[string]Vmad_Tally,
	kinds:      map[esm.Prop_Kind]int,
	names:      map[string]int, // lower-cased script name -> attachments
	alias_hist: map[i16]int,    // object-property alias index -> count (which values mean "no alias")
	samples:    [dynamic]string,
	interned:   map[string]string,
}

vmad_survey :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("could not read %s", path)
		os.exit(1)
	}
	defer delete(data)

	s: Vmad_Survey
	defer vmad_survey_destroy(&s)
	esm.walk(data, vmad_visit, &s)

	types := make([dynamic]string, context.temp_allocator)
	for k in s.by_type {append(&types, k)}
	slice.sort_by(types[:], proc(a, b: string) -> bool {return a < b})

	fmt.printfln("VMAD survey — %s", path)
	fmt.println("type   records  scripts    props  frags aliases alias_scr removed failed")
	total: Vmad_Tally
	for t in types {
		v := s.by_type[t]
		fmt.printfln(
			"%-6s %7d %8d %8d %6d %7d %9d %7d %6d",
			t, v.records, v.scripts, v.props, v.fragments, v.aliases, v.alias_scripts, v.removed, v.failed,
		)
		total.records += v.records;total.scripts += v.scripts;total.props += v.props
		total.fragments += v.fragments;total.aliases += v.aliases
		total.alias_scripts += v.alias_scripts;total.removed += v.removed;total.failed += v.failed
	}
	fmt.printfln(
		"%-6s %7d %8d %8d %6d %7d %9d %7d %6d",
		"TOTAL", total.records, total.scripts, total.props, total.fragments,
		total.aliases, total.alias_scripts, total.removed, total.failed,
	)

	fmt.printfln("\ndistinct script names: %d", len(s.names))
	// -1 is "names a form directly"; anything >= 0 resolves through that quest alias.
	none, aliased, max_alias := 0, 0, i16(-1)
	for k, n in s.alias_hist {
		if k < 0 {
			none += n
			continue
		}
		aliased += n
		max_alias = max(max_alias, k)
	}
	fmt.printfln(
		"object properties: %d name a form, %d resolve through a quest alias (highest id %d)",
		none, aliased, max_alias,
	)
	fmt.println("property kinds:")
	kinds := make([dynamic]esm.Prop_Kind, context.temp_allocator)
	for k in s.kinds {append(&kinds, k)}
	slice.sort(kinds[:])
	for k in kinds {
		fmt.printfln("  %-13v %8d", k, s.kinds[k])
	}

	fmt.println("\nsamples:")
	for line in s.samples {
		fmt.println(" ", line)
	}
	if total.failed > 0 {
		fmt.eprintfln("FAILED to decode %d VMAD fields", total.failed)
		os.exit(1)
	}
}

// --vmad-names: every script name the plugin attaches (form, alias and fragment scripts), lower
// case, one per line, sorted and unique. Removed attachments (status 3) are left out.
vmad_names :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("could not read %s", path)
		os.exit(1)
	}
	defer delete(data)

	s: Vmad_Survey
	defer vmad_survey_destroy(&s)
	esm.walk(data, vmad_names_visit, &s)

	names := make([dynamic]string, context.temp_allocator)
	for k in s.names {append(&names, k)}
	slice.sort(names[:])
	for n in names {fmt.println(n)}
}

@(private = "file")
vmad_names_visit :: proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
	s := (^Vmad_Survey)(user)
	fl, backing, fok := esm.fields(rec, context.temp_allocator)
	if !fok {return true}
	defer delete(backing, context.temp_allocator)
	if _, has := esm.find_field(fl, "VMAD"); !has {return true}
	fs, ok := esm.decode_vmad(rec.type, fl)
	if !ok {return true}
	defer esm.free_form_scripts(fs)

	add :: proc(s: ^Vmad_Survey, name: string) {
		if name != "" {s.names[vmad_keep(s, strings.to_lower(name, context.temp_allocator))] += 1}
	}
	for a in fs.scripts {if !esm.script_attach_removed(a) {add(s, a.name)}}
	for al in fs.aliases {for a in al.scripts {if !esm.script_attach_removed(a) {add(s, a.name)}}}
	add(s, fs.frag_file)
	for fr in fs.fragments {add(s, fr.script)}
	return true
}

// --vmad-props: every number property value, one "script<TAB>property<TAB>value" line per
// attachment (form and alias scripts), names lower case.
vmad_props :: proc(path: string) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("could not read %s", path)
		os.exit(1)
	}
	defer delete(data)
	esm.walk(data, vmad_props_visit, nil)
}

@(private = "file")
vmad_props_visit :: proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
	fl, backing, fok := esm.fields(rec, context.temp_allocator)
	if !fok {return true}
	defer delete(backing, context.temp_allocator)
	if _, has := esm.find_field(fl, "VMAD"); !has {return true}
	fs, ok := esm.decode_vmad(rec.type, fl)
	if !ok {return true}
	defer esm.free_form_scripts(fs)

	print :: proc(list: []esm.Script_Attach) {
		for a in list {
			for p in a.props {
				name := strings.to_lower(a.name, context.temp_allocator)
				prop := strings.to_lower(p.name, context.temp_allocator)
				#partial switch v in p.value {
				case i32: fmt.printfln("%s\t%s\t%v", name, prop, v)
				case f32: fmt.printfln("%s\t%s\t%v", name, prop, v)
				}
			}
		}
	}
	print(fs.scripts)
	for al in fs.aliases {print(al.scripts)}
	return true
}

@(private = "file")
vmad_visit :: proc(rec: esm.Record, ctx: esm.Walk_Context, user: rawptr) -> bool {
	s := (^Vmad_Survey)(user)
	fl, backing, fok := esm.fields(rec, context.temp_allocator)
	if !fok {
		return true
	}
	defer delete(backing, context.temp_allocator)
	if _, has := esm.find_field(fl, "VMAD"); !has {
		return true
	}

	t := s.by_type[vmad_keep(s, rec.type)]
	t.records += 1
	defer s.by_type[vmad_keep(s, rec.type)] = t

	fs, ok := esm.decode_vmad(rec.type, fl)
	if !ok {
		t.failed += 1
		fmt.eprintfln("  decode failed: %s %08X", rec.type, rec.form_id)
		return true
	}
	defer esm.free_form_scripts(fs)

	t.fragments += len(fs.fragments)
	t.aliases += len(fs.aliases)
	for a in fs.aliases {
		t.alias_scripts += len(a.scripts)
	}
	vmad_count(s, &t, fs.scripts)
	for a in fs.aliases {
		vmad_count(s, &t, a.scripts)
	}

	if len(s.samples) < 12 && len(fs.scripts) > 0 && len(fs.scripts[0].props) > 0 {
		vmad_sample(s, rec, fs)
	}
	return true
}

@(private = "file")
vmad_count :: proc(s: ^Vmad_Survey, t: ^Vmad_Tally, list: []esm.Script_Attach) {
	for a in list {
		t.scripts += 1
		if esm.script_attach_removed(a) {
			t.removed += 1
		}
		s.names[vmad_keep(s, strings.to_lower(a.name, context.temp_allocator))] += 1
		for p in a.props {
			t.props += 1
			s.kinds[p.kind] += 1
			if obj, is_obj := p.value.(esm.Prop_Object); is_obj {
				s.alias_hist[obj.alias] += 1
			}
		}
	}
}

// One readable line per sampled record: what it carries, and its first few property names with
// the kind each decoded to.
@(private = "file")
vmad_sample :: proc(s: ^Vmad_Survey, rec: esm.Record, fs: esm.Form_Scripts) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s %08X  %s", rec.type, rec.form_id, fs.scripts[0].name)
	if fs.frag_file != "" {
		fmt.sbprintf(&b, "  frag=%s(%d)", fs.frag_file, len(fs.fragments))
	}
	if len(fs.aliases) > 0 {
		fmt.sbprintf(&b, "  aliases=%d", len(fs.aliases))
	}
	fmt.sbprint(&b, "  [")
	for p, i in fs.scripts[0].props {
		if i >= 4 {
			fmt.sbprint(&b, " …")
			break
		}
		fmt.sbprintf(&b, "%s%s:%v", i > 0 ? " " : "", p.name, p.kind)
	}
	fmt.sbprint(&b, "]")
	append(&s.samples, strings.clone(strings.to_string(b)))
}

// Map keys must outlive the temp arena and the plugin buffer they are views into.
@(private = "file")
vmad_keep :: proc(s: ^Vmad_Survey, k: string) -> string {
	if v, ok := s.interned[k]; ok {
		return v
	}
	c := strings.clone(k)
	s.interned[c] = c
	return c
}

@(private = "file")
vmad_survey_destroy :: proc(s: ^Vmad_Survey) {
	for line in s.samples {delete(line)}
	delete(s.samples)
	for k in s.interned {delete(k)}
	delete(s.interned)
	delete(s.by_type)
	delete(s.kinds)
	delete(s.names)
	delete(s.alias_hist)
}
