package main

// --guards: what the if/while conditions read. One JmpT/JmpF = one guard; its condition
// operand is walked back through reaching definitions to leaves.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "../../src/formats/pex"
import "../../src/script"

NATIVES_TSV :: "docs/natives-classified.tsv"

Guards :: struct {
	on:      bool,
	fns:     map[string]string, // "class.fn" lower -> leaf ("native:"/"latent:"/"script:" + declared casing)
	props:   map[string]string, // "class.prop" lower -> "Class.Prop"
	types:   map[string]string, // "class.var" lower -> type lower (members + properties, for inherited receivers)
	natives: map[string]Native_Row,
	list:    [dynamic]Guard_Fn,
}

Guard_Fn :: struct {
	node:              int,
	script, fn, state: string,
	loops:             []Loop,
	preds:             [][]int,       // CFG predecessors per instruction
	sites:             [dynamic]Site, // every call; raw until resolve_guards
	guards:            [dynamic]Guard,
}

Site :: struct {
	idx: int,
	raw: string,
}

Guard :: struct {
	idx, target, line:           int,
	leaves:                      [dynamic]string, // "call:cls.fn" / "pget:cls.prop" are raw until resolve_guards
	loop_cond, poll, after_wait: bool,
}

collect_decls :: proc(c: ^Corpus, o: ^pex.Object) {
	g := &c.guards
	for &st in o.states {
		for &f in st.functions {
			key := lower_key(o.name, f.name)
			if key in g.fns {continue}
			kind, name := "script", fmt.tprintf("%s.%s", o.name, f.name)
			if strings.equal_fold(f.name, "GetState") || strings.equal_fold(f.name, "GotoState") {
				kind, name = "native", "ScriptObject.GetState" if strings.equal_fold(f.name, "GetState") else "ScriptObject.GotoState"
			} else if f.is_native {
				kind = "latent" if pex.is_latent(o.name, f.name) else "native"
				if row, ok := g.natives[key]; ok {name = row.name}
			}
			g.fns[strings.clone(key)] = fmt.aprintf("%s:%s", kind, name)
		}
	}
	for &pr in o.properties {
		key := lower_key(o.name, pr.name)
		if key in g.props {continue}
		g.props[strings.clone(key)] = fmt.aprintf("%s.%s", o.name, pr.name)
		g.types[strings.clone(key)] = strings.to_lower(pr.type_name)
	}
	for &v in o.variables {
		key := lower_key(o.name, v.name)
		if key not_in g.types {g.types[strings.clone(key)] = strings.to_lower(v.type_name)}
	}
}

lower_key :: proc(class, name: string) -> string {
	return strings.to_lower(fmt.tprintf("%s.%s", class, name), context.temp_allocator)
}

// ── scan ─────────────────────────────────────────────────────────────────────

Walk :: struct {
	o:      ^pex.Object,
	f:      ^pex.Function,
	syms:   map[string]string,
	preds:  [][dynamic]int,
	done:   []bool, // defs already expanded for this guard
	seen:   []bool, // reaching-def search scratch
	leaves: ^[dynamic]string,
}

scan_guards :: proc(c: ^Corpus, o: ^pex.Object, syms: map[string]string, f: ^pex.Function, node: int, state: string, loops: []Loop) {
	n := len(f.instructions)
	if !slice.any_of_proc(f.instructions, proc(ins: pex.Instruction) -> bool {return ins.op == .JmpT || ins.op == .JmpF}) {return}

	preds := build_preds(f)
	w := Walk{o, f, syms, preds, make([]bool, n, context.temp_allocator), make([]bool, n, context.temp_allocator), nil}

	// The compiler writes one line per instruction; a partial table belongs to another body.
	lines_ok := slice.all_of_proc(f.instructions, proc(i: pex.Instruction) -> bool {return i.line > 0}) ||
	            slice.all_of_proc(f.instructions, proc(i: pex.Instruction) -> bool {return i.line == 0})
	gf := Guard_Fn{node = node, script = strings.clone(o.name), fn = strings.clone(f.name if f.name != "" else "<prop>"), state = strings.clone(state), loops = slice.clone(loops)}
	gf.preds = make([][]int, n)
	for p, i in preds {gf.preds[i] = slice.clone(p[:])}
	for ins, idx in f.instructions {
		#partial switch ins.op {
		case .CallStatic, .CallMethod, .CallParent:
			if raw, ok := call_raw(&w, ins); ok {append(&gf.sites, Site{idx, strings.clone(raw)})}
		case .JmpT, .JmpF:
			if len(ins.args) < 2 {continue}
			g := Guard{idx = idx, line = int(ins.line) if lines_ok else 0}
			g.target, _ = jump_target(ins, idx)
			slice.zero(w.done)
			w.leaves = &g.leaves
			walk_value(&w, ins.args[0], idx)
			append(&gf.guards, g)
		}
	}
	append(&c.guards.list, gf)
}

