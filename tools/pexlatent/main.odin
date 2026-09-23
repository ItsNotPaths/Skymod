package main

// RE harness (not shipped): survey the compiled-Papyrus corpus for LATENT state —
// the suspended-call-stack problem behind converted-script persistence (docs/mods.md
// open q. #6). Answers, empirically, whether an "intelligent transpiler" that splits
// functions at wait points (CPS → timer continuations, state = plain data) is viable:
//
//   1. direct suspension sites (Utility.Wait* / PlayAnimationAndWait) + their SHAPE
//      (inside a loop = poll idiom → repeating timer; straight-line → timer chain;
//      constant vs computed wait duration)
//   2. the TRANSITIVE latent closure over the call graph (a caller of a waiter must
//      itself suspend — that's exactly what Papyrus persists stacks for), with
//      optimistic (resolved receivers only) and conservative (name-match fallback)
//      bounds, since instance-call receivers need type resolution
//   3. recursion inside the closure (cycles = the case a static splitter can't do)
//   4. how much code already fits the data-persistable event model: RegisterForUpdate
//      family, OnUpdate handlers, GotoState / multi-state objects, and captured-state
//      size (locals) at latent functions
//
//   odin run tools/pexlatent -- <archive.bsa> [more.bsa ...] [--top N]
//
// Metadata/counts only — no source text (PEX carries none). Headless, no SDL.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../../src/formats/bsa"
import "../../src/formats/pex"

// The latent set is pex.LATENT_GLOBALS / LATENT_METHODS. The "wait"-substring report
// at the end sanity-checks it against the corpus.
is_latent_method_name :: proc(name: string) -> bool {
	for k in pex.LATENT_METHODS {
		if k[strings.index_byte(k, '.') + 1:] == name {return true}
	}
	return false
}

// A latent-named method call whose receiver type is known; it counts once the class
// hierarchy is (Scene.Start is not Quest.Start).
Typed_Site :: struct {
	recv, fn: string, // lower, cloned
	in_loop:  bool,
}

REGISTER_FNS := []string{"registerforupdate", "registerforsingleupdate", "registerforupdategametime", "registerforsingleupdategametime"}

Node :: struct {
	key:          string, // "class.fn" lower — cloned, owned
	class:        string, // lower, cloned
	fn:           string, // lower, cloned
	is_event:     bool,   // name starts with "on" (event-handler root heuristic)
	bodies:       int,    // state variants merged into this node
	n_instr:      int,
	n_locals:     int,    // max over bodies — captured-state-size proxy
	direct_sites: int,    // latent native call sites in this body
	typed_sites:  [dynamic]Typed_Site, // resolved to direct_sites by count_typed_sites
	sites_loop:   int,    // ...of those, inside a backward-jump span (poll loop)
	const_waits:  int,    // Utility.Wait* with a literal duration
	edge_keys:    [dynamic]string, // resolved callee keys (cloned), linked later
	name_edges:   [dynamic]string, // unresolved-receiver callee fn names (cloned)
	edges:        [dynamic]int,    // linked callee node indices
	latent:       bool, // optimistic closure member
	latent_c:     bool, // conservative closure member
	in_cycle:     bool,
}

