package main

// --shapes: per closure function, where its latent sites sit on the CFG and which clock
// shape (docs/script-rewrite.md "Evaluation and clocks") could replace them mechanically.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../../src/formats/pex"

Shape :: enum {None, Transitive, Poll, Single, Seq_Const, Seq_Other, Non_Timer} // worst body wins

SHAPE_NAMES := [Shape]string {
	.None       = "-",
	.Transitive = "transitive",
	.Poll       = "poll",
	.Single     = "single",
	.Seq_Const  = "seq_const",
	.Seq_Other  = "seq_other",
	.Non_Timer  = "non_timer",
}

// Why a Wait-only body is seq_other.
Why :: enum {None, Callee, Loop_Plus, Poll_No_Exit, Branchy, Computed}

WHY_NAMES := [Why]string {
	.None         = "-",
	.Callee       = "callee",
	.Loop_Plus    = "loop_plus",
	.Poll_No_Exit = "loop_no_exit_test",
	.Branchy      = "branchy",
	.Computed     = "computed_dur",
}

Dur :: enum {None, Lit, Member, Computed} // worst wins

DUR_NAMES := [Dur]string{.None = "-", .Lit = "lit", .Member = "member", .Computed = "computed"}

Site_Kind :: enum {None, Wait, Native, Callee}

Shape_Row :: struct {
	script:              string,
	states, calls:       [dynamic]string,
	carried:             [dynamic]string, // "name:type"
	shape:               Shape,
	why:                 Why,
	dur:                 Dur,
	direct:              bool,
	max_path, max_plain: int, // latent sites on one path (a loop runs once) / not counting loop sites
	min_plain:           int, // fewest non-loop sites on a path, over bodies with sites
	sites, sites_loop:   int,
	nat_max, nat_loop:   int, // latent natives only (the old survey's population)
	nat_plain:           int,
	gotostate, result:   bool,
	multi_state:         bool,
	callers:             int,
}

shapes_object :: proc(c: ^Corpus, p: ^pex.Pex, o: ^pex.Object) {
	class := strings.to_lower(o.name, context.temp_allocator)
	syms := object_syms(o, class)
	named := 0
	for &st in o.states {if st.name != "" {named += 1}}
	multi := named > 1 || (named == 1 && o.auto_state == "")
	for &st in o.states {
		for &f in st.functions {shape_body(c, o, class, syms, &f, st.name, multi)}
	}
	for &pr in o.properties {
		if pr.has_reader {shape_body(c, o, class, syms, &pr.reader, "", multi)}
		if pr.has_writer {shape_body(c, o, class, syms, &pr.writer, "", multi)}
	}
}