build_preds :: proc(f: ^pex.Function) -> [][dynamic]int {
	n := len(f.instructions)
	preds := make([][dynamic]int, n, context.temp_allocator)
	for ins, idx in f.instructions {
		if t, ok := jump_target(ins, idx); ok && t >= 0 && t < n {append(&preds[t], idx)}
		if idx + 1 < n && ins.op != .Jmp && ins.op != .Return {append(&preds[idx + 1], idx)}
	}
	return preds
}

jump_target :: proc(ins: pex.Instruction, idx: int) -> (int, bool) {
	a := -1
	#partial switch ins.op {
	case .Jmp:
		a = 0
	case .JmpT, .JmpF:
		a = 1
	}
	if a < 0 || a >= len(ins.args) || ins.args[a].kind != .Integer {return 0, false}
	return idx + int(ins.args[a].i), true
}

// dest_arg is the slot an opcode assigns, or -1.
dest_arg :: proc(op: pex.Opcode) -> int {
	#partial switch op {
	case .Nop, .Jmp, .JmpT, .JmpF, .Return, .PropSet, .ArraySetElement:
		return -1
	case .CallMethod, .CallStatic, .PropGet:
		return 2
	case .CallParent, .ArrayFindElement, .ArrayRFindElement:
		return 1
	}
	return 0
}

add_leaf :: proc(w: ^Walk, leaf: string) {
	if slice.contains(w.leaves[:], leaf) {return}
	append(w.leaves, strings.clone(leaf))
}

walk_value :: proc(w: ^Walk, v: pex.Value, at: int) {
	#partial switch v.kind {
	case .Null:
		add_leaf(w, "none")
	case .Identifier:
		walk_var(w, v.str, at)
	case:
		add_leaf(w, "const")
	}
}

walk_var :: proc(w: ^Walk, name: string, at: int) {
	if strings.equal_fold(name, "self") {return} // not a read
	switch {
	case !is_fn_var(w.f, name) && strings.has_prefix(name, "::") && strings.has_suffix(name, "_var"):
		add_leaf(w, fmt.tprintf("prop:%s", name[2:len(name) - 4]))
	case !is_fn_var(w.f, name):
		add_leaf(w, fmt.tprintf("member:%s", name))
	case !strings.has_prefix(name, "::"):
		add_leaf(w, fmt.tprintf("%s:%s", "param" if is_param(w.f, name) else "local", name))
	}
	// members too: a write earlier in this body reaches the guard
	for d in reaching_defs(w, name, at) {walk_def(w, d)}
}

is_param :: proc(f: ^pex.Function, name: string) -> bool {
	for &v in f.params {if strings.equal_fold(v.name, name) {return true}}
	return false
}

is_fn_var :: proc(f: ^pex.Function, name: string) -> bool {
	if is_param(f, name) {return true}
	for &v in f.locals {if strings.equal_fold(v.name, name) {return true}}
	return false
}