Corpus :: struct {
	nodes:      [dynamic]Node,
	index:      map[string]int,            // key -> node
	by_fn:      map[string][dynamic]int,   // fn name -> nodes (conservative edges)
	parents:    map[string]string,         // class -> parent class (lower, cloned)
	classes:    map[string]bool,           // every object/class name seen (lower, cloned)
	wait_names: map[string]int,            // call targets containing "wait" (sanity)
	by_native:  map[string]int,            // direct latent sites per native ("?.fn" = receiver unknown)
	scripts:    int,
	parsed:     int,
	objects:    int,
	// save-weight inputs: member variables per object (what a variables-only
	// persistence row can maximally carry; properties refill from gamedb)
	member_vars:    int,
	autoprop_vars:  int, // ::X_var property backers (values come from ESP VMAD → refilled, not persisted)
	// event-model usage
	register_calls: int,
	onupdate_defs:  int,
	gotostate_calls: int,
	multi_state_objects: int,
	states_total:   int,
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: pexlatent <archive.bsa> [more.bsa ...] [--top N]")
		os.exit(2)
	}
	top_n := 30
	paths := make([dynamic]string)
	for i in 1 ..< len(os.args) {
		if os.args[i] == "--top" && i + 1 < len(os.args) {
			if v, ok := strconv.parse_int(os.args[i + 1]); ok {top_n = v}
		} else if strings.has_suffix(strings.to_lower(os.args[i], context.temp_allocator), ".bsa") {
			append(&paths, os.args[i])
		}
	}

	c: Corpus
	c.index = make(map[string]int)
	c.by_fn = make(map[string][dynamic]int)
	c.parents = make(map[string]string)
	c.classes = make(map[string]bool)
	c.wait_names = make(map[string]int)
	c.by_native = make(map[string]int)

	for p in paths {scan_bsa(&c, p)}
	count_typed_sites(&c)
	link(&c)
	propagate(&c)
	find_cycles(&c)
	report(&c, top_n)
}

// ── corpus scan ──────────────────────────────────────────────────────────────

scan_bsa :: proc(c: ^Corpus, path: string) {
	arc, ok := bsa.open(path)
	if !ok {
		fmt.eprintfln("failed to open BSA: %s", path)
		return
	}
	defer bsa.close(&arc)

	for e in arc.entries {
		lower := strings.to_lower(e.path, context.temp_allocator)
		if !strings.has_prefix(lower, "scripts\\") || !strings.has_suffix(lower, ".pex") {
			continue
		}
		c.scripts += 1
		data, xok := bsa.extract(&arc, e, context.temp_allocator)
		if !xok {free_all(context.temp_allocator);continue}
		p, pok := pex.parse(data, context.temp_allocator)
		if !pok {free_all(context.temp_allocator);continue}
		c.parsed += 1
		for &o in p.objects {
			scan_object(c, &p, &o)
		}
		free_all(context.temp_allocator)
	}
}

scan_object :: proc(c: ^Corpus, p: ^pex.Pex, o: ^pex.Object) {
	c.objects += 1
	class := strings.to_lower(o.name, context.temp_allocator)
	if class not_in c.classes {
		c.classes[strings.clone(class)] = true
	}
	if o.parent != "" {
		if class not_in c.parents {
			c.parents[strings.clone(class)] = strings.clone(strings.to_lower(o.parent, context.temp_allocator))
		}
	}

	// Object-level symbol table: member vars + properties + self (receiver typing).
	syms := make(map[string]string, len(o.variables) + len(o.properties) + 1, context.temp_allocator)
	syms["self"] = class
	c.member_vars += len(o.variables)
	for &v in o.variables {
		if strings.has_prefix(v.name, "::") {c.autoprop_vars += 1}
		syms[strings.to_lower(v.name, context.temp_allocator)] = strings.to_lower(v.type_name, context.temp_allocator)
	}
	for &pr in o.properties {
		syms[strings.to_lower(pr.name, context.temp_allocator)] = strings.to_lower(pr.type_name, context.temp_allocator)
	}

	named_states := 0
	for &st in o.states {
		if st.name != "" {named_states += 1}
		for &f in st.functions {
			if f.is_native || len(f.instructions) == 0 {continue}
			scan_function(c, o, class, syms, &f)
		}
	}
	c.states_total += named_states
	if named_states > 1 || (named_states == 1 && o.auto_state == "") {c.multi_state_objects += 1}
	// property handlers can contain code too — rare, but walk them for completeness
	for &pr in o.properties {
		if pr.has_reader {scan_function(c, o, class, syms, &pr.reader)}
		if pr.has_writer {scan_function(c, o, class, syms, &pr.writer)}
	}
}

