package main

// --callers: per call to a closure function, what follows it in the caller. Decides whether the
// caller still works once the callee sets a fact and returns early (mydocs/script-rewrite.md
// "What the API must answer" item 1).
//
// State keys: "m:<declaring class>.<member or property>" and "n:<class>.<family>" for natives.
// A callee writes what its body and every function it reaches (resolved edges) write.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../../src/formats/pex"

Effects :: struct {
	reads, writes: [dynamic]string,
	calls:         [dynamic]int, // script nodes called
}

Call_Class :: enum {Tail, Tail_Value, After_Indep, After_Dep, After_Wait}

CALL_CLASS_NAMES := [Call_Class]string {
	.Tail        = "tail",
	.Tail_Value  = "tail_value",
	.After_Indep = "after_indep",
	.After_Dep   = "after_dep",
	.After_Wait  = "after_wait",
}

Call_Site :: struct {
	caller, callee:  int,
	state:           string,
	idx, line:       int,
	only, in_loop:   bool,
	result, effect:  bool, // result read later / an effectful instruction follows
	wait, wait_nat:  bool, // a latent site follows / one of them is a latent native
	after:           Effects,
	class:           Call_Class,
	dep, waw:        string, // first read / write after that meets a callee write
	war:             string, // first write after that the callee or the caller itself reads (order or lock)
}

// verb prefixes dropped to get a native's family: SetStage and GetStageDone share "stage".
NATIVE_VERBS :: []string{"get", "set", "is", "has", "add", "remove", "mod", "force", "damage", "restore", "clear", "reset", "equip", "unequip"}

native_family :: proc(fn: string) -> string {
	switch fn {
	case "enable", "disable", "isdisabled":
		return "enabled"
	case "start", "stop", "isrunning", "isstarting", "isstopping", "isstopped":
		return "running"
	case "moveto", "translateto":
		return "position"
	}
	for v in NATIVE_VERBS {
		if strings.has_prefix(fn, v) && len(fn) > len(v) {return fn[len(v):]}
	}
	return fn
}

// member_key: `name` read or written on an object of class `cls`, at its declaring class.
member_key :: proc(c: ^Corpus, cls, name: string) -> string {
	name := strings.to_lower(name, context.temp_allocator)
	if strings.has_prefix(name, "::") && strings.has_suffix(name, "_var") {name = name[2:len(name) - 4]}
	cls := resolve_class(c, cls)
	for k, ok := cls, true; ok; k, ok = c.parents[k] {
		if fmt.tprintf("%s.%s", k, name) in c.guards.types {return fmt.tprintf("m:%s.%s", k, name)}
	}
	return fmt.tprintf("m:%s.%s", cls, name)
}

own_class :: proc(w: ^Walk) -> string {return strings.to_lower(w.o.name, context.temp_allocator)}

// is_member: a member variable or autoprop backer; ::temp and ::nonevar are compiler locals.
is_member :: proc(w: ^Walk, v: pex.Value) -> bool {
	if v.kind != .Identifier || is_self(v) || is_fn_var(w.f, v.str) {return false}
	return !strings.has_prefix(v.str, "::") || strings.has_suffix(strings.to_lower(v.str, context.temp_allocator), "_var")
}

// instr_effects adds what `ins` reads and writes to `e`; effect is false for pure local work and read natives.
instr_effects :: proc(c: ^Corpus, w: ^Walk, ins: pex.Instruction, e: ^Effects) -> (effect: bool) {
	#partial switch ins.op {
	case .CallStatic, .CallMethod, .CallParent:
		raw, _ := call_raw(w, ins)
		effect = call_effects(c, w, ins, resolve_leaf(c, raw), e)
	case .PropGet, .PropSet:
		cls := own_class(w) if is_self(ins.args[1]) else receiver_type(w, ins.args[1])
		key := member_key(c, cls, ins.args[0].str)
		if ins.op == .PropSet {
			add_unique(&e.writes, key)
			effect = true
		} else {
			add_unique(&e.reads, key)
		}
	case .ArraySetElement:
		if is_member(w, ins.args[0]) {add_unique(&e.writes, member_key(c, own_class(w), ins.args[0].str))}
		effect = true
	}
	dest := dest_arg(ins.op)
	for a, i in ins.args {
		if i < first_operand(ins.op) {continue}
		if !is_member(w, a) {continue}
		add_unique(&e.writes if i == dest else &e.reads, member_key(c, own_class(w), a.str))
		if i == dest {effect = true}
	}
	return
}