shape_body :: proc(c: ^Corpus, o: ^pex.Object, class: string, syms: map[string]string, f: ^pex.Function, state: string, multi: bool) {
	n := len(f.instructions)
	if f.is_native || n == 0 {return}
	fn := strings.to_lower(f.name, context.temp_allocator)
	ni, ok := c.index[fmt.tprintf("%s.%s", class, fn if fn != "" else "<prop>")]
	if !ok {return}
	if c.effects != nil {body_effects(c, &Walk{o = o, f = f, syms = syms}, ni)}
	if !c.nodes[ni].latent {return}
	r := &c.shapes[ni]
	if r.script == "" {r.script = strings.clone(o.name)}
	r.multi_state = multi
	append(&r.states, strings.clone(state if state != "" else "-"))

	w := Walk{o, f, syms, build_preds(f), make([]bool, n, context.temp_allocator), make([]bool, n, context.temp_allocator), nil}
	loops := find_loops(f)
	kind := make([]Site_Kind, n, context.temp_allocator)
	sites := make([dynamic]int, context.temp_allocator)
	dur := Dur.None
	for ins, idx in f.instructions {
		if ins.op == .CallMethod && len(ins.args) > 0 && strings.equal_fold(ins.args[0].str, "gotostate") {r.gotostate = true}
		raw, is_call := call_raw(&w, ins)
		if !is_call {continue}
		leaf := resolve_leaf(c, raw)
		if name, nat := latent_native(leaf); nat {
			kind[idx] = .Native
			if strings.has_prefix(strings.to_lower(name, context.temp_allocator), "utility.wait") {
				kind[idx] = .Wait
				slice.zero(w.done)
				dur = max(dur, dur_kind(&w, ins.args[3], idx) if len(ins.args) > 3 else .Computed)
			}
			add_unique(&r.calls, name)
		} else if is_latent_leaf(c, leaf) {
			kind[idx] = .Callee
			add_unique(&r.calls, leaf[len("script:"):])
		} else {
			continue
		}
		append(&sites, idx)
	}
	if len(sites) == 0 {return}
	r.dur = max(r.dur, dur)

	all_w := make([]bool, n, context.temp_allocator)
	plain_w := make([]bool, n, context.temp_allocator)
	nat_w := make([]bool, n, context.temp_allocator)
	nat_plain_w := make([]bool, n, context.temp_allocator)
	loop_sites, nat_loop := 0, 0
	has := [Site_Kind]bool{}
	for s in sites {
		looped := in_any_loop(loops[:], s)
		nat := kind[s] != .Callee
		all_w[s], plain_w[s], nat_w[s], nat_plain_w[s] = true, !looped, nat, nat && !looped
		if looped {loop_sites += 1}
		if looped && nat {nat_loop += 1}
		has[kind[s]] = true
	}
	max_path, _ := path_waits(f, all_w)
	max_plain, min_plain := path_waits(f, plain_w)
	nat_max, _ := path_waits(f, nat_w)
	nat_plain, _ := path_waits(f, nat_plain_w)
	min_plain_prev := r.min_plain if r.sites > 0 else max(int)
	r.max_path = max(r.max_path, max_path)
	r.max_plain = max(r.max_plain, max_plain)
	r.min_plain = min(min_plain_prev, min_plain)
	r.nat_max = max(r.nat_max, nat_max)
	r.nat_plain = max(r.nat_plain, nat_plain)
	r.nat_loop += nat_loop
	r.sites += len(sites)
	r.sites_loop += loop_sites
	r.direct = r.direct || has[.Wait] || has[.Native]

	for s in sites {
		if d := dest_arg(f.instructions[s].op); !strings.equal_fold(f.instructions[s].args[d].str, "::nonevar") && live_after(f, s, f.instructions[s].args[d].str) {
			r.result = true
		}
		carried_at(&w, s, &r.carried)
		if c.effects != nil && kind[s] == .Callee {record_site(c, &w, ni, state, s, kind, in_any_loop(loops[:], s), len(sites) == 1)}
	}

	shape, why := Shape.Transitive, Why.None
	switch {
	case has[.Native]:
		shape = .Non_Timer
	case !has[.Wait]:
		shape = .Transitive
	case has[.Callee]:
		shape, why = .Seq_Other, .Callee
	case loop_sites == len(sites):
		shape, why = poll_shape(f, loops[:], sites[:], max_path)
	case loop_sites > 0:
		shape, why = .Seq_Other, .Loop_Plus
	case max_path == 1:
		shape = .Single
	case !every_path(f, sites[:]):
		shape, why = .Seq_Other, .Branchy
	case dur == .Computed:
		shape, why = .Seq_Other, .Computed
	case:
		shape = .Seq_Const
	}
	if shape > r.shape {r.shape, r.why = shape, why}
}

add_unique :: proc(list: ^[dynamic]string, s: string) {
	for x in list {if x == s {return}}
	append(list, strings.clone(s))
}

in_any_loop :: proc(loops: []Loop, i: int) -> bool {
	for l in loops {if l.lo <= i && i <= l.hi {return true}}
	return false
}

// latent_native: the latent native a resolved call leaf names; untyped receivers match by name like count_site.
latent_native :: proc(leaf: string) -> (string, bool) {
	if strings.has_prefix(leaf, "latent:") {return leaf[len("latent:"):], true}
	if !strings.has_prefix(leaf, "unresolved:") {return "", false}
	key := leaf[len("unresolved:"):]
	if slice.contains(pex.LATENT_GLOBALS, key) {return key, true}
	if strings.has_prefix(key, "?.") && is_latent_method_name(key[2:]) {return key, true}
	return "", false
}