scan_function :: proc(c: ^Corpus, o: ^pex.Object, class: string, syms: map[string]string, f: ^pex.Function) {
	if len(f.instructions) == 0 {return}
	fn := strings.to_lower(f.name, context.temp_allocator)
	if fn == "" {fn = "<prop>"}
	key := fmt.tprintf("%s.%s", class, fn)

	ni: int
	if i, ok := c.index[key]; ok {
		ni = i
	} else {
		ni = len(c.nodes)
		k := strings.clone(key)
		append(&c.nodes, Node{key = k, class = strings.clone(class), fn = strings.clone(fn), is_event = strings.has_prefix(fn, "on")})
		c.index[k] = ni
		if fn not_in c.by_fn {
			c.by_fn[strings.clone(fn)] = make([dynamic]int)
		}
		lst := &c.by_fn[fn]
		append(lst, ni)
	}
	n := &c.nodes[ni]
	n.bodies += 1
	n.n_instr += len(f.instructions)
	n.n_locals = max(n.n_locals, len(f.locals))
	if fn == "onupdate" || fn == "onupdategametime" {c.onupdate_defs += 1}

	// Backward-jump spans (loops). Offsets are relative instruction counts.
	Loop :: struct {lo, hi: int}
	loops := make([dynamic]Loop, context.temp_allocator)
	for ins, idx in f.instructions {
		off_arg := -1
		#partial switch ins.op {
		case .Jmp:
			off_arg = 0
		case .JmpT, .JmpF:
			off_arg = 1
		}
		if off_arg >= 0 && off_arg < len(ins.args) && ins.args[off_arg].kind == .Integer {
			t := idx + int(ins.args[off_arg].i)
			if t <= idx {append(&loops, Loop{t, idx})}
		}
	}
	in_loop :: proc(loops: [dynamic]Loop, i: int) -> bool {
		for l in loops {if l.lo <= i && i <= l.hi {return true}}
		return false
	}

	for ins, idx in f.instructions {
		#partial switch ins.op {
		case .CallStatic:
			if len(ins.args) < 3 {continue}
			cls := strings.to_lower(ins.args[0].str, context.temp_allocator)
			name := strings.to_lower(ins.args[1].str, context.temp_allocator)
			tgt := fmt.tprintf("%s.%s", cls, name)
			tally_wait_name(c, tgt, name)
			if slice.contains(pex.LATENT_GLOBALS, tgt) {
				count_site(c, n, tgt, in_loop(loops, idx))
				if len(ins.args) > 3 && (ins.args[3].kind == .Float || ins.args[3].kind == .Integer) {
					n.const_waits += 1
				}
			} else {
				add_edge(n, tgt)
			}
		case .CallMethod:
			if len(ins.args) < 3 {continue}
			name := strings.to_lower(ins.args[0].str, context.temp_allocator)
			tally_wait_name(c, name, name)
			if name == "gotostate" {c.gotostate_calls += 1;continue}
			if slice.contains(REGISTER_FNS, name) {c.register_calls += 1;continue}
			// resolve the receiver's static type: param/local, then member/property/self
			recv := strings.to_lower(ins.args[1].str, context.temp_allocator)
			t := ""
			for &pv in f.params {
				if strings.equal_fold(pv.name, recv) {t = strings.to_lower(pv.type_name, context.temp_allocator);break}
			}
			if t == "" {
				for &lv in f.locals {
					if strings.equal_fold(lv.name, recv) {t = strings.to_lower(lv.type_name, context.temp_allocator);break}
				}
			}
			if t == "" {
				if s, ok := syms[recv]; ok {t = s}
			}
			typed := t != "" && !strings.contains(t, "[")
			if is_latent_method_name(name) {
				if typed {
					append(&n.typed_sites, Typed_Site{strings.clone(t), strings.clone(name), in_loop(loops, idx)})
				} else {
					count_site(c, n, fmt.tprintf("?.%s", name), in_loop(loops, idx))
					continue
				}
			}
			if typed {
				add_edge(n, fmt.tprintf("%s.%s", t, name))
			} else {
				add_name_edge(n, name)
			}
		case .CallParent:
			if len(ins.args) < 2 {continue}
			name := strings.to_lower(ins.args[0].str, context.temp_allocator)
			tally_wait_name(c, name, name)
			parent := strings.to_lower(o.parent, context.temp_allocator)
			if parent != "" {
				add_edge(n, fmt.tprintf("%s.%s", parent, name))
			}
		}
	}
}