// reaching_defs: the defs of `name` that reach instruction `at` on some path.
reaching_defs :: proc(w: ^Walk, name: string, at: int) -> [dynamic]int {
	defs := make([dynamic]int, context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	slice.zero(w.seen)
	append(&stack, ..w.preds[at][:])
	for len(stack) > 0 {
		p := pop(&stack)
		if w.seen[p] {continue}
		w.seen[p] = true
		ins := w.f.instructions[p]
		if d := dest_arg(ins.op); d >= 0 && d < len(ins.args) && strings.equal_fold(ins.args[d].str, name) {
			append(&defs, p)
			continue
		}
		append(&stack, ..w.preds[p][:])
	}
	return defs
}

walk_def :: proc(w: ^Walk, d: int) {
	if w.done[d] {return}
	w.done[d] = true
	ins := w.f.instructions[d]
	#partial switch ins.op {
	case .IAdd, .FAdd, .ISub, .FSub, .IMul, .FMul, .IDiv, .FDiv, .IMod, .CmpEq, .CmpLt, .CmpLe, .CmpGt, .CmpGe, .StrCat:
		walk_value(w, ins.args[1], d)
		walk_value(w, ins.args[2], d)
	case .Not, .INeg, .FNeg, .Assign, .Cast:
		walk_value(w, ins.args[1], d)
	case .ArrayLength, .ArrayGetElement:
		add_leaf(w, "array")
		walk_value(w, ins.args[1], d)
	case .ArrayFindElement, .ArrayRFindElement:
		add_leaf(w, "array")
		walk_value(w, ins.args[0], d)
	case .ArrayCreate:
		add_leaf(w, "array")
	case .CallMethod, .CallStatic, .CallParent:
		raw, ok := call_raw(w, ins)
		if !ok {return}
		add_leaf(w, raw)
		first_arg := 2 if ins.op == .CallParent else 3
		if ins.op == .CallMethod {walk_receiver(w, ins.args[1], d)}
		for a in ins.args[first_arg:] {walk_value(w, a, d)}
	case .PropGet:
		obj, prop := ins.args[1], ins.args[0].str
		if is_self(obj) {
			add_leaf(w, fmt.tprintf("prop:%s", prop))
		} else {
			add_leaf(w, fmt.tprintf("pget:%s", lower_key(receiver_type(w, obj), prop)))
			walk_receiver(w, obj, d)
		}
	}
}

is_self :: proc(v: pex.Value) -> bool {
	return v.kind == .Identifier && strings.equal_fold(v.str, "self")
}

// walk_receiver: whatever computed the object is read too; self is not a read.
walk_receiver :: proc(w: ^Walk, v: pex.Value, at: int) {
	if !is_self(v) {walk_value(w, v, at)}
}

// receiver_type is lower; "@class/var" defers an inherited member to resolve_class.
receiver_type :: proc(w: ^Walk, v: pex.Value) -> string {
	if v.kind != .Identifier {return "?"}
	t := var_type(w.f, w.syms, v.str)
	if t == "" && !is_fn_var(w.f, v.str) {return strings.to_lower(fmt.tprintf("@%s/%s", w.o.name, v.str), context.temp_allocator)}
	return "?" if t == "" || strings.contains(t, "[") else t
}

resolve_class :: proc(c: ^Corpus, cls: string) -> string {
	if !strings.has_prefix(cls, "@") {return cls}
	slash := strings.index_byte(cls, '/')
	for k, ok := cls[1:slash], true; ok; k, ok = c.parents[k] {
		if t, found := c.guards.types[fmt.tprintf("%s.%s", k, cls[slash + 1:])]; found {
			return "?" if strings.contains(t, "[") else t
		}
	}
	return "?"
}

// call_raw: "call:<static class>.<fn>" lower, "?" when the receiver is untyped.
call_raw :: proc(w: ^Walk, ins: pex.Instruction) -> (string, bool) {
	#partial switch ins.op {
	case .CallStatic:
		if len(ins.args) >= 3 {return fmt.tprintf("call:%s", lower_key(ins.args[0].str, ins.args[1].str)), true}
	case .CallMethod:
		if len(ins.args) >= 3 {return fmt.tprintf("call:%s", lower_key(receiver_type(w, ins.args[1]), ins.args[0].str)), true}
	case .CallParent:
		if len(ins.args) >= 2 {return fmt.tprintf("call:%s", lower_key(w.o.parent if w.o.parent != "" else "?", ins.args[0].str)), true}
	}
	return "", false
}