call_effects :: proc(c: ^Corpus, w: ^Walk, ins: pex.Instruction, leaf: string, e: ^Effects) -> bool {
	colon := strings.index_byte(leaf, ':')
	kind, name := leaf[:colon], strings.to_lower(leaf[colon + 1:], context.temp_allocator)
	switch kind {
	case "script":
		if i, ok := c.index[name]; ok {append(&e.calls, i)}
		return true
	case "native", "latent":
	case:
		return true // unresolved
	}
	recv := own_class(w) if ins.op != .CallMethod || is_self(ins.args[1]) else receiver_type(w, ins.args[1])
	switch name {
	case "scriptobject.gotostate":
		add_unique(&e.writes, member_key(c, recv, "<state>"))
		return true
	case "scriptobject.getstate":
		add_unique(&e.reads, member_key(c, recv, "<state>"))
		return false
	}
	if strings.has_prefix(name, "utility.wait") {return true} // no state, the wait itself
	if strings.has_prefix(name, "debug.trace") {return false} // writes only the log
	dot := strings.index_byte(name, '.')
	key := fmt.tprintf("n:%s.%s", name[:dot], native_family(name[dot + 1:]))
	row, known := c.guards.natives[name]
	if row.effect == "read" || row.effect == "both" {add_unique(&e.reads, key)}
	if row.effect == "write" || row.effect == "both" {add_unique(&e.writes, key)}
	return kind == "latent" || !known || row.effect != "read"
}

body_effects :: proc(c: ^Corpus, w: ^Walk, ni: int) {
	for ins in w.f.instructions {_ = instr_effects(c, w, ins, &c.effects[ni])}
}

record_site :: proc(c: ^Corpus, w: ^Walk, ni: int, state: string, s: int, kind: []Site_Kind, in_loop, only: bool) {
	f := w.f
	ins := f.instructions[s]
	leaf := resolve_leaf(c, call_raw(w, ins) or_else "")
	cs := Call_Site {
		caller  = ni,
		callee  = c.index[strings.to_lower(leaf[len("script:"):], context.temp_allocator)],
		state   = strings.clone(state if state != "" else "-"),
		idx     = s,
		line    = int(ins.line),
		only    = only,
		in_loop = in_loop,
	}
	dest := ins.args[dest_arg(ins.op)].str
	cs.result = !strings.equal_fold(dest, "::nonevar") && live_after(f, s, dest)

	seen := make([]bool, len(f.instructions), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	push_succs(&stack, f, s)
	for len(stack) > 0 {
		i := pop(&stack)
		if i < 0 || i >= len(f.instructions) || seen[i] {continue}
		seen[i] = true
		if kind[i] != .None {cs.wait = true}
		if kind[i] == .Wait || kind[i] == .Native {cs.wait_nat = true}
		if instr_effects(c, w, f.instructions[i], &cs.after) {cs.effect = true}
		push_succs(&stack, f, i)
	}
	append(&c.call_sites, cs)
}

// reach_effects: union of body effects over every node reachable from `roots`.
reach_effects :: proc(c: ^Corpus, roots: []int) -> (out: Effects) {
	out.reads = make([dynamic]string, context.temp_allocator)
	out.writes = make([dynamic]string, context.temp_allocator)
	seen := make([]bool, len(c.nodes), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, ..roots)
	for len(stack) > 0 {
		i := pop(&stack)
		if seen[i] {continue}
		seen[i] = true
		e := &c.effects[i]
		for k in e.reads {if !slice.contains(out.reads[:], k) {append(&out.reads, k)}}
		for k in e.writes {if !slice.contains(out.writes[:], k) {append(&out.writes, k)}}
		append(&stack, ..c.nodes[i].edges[:])
		append(&stack, ..e.calls[:])
	}
	return
}

related :: proc(c: ^Corpus, a, b: string) -> bool {
	for k, ok := a, true; ok; k, ok = c.parents[k] {if k == b {return true}}
	for k, ok := b, true; ok; k, ok = c.parents[k] {if k == a {return true}}
	return false
}

// key_hits: same member; or natives on related classes whose families share a prefix.
key_hits :: proc(c: ^Corpus, a, b: string) -> bool {
	if a[0] != b[0] {return false}
	if a[0] == 'm' {return a == b && !strings.has_prefix(a, "m:?.")}
	da, db := strings.index_byte(a, '.'), strings.index_byte(b, '.')
	fa, fb := a[da + 1:], b[db + 1:]
	return related(c, a[2:da], b[2:db]) && (strings.has_prefix(fa, fb) || strings.has_prefix(fb, fa))
}

first_hit :: proc(c: ^Corpus, keys, writes: []string) -> string {
	for k in keys {
		for w in writes {if key_hits(c, k, w) {return k}}
	}
	return ""
}

classify_sites :: proc(c: ^Corpus) {
	for &cs in c.call_sites {
		callee := reach_effects(c, {cs.callee})
		later := reach_effects(c, cs.after.calls[:])
		reads := slice.concatenate([][]string{cs.after.reads[:], later.reads[:]}, context.temp_allocator)
		writes := slice.concatenate([][]string{cs.after.writes[:], later.writes[:]}, context.temp_allocator)
		cs.dep = strings.clone(first_hit(c, reads, callee.writes[:]))
		cs.waw = strings.clone(first_hit(c, writes, callee.writes[:]))
		dispatch := member_key(c, c.nodes[cs.caller].class, "<state>") // event dispatch reads the caller's state
		readers := slice.concatenate([][]string{callee.reads[:], c.effects[cs.caller].reads[:], {dispatch}}, context.temp_allocator)
		cs.war = strings.clone(first_hit(c, writes, readers))
		dep := cs.result || cs.dep != ""
		switch {
		case cs.wait:
			cs.class = .After_Wait
		case !cs.effect:
			cs.class = .Tail_Value if dep else .Tail
		case dep:
			cs.class = .After_Dep
		case:
			cs.class = .After_Indep
		}
		free_all(context.temp_allocator)
	}
}

// ── output ───────────────────────────────────────────────────────────────────

write_callers_tsv :: proc(c: ^Corpus, path: string) {
	classify_sites(c)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "script\tfunction\tstate\tidx\tline\tcallee\tclass\tonly_site\tin_loop\tuses_result\twaits_after\tdep\twaw\twar\tcaller_shape\tcallee_shape\n")
	dash :: proc(s: string) -> string {return s if s != "" else "-"}
	for &cs in c.call_sites {
		r, e := &c.shapes[cs.caller], &c.shapes[cs.callee]
		fmt.sbprintf(&b, "%s\t%s\t%s\t%d\t%d\t%s.%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
			r.script, c.nodes[cs.caller].fn, cs.state, cs.idx, cs.line, e.script, c.nodes[cs.callee].fn,
			CALL_CLASS_NAMES[cs.class], int(cs.only), int(cs.in_loop), int(cs.result), "native" if cs.wait_nat else "calls" if cs.wait else "-", dash(cs.dep), dash(cs.waw), dash(cs.war),
			SHAPE_NAMES[r.shape], SHAPE_NAMES[e.shape])
	}
	if err := os.write_entire_file(path, b.buf[:]); err != nil {
		fmt.eprintfln("failed to write %s: %v", path, err)
	}
}