count_site :: proc(c: ^Corpus, n: ^Node, native: string, loop: bool) {
	n.direct_sites += 1
	if loop {n.sites_loop += 1}
	if native not_in c.by_native {c.by_native[strings.clone(native)] = 0}
	c.by_native[native] += 1
}

// count_typed_sites walks each typed receiver up the class chain to the declaring class.
count_typed_sites :: proc(c: ^Corpus) {
	for &n in c.nodes {
		for s in n.typed_sites {
			for cls, ok := s.recv, true; ok; cls, ok = c.parents[cls] {
				key := fmt.tprintf("%s.%s", cls, s.fn)
				if slice.contains(pex.LATENT_METHODS, key) {
					count_site(c, &n, key, s.in_loop)
					break
				}
			}
		}
	}
}

add_edge :: proc(n: ^Node, key: string) {
	for e in n.edge_keys {if e == key {return}}
	append(&n.edge_keys, strings.clone(key))
}

add_name_edge :: proc(n: ^Node, name: string) {
	for e in n.name_edges {if e == name {return}}
	append(&n.name_edges, strings.clone(name))
}

tally_wait_name :: proc(c: ^Corpus, tgt: string, name: string) {
	if !strings.contains(name, "wait") {return}
	if existing, found := c.wait_names[tgt]; found {
		c.wait_names[tgt] = existing + 1
	} else {
		c.wait_names[strings.clone(tgt)] = 1
	}
}

// ── link + closure ───────────────────────────────────────────────────────────

// link resolves edge keys to node indices, walking the parent-class chain when the
// named class doesn't define the function (inherited script-defined calls).
link :: proc(c: ^Corpus) {
	for &n in c.nodes {
		for k in n.edge_keys {
			dot := strings.index_byte(k, '.')
			if dot < 0 {continue}
			cls, fn := k[:dot], k[dot + 1:]
			for {
				key := fmt.tprintf("%s.%s", cls, fn)
				if i, ok := c.index[key]; ok {
					append(&n.edges, i)
					break
				}
				parent, has := c.parents[cls]
				if !has {
					// End of the chain with no script body. If the class IS a known
					// script object, this is a declared NATIVE (natives don't suspend
					// script-visibly outside the latent set) — drop the edge. Only a
					// class the corpus has never seen keeps the name as a conservative
					// fallback (mistyped receivers, external classes).
					if cls not_in c.classes {
						add_name_edge(&n, strings.clone(fn))
					}
					break
				}
				cls = parent
			}
		}
	}
}

// propagate computes the latent closures to fixpoint: optimistic over resolved
// edges only, conservative additionally treating an unresolved call to NAME as an
// edge to every latent node with that fn name.
propagate :: proc(c: ^Corpus) {
	for &n in c.nodes {n.latent = n.direct_sites > 0}
	for changed := true; changed; {
		changed = false
		for &n in c.nodes {
			if n.latent {continue}
			for e in n.edges {
				if c.nodes[e].latent {n.latent = true;changed = true;break}
			}
		}
	}
	for &n in c.nodes {n.latent_c = n.latent}
	for changed := true; changed; {
		changed = false
		outer: for &n in c.nodes {
			if n.latent_c {continue}
			for e in n.edges {
				if c.nodes[e].latent_c {n.latent_c = true;changed = true;continue outer}
			}
			for name in n.name_edges {
				if lst, ok := c.by_fn[name]; ok {
					for i in lst {
						if c.nodes[i].latent_c {n.latent_c = true;changed = true;continue outer}
					}
				}
			}
		}
	}
}