// ── resolve ──────────────────────────────────────────────────────────────────

// resolve_leaf walks a raw call/propget up the class chain to its declaring class.
resolve_leaf :: proc(c: ^Corpus, raw: string) -> string {
	is_call := strings.has_prefix(raw, "call:")
	if !is_call && !strings.has_prefix(raw, "pget:") {return raw}
	table := c.guards.fns if is_call else c.guards.props
	dot := strings.index_byte(raw[5:], '.') + 5
	name := raw[dot + 1:]
	key := fmt.tprintf("%s.%s", resolve_class(c, raw[5:dot]), name)
	for cls, ok := key[:strings.index_byte(key, '.')], true; ok; cls, ok = c.parents[cls] {
		if hit, found := table[fmt.tprintf("%s.%s", cls, name)]; found {
			return hit if is_call else fmt.tprintf("propget:%s", hit)
		}
	}
	return fmt.tprintf("%s:%s", "unresolved" if is_call else "propget", key)
}

resolve_guards :: proc(c: ^Corpus) {
	for &gf in c.guards.list {
		latent := make([]bool, len(gf.preds), context.temp_allocator)
		for s in gf.sites {latent[s.idx] = is_latent_leaf(c, resolve_leaf(c, s.raw))}
		for &g in gf.guards {
			out := make([dynamic]string)
			for l in g.leaves {
				r := resolve_leaf(c, l)
				if !slice.contains(out[:], r) {append(&out, strings.clone(r))}
			}
			g.leaves = out
			g.after_wait = reaches(gf.preds, latent, gf.preds[g.idx], {0, len(latent) - 1})
			if g.target <= g.idx {g.loop_cond = true} // backward conditional jump
			for l in gf.loops {
				if g.idx < l.lo || g.idx > l.hi || (l.lo <= g.target && g.target <= l.hi) {continue}
				g.loop_cond = true
				if reaches(gf.preds, latent, {l.hi}, l) {g.poll = true}
			}
		}
		free_all(context.temp_allocator)
	}
}

// is_latent_leaf: a latent native, or a script function in the closure.
is_latent_leaf :: proc(c: ^Corpus, leaf: string) -> bool {
	if strings.has_prefix(leaf, "latent:") {return true}
	if !strings.has_prefix(leaf, "script:") {return false}
	i, ok := c.index[strings.to_lower(leaf[len("script:"):], context.temp_allocator)]
	return ok && c.nodes[i].latent
}

// reaches: a latent site inside `within` flows into `from` (walked backwards, back edges included).
reaches :: proc(preds: [][]int, latent: []bool, from: []int, within: Loop) -> bool {
	seen := make([]bool, len(preds), context.temp_allocator)
	stack := make([dynamic]int, context.temp_allocator)
	append(&stack, ..from)
	for len(stack) > 0 {
		p := pop(&stack)
		if p < within.lo || p > within.hi || seen[p] {continue}
		seen[p] = true
		if latent[p] {return true}
		append(&stack, ..preds[p])
	}
	return false
}

write_guards_tsv :: proc(c: ^Corpus, path: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "script\tfunction\tstate\tidx\tline\tin_closure\tloop_cond\tpoll\tafter_wait\tleaves\n")
	for &gf in c.guards.list {
		in_closure := c.nodes[gf.node].latent
		for &g in gf.guards {
			fmt.sbprintf(&b, "%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t", gf.script, gf.fn, gf.state, g.idx, g.line,
				int(in_closure), int(g.loop_cond), int(g.poll), int(g.after_wait))
			for l, i in g.leaves {
				if i > 0 {strings.write_byte(&b, ',')}
				strings.write_string(&b, l)
			}
			strings.write_byte(&b, '\n')
		}
	}
	if err := os.write_entire_file(path, b.buf[:]); err != nil {
		fmt.eprintfln("failed to write %s: %v", path, err)
	}
}

// ── report ───────────────────────────────────────────────────────────────────