// poll_shape: all sites in one loop, at most one per pass, and a test in the loop that leaves it.
poll_shape :: proc(f: ^pex.Function, loops: []Loop, sites: []int, max_path: int) -> (Shape, Why) {
	if max_path > 1 {return .Seq_Other, .Loop_Plus}
	outer: for l in loops {
		for s in sites {if s < l.lo || s > l.hi {continue outer}}
		for idx in l.lo ..= l.hi {
			op := f.instructions[idx].op
			if op != .JmpT && op != .JmpF {continue}
			if t, ok := jump_target(f.instructions[idx], idx); ok && (t < l.lo || t > l.hi) {return .Poll, .None}
		}
	}
	return .Seq_Other, .Poll_No_Exit
}

// dag_succs: back edges fall through, so a loop body runs once; len(instructions) is the exit.
dag_succs :: proc(f: ^pex.Function, idx: int) -> [2]int {
	n := len(f.instructions)
	ins := f.instructions[idx]
	if ins.op == .Return {return {n, -1}}
	out := [2]int{-1, -1}
	if ins.op != .Jmp {out[0] = idx + 1}
	if t, ok := jump_target(ins, idx); ok {out[1] = clamp(t, 0, n) if t > idx else idx + 1}
	return out
}

// path_waits: most and fewest weighted instructions on one entry-to-exit path.
path_waits :: proc(f: ^pex.Function, weight: []bool) -> (hi, lo: int) {
	n := len(f.instructions)
	best := make([]int, n + 1, context.temp_allocator)
	low := make([]int, n + 1, context.temp_allocator)
	slice.fill(best, -1)
	slice.fill(low, max(int))
	best[0], low[0] = 0, 0
	for idx in 0 ..< n {
		if best[idx] < 0 {continue}
		wt := int(weight[idx])
		for t in dag_succs(f, idx) {
			if t < 0 {continue}
			best[t] = max(best[t], best[idx] + wt)
			low[t] = min(low[t], low[idx] + wt)
		}
	}
	if best[n] < 0 {return 0, 0}
	return best[n], low[n]
}

dag_reach :: proc(f: ^pex.Function, from, avoid: int) -> []bool {
	seen := make([]bool, len(f.instructions) + 1, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, from)
	for len(stack) > 0 {
		i := pop(&stack)
		if i < 0 || i == avoid || seen[i] {continue}
		seen[i] = true
		if i < len(f.instructions) {
			succ := dag_succs(f, i)
			append(&stack, ..succ[:])
		}
	}
	return seen
}

// every_path: no path runs one wait but skips another, so the waits form one fixed chain.
every_path :: proc(f: ^pex.Function, sites: []int) -> bool {
	exit := len(f.instructions)
	for s in sites {
		from := dag_reach(f, 0, s)
		for t in sites {
			if t != s && from[t] && dag_reach(f, t, s)[exit] {return false}
		}
	}
	return true
}

// dur_kind: literal; a local whose every reaching def is a literal; or a member never written here.
dur_kind :: proc(w: ^Walk, v: pex.Value, at: int) -> Dur {
	#partial switch v.kind {
	case .Float, .Integer:
		return .Lit
	case .Identifier:
	case:
		return .Computed
	}
	if !is_fn_var(w.f, v.str) {return .Computed if member_written(w.f, v.str) else .Member}
	defs := reaching_defs(w, v.str, at)
	if len(defs) == 0 {return .Computed}
	worst := Dur.None
	for d in defs {
		ins := w.f.instructions[d]
		if ins.op != .Assign && ins.op != .Cast {return .Computed}
		if w.done[d] {continue}
		w.done[d] = true
		worst = max(worst, dur_kind(w, ins.args[1], d))
	}
	return worst
}

member_written :: proc(f: ^pex.Function, name: string) -> bool {
	prop := name[2:len(name) - 4] if strings.has_prefix(name, "::") && strings.has_suffix(name, "_var") else name
	for ins in f.instructions {
		if d := dest_arg(ins.op); d >= 0 && d < len(ins.args) && strings.equal_fold(ins.args[d].str, name) {return true}
		if ins.op == .PropSet && is_self(ins.args[1]) && strings.equal_fold(ins.args[0].str, prop) {return true}
	}
	return false
}