// find_cycles marks latent nodes on cycles (resolved edges, latent subgraph) —
// the shape a static wait-point splitter cannot handle. Iterative Tarjan.
find_cycles :: proc(c: ^Corpus) {
	n := len(c.nodes)
	idx := make([]int, n);defer delete(idx)
	low := make([]int, n);defer delete(low)
	on_stk := make([]bool, n);defer delete(on_stk)
	for i in 0 ..< n {idx[i] = -1}
	stack := make([dynamic]int);defer delete(stack)
	counter := 0

	Frame :: struct {v, ei: int}
	work := make([dynamic]Frame);defer delete(work)

	for root in 0 ..< n {
		if idx[root] >= 0 || !c.nodes[root].latent {continue}
		append(&work, Frame{root, 0})
		idx[root] = counter;low[root] = counter;counter += 1
		append(&stack, root);on_stk[root] = true
		for len(work) > 0 {
			fr := &work[len(work) - 1]
			v := fr.v
			advanced := false
			for fr.ei < len(c.nodes[v].edges) {
				w := c.nodes[v].edges[fr.ei]
				fr.ei += 1
				if !c.nodes[w].latent {continue}
				if idx[w] < 0 {
					idx[w] = counter;low[w] = counter;counter += 1
					append(&stack, w);on_stk[w] = true
					append(&work, Frame{w, 0})
					advanced = true
					break
				} else if on_stk[w] {
					low[v] = min(low[v], idx[w])
				}
			}
			if advanced {continue}
			// v done: pop SCC if root
			if low[v] == idx[v] {
				scc := make([dynamic]int, context.temp_allocator)
				for {
					w := pop(&stack)
					on_stk[w] = false
					append(&scc, w)
					if w == v {break}
				}
				if len(scc) > 1 {
					for w in scc {c.nodes[w].in_cycle = true}
				} else {
					// self-loop?
					v0 := scc[0]
					for e in c.nodes[v0].edges {
						if e == v0 {c.nodes[v0].in_cycle = true;break}
					}
				}
			}
			pop(&work)
			if len(work) > 0 {
				p := work[len(work) - 1].v
				low[p] = min(low[p], low[v])
			}
		}
	}
}

// ── report ───────────────────────────────────────────────────────────────────