callers_report :: proc(c: ^Corpus) {
	pct :: proc(n, d: int) -> f64 {return 100.0 * f64(n) / f64(max(d, 1))}
	// Ok levels: loose = tail/tail_value/after_indep; no_value drops tail_value; no_order drops later writes that meet callee state.
	Level :: enum {Loose, No_Value, No_Order}
	site_ok :: proc(cs: ^Call_Site, l: Level) -> bool {
		switch l {
		case .Loose:
			return cs.class == .Tail || cs.class == .Tail_Value || cs.class == .After_Indep
		case .No_Value:
			return cs.class == .Tail || cs.class == .After_Indep
		case .No_Order:
			return site_ok(cs, .Loose) && cs.waw == "" && cs.war == ""
		}
		return false
	}

	by_class: [Call_Class]int
	only, loop_wait, waw_indep, war_indep, wait_calls := 0, 0, 0, 0, 0
	caller_bad, callee_bad: [Level][]bool
	for l in Level {
		caller_bad[l] = make([]bool, len(c.nodes), context.temp_allocator)
		callee_bad[l] = make([]bool, len(c.nodes), context.temp_allocator)
	}
	has_site := make([]bool, len(c.nodes), context.temp_allocator)
	Callee_Tally :: struct {callers: map[int]bool, by: [Call_Class]int}
	callees := make(map[int]Callee_Tally, context.temp_allocator)
	for &cs in c.call_sites {
		by_class[cs.class] += 1
		if cs.only {only += 1}
		if cs.in_loop && cs.class == .After_Wait {loop_wait += 1}
		if cs.class == .After_Indep && cs.waw != "" {waw_indep += 1}
		if cs.class == .After_Indep && cs.war != "" {war_indep += 1}
		if cs.class == .After_Wait && !cs.wait_nat && !cs.result && cs.dep == "" {wait_calls += 1}
		has_site[cs.caller] = true
		for l in Level {
			caller_bad[l][cs.caller] |= !site_ok(&cs, l)
			callee_bad[l][cs.callee] |= !site_ok(&cs, l)
		}
		t := callees[cs.callee] or_else Callee_Tally{callers = make(map[int]bool, context.temp_allocator)}
		t.callers[cs.caller] = true
		t.by[cs.class] += 1
		callees[cs.callee] = t
	}
	total := len(c.call_sites)

	fmt.println()
	fmt.printfln("CALLERS (%d call sites to a closure function):", total)
	for k in Call_Class {fmt.printfln("  %-12s % 6d (%.1f%%)", CALL_CLASS_NAMES[k], by_class[k], pct(by_class[k], total))}
	fmt.printfln("  only latent site in its body: %d (%.1f%%)", only, pct(only, total))
	fmt.printfln("  after_wait inside a loop: %d", loop_wait)
	fmt.printfln("  after_wait where only closure calls follow and nothing reads callee state: %d", wait_calls)
	fmt.printfln("  after_indep with a later write to state the callee writes (waw): %d", waw_indep)
	fmt.printfln("  after_indep with a later write to state the callee or the caller reads (war: lock, flag): %d", war_indep)

	trans, no_site, split, split_no_site, frag: int
	free, frag_free, split_ok: [Level]int
	for &n, i in c.nodes {
		if !n.latent {continue}
		r := &c.shapes[i]
		if r.shape == .Transitive {
			trans += 1
			if !has_site[i] {no_site += 1}
			if is_fragment(n.class) {frag += 1}
			for l in Level {
				if !has_site[i] || caller_bad[l][i] {continue}
				free[l] += 1
				if is_fragment(n.class) {frag_free[l] += 1}
			}
		}
		if (r.shape == .Poll || r.shape == .Single || r.shape == .Seq_Const) && r.callers > 0 {
			split += 1
			if i not_in callees {split_no_site += 1;continue}
			for l in Level {if !callee_bad[l][i] {split_ok[l] += 1}}
			r.callers_free = !callee_bad[.No_Order][i] && !callee_bad[.No_Value][i] // and no caller uses the result
		}
	}
	fmt.printfln("  levels: loose = tail/tail_value/after_indep, no_value = without tail_value, no_order = loose without waw/war")
	fmt.printfln("  transitive functions: %d (no callee site found: %d); free loose %d (%.1f%%), no_value %d, no_order %d (%.1f%%)",
		trans, no_site, free[.Loose], pct(free[.Loose], trans), free[.No_Value], free[.No_Order], pct(free[.No_Order], trans))
	fmt.printfln("    quest fragments (qf_/tif_/sf_): %d (%.1f%% of transitive); free loose %d (%.1f%%), no_order %d (%.1f%%)",
		frag, pct(frag, trans), frag_free[.Loose], pct(frag_free[.Loose], frag), frag_free[.No_Order], pct(frag_free[.No_Order], frag))
	fmt.printfln("  poll/single/seq_const with closure callers: %d (no call site found: %d); every caller site ok: loose %d, no_value %d, no_order %d",
		split, split_no_site, split_ok[.Loose], split_ok[.No_Value], split_ok[.No_Order])

	fmt.println("  top 20 callees by distinct callers:")
	fmt.printfln("    %-56s %7s %6s %6s %6s %6s %6s %6s", "callee", "callers", "sites", "tail", "t_val", "indep", "dep", "wait")
	Pair :: struct {k, v: int}
	prs := make([dynamic]Pair, context.temp_allocator)
	for k, t in callees {append(&prs, Pair{k, len(t.callers)})}
	slice.sort_by(prs[:], proc(a, b: Pair) -> bool {return a.v > b.v || (a.v == b.v && a.k < b.k)})
	for p, i in prs {
		if i >= 20 {break}
		t := callees[p.k]
		sites := 0
		for v in t.by {sites += v}
		fmt.printfln("    %-56s % 7d % 6d % 6d % 6d % 6d % 6d % 6d", c.nodes[p.k].key, p.v, sites,
			t.by[.Tail], t.by[.Tail_Value], t.by[.After_Indep], t.by[.After_Dep], t.by[.After_Wait])
	}
	fmt.println("  approximation: callee writes = members/properties assigned (declaring class, instance ignored) + write natives,")
	fmt.println("  over its body and every function it reaches; reads after = the same over the rest of the caller and the script")
	fmt.println("  functions it calls there. Natives match on related classes when families (name minus a verb prefix) share a prefix.")
	free_all(context.temp_allocator)
}