// reads_var: `name` is an operand read by `ins` (call/prop name slots and the dest are not reads).
reads_var :: proc(ins: pex.Instruction, name: string) -> bool {
	dest := dest_arg(ins.op)
	for i in first_operand(ins.op) ..< len(ins.args) {
		a := ins.args[i]
		if i != dest && a.kind == .Identifier && strings.equal_fold(a.str, name) {return true}
	}
	return false
}

// first_operand: args before it name a call target or property, not a value.
first_operand :: proc(op: pex.Opcode) -> int {
	#partial switch op {
	case .CallMethod, .CallParent, .PropGet, .PropSet:
		return 1
	case .CallStatic:
		return 2
	}
	return 0
}

// push_succs: full-CFG successors, back edges kept.
push_succs :: proc(stack: ^[dynamic]int, f: ^pex.Function, i: int) {
	ins := f.instructions[i]
	if ins.op == .Return {return}
	if ins.op != .Jmp {append(stack, i + 1)}
	if t, ok := jump_target(ins, i); ok {append(stack, t)}
}

// live_after: some path from `at` reads `name` before writing it (full CFG, back edges kept).
live_after :: proc(f: ^pex.Function, at: int, name: string) -> bool {
	n := len(f.instructions)
	seen := make([]bool, n, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	push_succs(&stack, f, at)
	for len(stack) > 0 {
		i := pop(&stack)
		if i < 0 || i >= n || seen[i] {continue}
		seen[i] = true
		ins := f.instructions[i]
		if reads_var(ins, name) {return true}
		if d := dest_arg(ins.op); d >= 0 && d < len(ins.args) && strings.equal_fold(ins.args[d].str, name) {continue}
		push_succs(&stack, f, i)
	}
	return false
}

// carried_at: params/locals with a def reaching the site that is read after it.
carried_at :: proc(w: ^Walk, s: int, out: ^[dynamic]string) {
	ins := w.f.instructions[s]
	dest := ins.args[dest_arg(ins.op)].str
	check :: proc(w: ^Walk, s: int, dest: string, v: pex.Var, param: bool, out: ^[dynamic]string) {
		if strings.equal_fold(v.name, "::nonevar") || strings.equal_fold(v.name, dest) {return}
		if !live_after(w.f, s, v.name) {return}
		if !param && len(reaching_defs(w, v.name, s)) == 0 {return}
		add_unique(out, fmt.tprintf("%s:%s", v.name, strings.to_lower(v.type_name, context.temp_allocator)))
	}
	for v in w.f.params {check(w, s, dest, v, true, out)}
	for v in w.f.locals {check(w, s, dest, v, false, out)}
}

// ── output ───────────────────────────────────────────────────────────────────

count_callers :: proc(c: ^Corpus) {
	for &n, i in c.nodes {
		if !n.latent {continue}
		seen := make(map[int]bool, context.temp_allocator)
		for e in n.edges {
			if e == i || e in seen || !c.nodes[e].latent {continue}
			seen[e] = true
			c.shapes[e].callers += 1
		}
	}
	free_all(context.temp_allocator)
}

max_path_str :: proc(r: ^Shape_Row) -> string {
	if r.sites_loop == 0 {return fmt.tprintf("%d", r.max_plain)}
	if r.max_plain == 0 {return "loop"}
	return fmt.tprintf("%d+loop", r.max_plain)
}

write_shapes_tsv :: proc(c: ^Corpus, path: string) {
	count_callers(c)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "script\tfunction\tstate\tdirect\tshape\twhy\tnatives\tcallers\tmax_waits_path\tmin_waits_path\tin_loop\tconst_dur\tcarried\tcarried_types\tgotostate\tuses_result\n")
	join :: proc(l: [dynamic]string, sep: string) -> string {
		return strings.join(l[:], sep, context.temp_allocator) if len(l) > 0 else "-"
	}
	for &n, i in c.nodes {
		if !n.latent {continue}
		r := &c.shapes[i]
		fmt.sbprintf(&b, "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%d\t%d/%d\t%s\t%d\t%s\t%d\t%d\n",
			r.script, n.fn, join(r.states, ","), "direct" if r.direct else "transitive", SHAPE_NAMES[r.shape], WHY_NAMES[r.why],
			join(r.calls, ","), r.callers, max_path_str(r), r.min_plain, r.sites_loop, r.sites - r.sites_loop,
			DUR_NAMES[r.dur], len(r.carried), join(r.carried, ","), int(r.gotostate), int(r.result))
		free_all(context.temp_allocator)
	}
	if err := os.write_entire_file(path, b.buf[:]); err != nil {
		fmt.eprintfln("failed to write %s: %v", path, err)
	}
}