report :: proc(c: ^Corpus, top_n: int) {
	total := len(c.nodes)
	direct, direct_sites, in_loop, const_w := 0, 0, 0, 0
	lat_o, lat_c, cyc, ev_lat, frag_lat := 0, 0, 0, 0, 0
	locals_sum, locals_max := 0, 0
	is_fragment :: proc(class: string) -> bool {
		return strings.has_prefix(class, "qf_") || strings.has_prefix(class, "tif_") ||
		       strings.has_prefix(class, "sf_") || strings.contains(class, "_qf_") ||
		       strings.contains(class, "_tif_") || strings.contains(class, "_sf_")
	}
	for &n in c.nodes {
		if n.direct_sites > 0 {
			direct += 1
			direct_sites += n.direct_sites
			in_loop += n.sites_loop
			const_w += n.const_waits
		}
		if n.latent {
			lat_o += 1
			locals_sum += n.n_locals
			locals_max = max(locals_max, n.n_locals)
			if n.is_event {ev_lat += 1}
			if n.in_cycle {cyc += 1}
			if is_fragment(n.class) {frag_lat += 1}
		}
		if n.latent_c {lat_c += 1}
	}

	fmt.printfln("scripts: %d  parsed: %d  objects: %d  functions-with-bodies: %d", c.scripts, c.parsed, c.objects, total)
	fmt.println()
	fmt.printfln("DIRECT suspension:")
	fmt.printfln("  functions with a latent native call: %d (%.1f%%)", direct, 100.0 * f64(direct) / f64(max(total, 1)))
	fmt.printfln("  latent call sites:                   %d", direct_sites)
	fmt.printfln("    inside a loop (poll idiom):        %d (%.1f%%)", in_loop, 100.0 * f64(in_loop) / f64(max(direct_sites, 1)))
	fmt.printfln("    straight-line:                     %d", direct_sites - in_loop)
	fmt.printfln("    constant wait duration:            %d", const_w)
	fmt.println()
	fmt.printfln("TRANSITIVE latent closure:")
	fmt.printfln("  optimistic (resolved edges):    %d (%.1f%%)", lat_o, 100.0 * f64(lat_o) / f64(max(total, 1)))
	fmt.printfln("  conservative (+name fallback):  %d (%.1f%%)", lat_c, 100.0 * f64(lat_c) / f64(max(total, 1)))
	fmt.printfln("  event-handler roots in closure: %d", ev_lat)
	fmt.printfln("  quest-fragment (qf_/tif_/sf_):  %d  (one-shot generated stage code)", frag_lat)
	fmt.printfln("  latent nodes on call cycles:    %d  (static splitting blocked)", cyc)
	fmt.printfln("  locals in latent fns: avg %.1f  max %d", f64(locals_sum) / f64(max(lat_o, 1)), locals_max)
	fmt.println()
	fmt.printfln("event-model usage (persists as plain data):")
	fmt.printfln("  RegisterForUpdate-family call sites: %d", c.register_calls)
	fmt.printfln("  OnUpdate handler bodies:             %d", c.onupdate_defs)
	fmt.printfln("  GotoState call sites:                %d", c.gotostate_calls)
	fmt.printfln("  objects with named states: %d  (named states total: %d)", c.multi_state_objects, c.states_total)
	fmt.println()
	fmt.printfln("save-weight inputs:")
	fmt.printfln("  member variables: %d total, avg %.1f/object; %d are ::auto-prop backers (refilled from gamedb, not persisted) -> avg %.1f persistable vars/object",
		c.member_vars, f64(c.member_vars) / f64(max(c.objects, 1)), c.autoprop_vars,
		f64(c.member_vars - c.autoprop_vars) / f64(max(c.objects, 1)))
	fmt.println()

	fmt.printfln("direct latent sites by native:")
	{
		Pair :: struct {k: string, v: int}
		prs := make([dynamic]Pair, context.temp_allocator)
		for k, v in c.by_native {append(&prs, Pair{k, v})}
		slice.sort_by(prs[:], proc(a, b: Pair) -> bool {return a.v > b.v})
		for pr in prs {fmt.printfln("  %6d  %s", pr.v, pr.k)}
	}
	fmt.println()

	fmt.printfln("call targets containing 'wait' (latent-set sanity check):")
	{
		Pair :: struct {k: string, v: int}
		prs := make([dynamic]Pair, context.temp_allocator)
		for k, v in c.wait_names {append(&prs, Pair{k, v})}
		slice.sort_by(prs[:], proc(a, b: Pair) -> bool {return a.v > b.v})
		for pr in prs {fmt.printfln("  %6d  %s", pr.v, pr.k)}
	}
	fmt.println()

	// top classes by latent function count
	cls_count := make(map[string]int, 256, context.temp_allocator)
	for &n in c.nodes {
		if n.latent {cls_count[n.class] = cls_count[n.class] + 1}
	}
	Pair :: struct {k: string, v: int}
	prs := make([dynamic]Pair, context.temp_allocator)
	for k, v in cls_count {append(&prs, Pair{k, v})}
	slice.sort_by(prs[:], proc(a, b: Pair) -> bool {return a.v > b.v})
	fmt.printfln("top %d classes by latent functions:", top_n)
	for pr, i in prs {
		if i >= top_n {break}
		fmt.printfln("  %4d  %s", pr.v, pr.k)
	}
	fmt.println()

	// cycle examples (first few) — what recursion-through-wait looks like
	fmt.println("cycle members (first 20):")
	shown := 0
	for &n in c.nodes {
		if n.in_cycle && shown < 20 {fmt.printfln("  %s", n.key);shown += 1}
	}
}