Stats :: struct {
	guards, plain, poll, no_line: int,
	kinds, natives, scripts, latent, latent_poll, poll_kinds, poll_leaves: map[string]int,
	expensive:           map[string][dynamic]string, // native -> "script.fn:line"
}

Native_Row :: struct {
	name, cost, deleted, timing, bucket, effect: string,
}

PLAIN_KINDS :: []string{"member", "prop", "param", "local", "const", "none"}

leaf_kind :: proc(l: string) -> string {
	i := strings.index_byte(l, ':')
	return l if i < 0 else l[:i]
}

load_natives_tsv :: proc() -> map[string]Native_Row {
	rows := make(map[string]Native_Row)
	data, err := os.read_entire_file(NATIVES_TSV, context.allocator)
	if err != nil {
		fmt.eprintfln("failed to read %s: %v", NATIVES_TSV, err)
		return rows
	}
	lines := strings.split_lines(string(data))
	for line in lines[1:] {
		col := strings.split(line, "\t")
		if len(col) < 10 {continue}
		deleted := col[6] if col[6] != "" else "-"
		rows[strings.clone(lower_key(col[0], col[1]))] = Native_Row{fmt.aprintf("%s.%s", col[0], col[1]), col[3], strings.clone(deleted), col[7], col[9], col[2]}
	}
	return rows
}

bump :: proc(m: ^map[string]int, k: string) {
	m[k] = (m[k] or_else 0) + 1
}

gather :: proc(c: ^Corpus, rows: map[string]Native_Row, closure_only: bool) -> (s: Stats) {
	for &gf in c.guards.list {
		if closure_only && !c.nodes[gf.node].latent {continue}
		for &g in gf.guards {
			s.guards += 1
			if g.poll {s.poll += 1}
			if g.line == 0 {s.no_line += 1}
			kinds := make([dynamic]string, context.temp_allocator)
			for l in g.leaves {
				k := leaf_kind(l)
				if !slice.contains(kinds[:], k) {append(&kinds, k)}
				if g.poll {bump(&s.poll_leaves, l)}
				if k == "script" {bump(&s.scripts, l[len(k) + 1:])}
				if k != "native" && k != "latent" {continue}
				name := l[len(k) + 1:]
				bump(&s.natives, name)
				if k == "latent" {
					bump(&s.latent, name)
					if g.poll {bump(&s.latent_poll, name)}
				}
				if row, ok := rows[strings.to_lower(name, context.temp_allocator)]; ok && row.cost == "expensive" {
					if name not_in s.expensive {s.expensive[name] = make([dynamic]string)}
					append(&s.expensive[name], fmt.aprintf("%s.%s:%d", gf.script, gf.fn, g.line))
				}
			}
			plain := true
			for k in kinds {
				bump(&s.kinds, k)
				if g.poll {bump(&s.poll_kinds, k)}
				if !slice.contains(PLAIN_KINDS, k) {plain = false}
			}
			if plain {s.plain += 1}
		}
	}
	return
}

Pair :: struct {
	k: string,
	v: int,
}

sorted :: proc(m: map[string]int) -> []Pair {
	prs := make([dynamic]Pair, context.temp_allocator)
	for k, v in m {append(&prs, Pair{k, v})}
	slice.sort_by(prs[:], proc(a, b: Pair) -> bool {return a.v > b.v || (a.v == b.v && a.k < b.k)})
	return prs[:]
}

// coverage: how many natives cover `pct` of native guard reads.
coverage :: proc(m: map[string]int, pct: f64) -> int {
	prs := sorted(m)
	total := 0
	for p in prs {total += p.v}
	acc := 0
	for p, i in prs {
		acc += p.v
		if f64(acc) >= pct * f64(total) {return i + 1}
	}
	return len(prs)
}