shape_report :: proc(c: ^Corpus) {
	pct :: proc(n, d: int) -> f64 {return 100.0 * f64(n) / f64(max(d, 1))}
	Tally :: struct {n, callers, c0, c12, c3, cond, lit_only: int}
	tally: [Shape]Tally
	whys: [Why]int
	total, mismatch, no_sites := 0, 0, 0
	one, loop_only, seq, loop_seq, two_plus, two_multi, two_goto, direct, exactly_two, two_plain := 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
	for &n, i in c.nodes {
		if !n.latent {continue}
		r := &c.shapes[i]
		total += 1
		if r.direct != (n.direct_sites > 0) {mismatch += 1}
		if r.sites == 0 {no_sites += 1}
		shape := r.shape if r.shape != .None else .Transitive
		t := &tally[shape]
		t.n += 1
		if r.callers > 0 {t.callers += 1}
		switch len(r.carried) {
		case 0:
			t.c0 += 1
		case 1, 2:
			t.c12 += 1
		case:
			t.c3 += 1
		}
		if r.min_plain == 0 {t.cond += 1}
		if r.dur == .Lit {t.lit_only += 1}
		whys[r.why] += 1

		if !r.direct {continue}
		direct += 1
		plain := r.nat_plain > 0
		switch {
		case r.nat_loop == 0 && r.nat_max == 1:
			one += 1
		case r.nat_loop > 0 && !plain:
			loop_only += 1
		case r.nat_loop == 0:
			seq += 1
		case:
			loop_seq += 1
		}
		if r.nat_plain >= 2 {two_plain += 1}
		if r.nat_max >= 2 {
			two_plus += 1
			if r.nat_max == 2 {exactly_two += 1}
			if r.multi_state {two_multi += 1}
			if r.gotostate {two_goto += 1}
		}
	}

	fmt.println()
	fmt.printfln("SHAPES (optimistic closure: %d functions; direct/transitive mismatch vs count_site: %d; no latent site found: %d)", total, mismatch, no_sites)
	fmt.printfln("  %-11s %6s %7s  %9s  %6s %6s %6s  %10s  %7s", "shape", "n", "%", "callers>0", "carry0", "1-2", "3+", "some-path0", "lit-dur")
	for s in Shape {
		if s == .None {continue}
		t := tally[s]
		fmt.printfln("  %-11s % 6d % 6.1f%%  % 9d  % 6d % 6d % 6d  % 10d  % 7d", SHAPE_NAMES[s], t.n, pct(t.n, total), t.callers, t.c0, t.c12, t.c3, t.cond, t.lit_only)
	}
	fmt.println("  seq_other reasons:")
	for w in Why {if w != .None {fmt.printfln("    %-18s % 6d", WHY_NAMES[w], whys[w])}}
	fmt.println("  const_dur rule: literal, a local whose every reaching def is a literal, or a member/autoprop never written in the function (\"member\")")
	fmt.println()
	fmt.printfln("WAIT SHAPE, latent natives only, over %d functions with a direct call (old survey: 8-name seed, .psc):", direct)
	fmt.printfln("  one wait on any path:        % 6d (%.0f%%)", one, pct(one, direct))
	fmt.printfln("  waits only inside a loop:    % 6d (%.0f%%)", loop_only, pct(loop_only, direct))
	fmt.printfln("  multiple sequential, no loop:% 6d (%.0f%%)", seq, pct(seq, direct))
	fmt.printfln("  loop + sequential:           % 6d (%.0f%%)", loop_seq, pct(loop_seq, direct))
	fmt.printfln("  2+ on one path (loop = 1):   % 6d  (exactly two %d, multi-state script %d, calls GoToState %d)", two_plus, exactly_two, two_multi, two_goto)
	fmt.printfln("  2+ outside loops on one path:% 6d", two_plain)
}