guard_report :: proc(c: ^Corpus) {
	rows := c.guards.natives
	reg: script.Registry
	script.init(&reg)
	cl := gather(c, rows, true)
	all := gather(c, rows, false)
	pct :: proc(n, d: int) -> f64 {return 100.0 * f64(n) / f64(max(d, 1))}

	fmt.println()
	fmt.printfln("GUARDS (JmpT/JmpF conditions)            closure      corpus")
	fmt.printfln("  guards:                              % 8d    % 8d", cl.guards, all.guards)
	fmt.printfln("  all leaves non-native (plain):       % 8d    % 8d   (%.1f%% / %.1f%%)", cl.plain, all.plain, pct(cl.plain, cl.guards), pct(all.plain, all.guards))
	fmt.printfln("  poll conditions:                     % 8d    % 8d", cl.poll, all.poll)
	fmt.printfln("  no trusted source line (line=0):     % 8d    % 8d", cl.no_line, all.no_line)
	fmt.println("  guards touching each leaf kind:")
	for p in sorted(all.kinds) {
		fmt.printfln("    %-34s % 8d    % 8d", p.k, cl.kinds[p.k] or_else 0, p.v)
	}
	fmt.println()

	fmt.println("natives read in guards (by closure count; native: + latent: leaves):")
	fmt.printfln("  %-48s %7s %7s  %-9s %-3s %-9s %-10s %s", "native", "closure", "corpus", "cost", "del", "timing", "bucket", "impl")
	cum := 0
	total := 0
	for p in sorted(cl.natives) {total += p.v}
	for p, i in sorted(cl.natives) {
		if i >= 60 {break}
		cum += p.v
		row, ok := rows[strings.to_lower(p.k, context.temp_allocator)]
		if !ok {row = Native_Row{p.k, "?", "?", "?", "?", "?"}}
		dot := strings.index_byte(p.k, '.')
		impl := "impl" if dot >= 0 && script.is_implemented(&reg, p.k[:dot], p.k[dot + 1:]) else "stub"
		fmt.printfln("  %-48s % 7d % 7d  %-9s %-3s %-9s %-10s %s  (cum %.1f%%)", p.k, p.v, all.natives[p.k] or_else 0,
			row.cost, row.deleted, row.timing, row.bucket, impl, pct(cum, total))
	}
	fmt.printfln("  distinct natives: closure %d, corpus %d", len(cl.natives), len(all.natives))
	for f in ([]f64{0.80, 0.90, 0.95}) {
		fmt.printfln("  natives covering %.0f%% of native guard reads: closure %d, corpus %d", f * 100, coverage(cl.natives, f), coverage(all.natives, f))
	}
	fmt.println()

	fmt.println("script: calls read in guards (not recursed; reads sit one call down):")
	for p, i in sorted(cl.scripts) {
		if i >= 20 {break}
		fmt.printfln("  %-48s closure % 4d  corpus % 5d", p.k, p.v, all.scripts[p.k] or_else 0)
	}
	fmt.println()

	fmt.println("guards reading an EXPENSIVE native (closure sites listed; corpus count):")
	{
		m := make(map[string]int, context.temp_allocator)
		for k, v in all.expensive {m[k] = len(v)}
		for p in sorted(m) {
			sites := cl.expensive[p.k] or_else nil
			fmt.printfln("  %-48s closure % 4d  corpus % 5d", p.k, len(sites), p.v)
			for s in sites {fmt.printfln("      %s", s)}
		}
	}
	fmt.println()

	fmt.println("latent: reads (a guard testing a latent call's result):")
	for p in sorted(all.latent) {
		fmt.printfln("  %-48s closure % 4d (poll %d)  corpus % 5d (poll %d)", p.k, cl.latent[p.k] or_else 0, cl.latent_poll[p.k] or_else 0, p.v, all.latent_poll[p.k] or_else 0)
	}
	fmt.println()

	fmt.printfln("poll conditions (loop exit, loop body waits): closure %d, corpus %d", cl.poll, all.poll)
	fmt.println("  leaf kinds:")
	for p in sorted(all.poll_kinds) {
		fmt.printfln("    %-34s % 8d    % 8d", p.k, cl.poll_kinds[p.k] or_else 0, p.v)
	}
	fmt.println("  top leaves:")
	for p, i in sorted(all.poll_leaves) {
		if i >= 40 {break}
		fmt.printfln("    %-50s % 6d    % 6d", p.k, cl.poll_leaves[p.k] or_else 0, p.v)
	}
}
