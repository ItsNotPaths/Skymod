package magictranslate

// PERK records to Lua: a perk chain becomes one rt.perk whose hooks change an attack's Stamina, a
// weapon hit's or an armor piece's parts, each entry gated on the owner's rank (the chain's first perk read as an actor
// value) and on its tabs' conditions.

import "core:fmt"
import "core:slice"
import "core:strings"
import "../formats/esm"
import "../gamedb"

// (hole perk-translate :tags (magic records player) :sev gap) the 607 magic perk entry points are not translated: each becomes Lua in a landing or cost hook (Multiply, Add, Set and `1 + AV * k` are plain code, entry priority is hook order), Apply_Combat_Hit_Spell and Select_Spell become event scripts. Measure first which fit (build/out/wsM/edges.md section 1).
// (hole swing-spell :tags combat :sev gap :needs (actor-states)) Apply_Weapon_Swing_Spell (Quick Reflexes, 1 entry) is not translated: it runs on the one blocking as an enemy power attacks, and no actor has a block or power-attack state.
// (hole perk-priority :tags combat :sev polish) two Sets on one part: the last hook's wins, so entry priority counts only within a chain; across perks it is file order.

// Point is where an entry point's entries land: the perk file's function (FN_KINDS), its context,
// the part they change, the Lua ref each tab's conditions run on (tab 0 the owner), and a test the
// moment itself needs.
@(private)
Point :: struct {
	fn, ctx, part: string,
	tabs:          [3]string,
	only:          string,
}

// FN_KINDS are the hook kinds each function of a perk file runs as: an entry about weapon hits
// counts for melee and archery alike.
@(private)
FN_KINDS := [?][2]string{{"cost", "meleecost"}, {"hit", "meleehit"}, {"hit", "archhit"}, {"armor", "armorhit"}}

@(private)
ATTACKER :: [3]string{"h.actor", "h.source", "h.target"}

@(private)
POINTS := #partial [gamedb.Entry_Point]Point {
	.Calculate_Weapon_Damage          = {"hit", "h", "h.damage", ATTACKER, ""},
	.Mod_Attack_Damage                = {"hit", "h", "h.damage", ATTACKER, ""},
	.Mod_Incoming_Damage              = {"hit", "h", "h.damage", {"h.target", "h.actor", "h.source"}, ""},
	.Mod_Target_Damage_Resistance     = {"hit", "h", "h.armor_pen", ATTACKER, ""},
	.Calculate_My_Critical_Hit_Chance = {"hit", "h", "h.crit_chance", ATTACKER, ""},
	.Calculate_My_Critical_Hit_Damage = {"hit", "h", "h.crit_damage", ATTACKER, ""},
	.Mod_Power_Attack_Damage          = {"hit", "h", "h.power_mult", ATTACKER, ""},
	.Mod_Sneak_Attack_Mult            = {"hit", "h", "h.sneak_mult", ATTACKER, ""},
	.Apply_Combat_Hit_Spell           = {"hit", "h", "", ATTACKER, ""},
	.Apply_Bashing_Spell              = {"hit", "h", "", ATTACKER, "h.bash"},
	.Mod_Power_Attack_Stamina         = {"cost", "c", "c.cost", {"c.actor", "c.source", ""}, "c.power"},
	.Mod_Armor_Rating                 = {"armor", "a", "a.rating", {"a.actor", "a.source", ""}, ""},
}

// perk_chain is the chain a perk heads, first rank first; nil when another perk ranks up into it.
perk_chain :: proc(src: ^Source, head: Form_ID) -> []Form_ID {
	for _, p in src.db.perks {
		if p.next_rank == head {return nil}
	}
	chain := make([dynamic]Form_ID, context.temp_allocator)
	for cur := head; cur != 0 && !slice.contains(chain[:], cur); cur = src.db.perks[cur].next_rank {
		append(&chain, cur)
	}
	return chain[:]
}

@(private)
chain_wanted :: proc(src: ^Source, chain: []Form_ID) -> bool {
	for p in chain {
		if src.wanted[p] {return true}
	}
	return false
}

// perk_lua writes a perk chain as a perks/ file: "" when none of its entries is a translated
// point; false when one has a condition or function with no Lua form.
perk_lua :: proc(src: ^Source, chain: []Form_ID) -> (text: string, ok: bool) {
	lines := make(map[string][dynamic]string, context.temp_allocator)
	for member, rank in chain {
		entries := slice.clone(src.db.perks[member].entries, context.temp_allocator)
		slice.stable_sort_by(entries, proc(a, b: gamedb.Perk_Entry) -> bool {return a.priority > b.priority})
		for e in entries {
			if e.kind != .Entry_Point || e.point > max(gamedb.Entry_Point) || POINTS[e.point].fn == "" || gated_on_unbuilt(e) {continue}
			pt := POINTS[e.point]
			gate := entry_gate(src, chain, rank, e, pt) or_return
			change := change_lua(src, pt, e) or_return
			if pt.fn not_in lines {lines[pt.fn] = make([dynamic]string, context.temp_allocator)}
			append(&lines[pt.fn], fmt.tprintf("  if %s then %s end", gate, change))
		}
	}
	if len(lines) == 0 {return "", true}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintfln(&b, "-- %s PERK %s", src.files[u32(chain[0] >> 32)], src.edids[chain[0]])
	fmt.sbprintln(&b, "local rt = require('skymod.rt')")
	for fn in ([]string{"cost", "hit", "armor"}) {
		body := lines[fn] or_continue
		fmt.sbprintfln(&b, "\nlocal function %s(%s)", fn, fn[:1])
		for l in body {fmt.sbprintln(&b, l)}
		fmt.sbprintln(&b, "end")
	}
	fmt.sbprintln(&b, "\nreturn rt.perk {")
	fmt.sbprint(&b, "  ranks = {")
	for p, i in chain {fmt.sbprintf(&b, "%s %q", "," if i > 0 else "", form_name(src, p))}
	fmt.sbprintln(&b, " },")
	fmt.sbprint(&b, "  hooks = {")
	n := 0
	for k in FN_KINDS {
		if k[0] not_in lines {continue}
		fmt.sbprintf(&b, "%s %s = %s", "," if n > 0 else "", k[1], k[0])
		n += 1
	}
	fmt.sbprintln(&b, " },")
	fmt.sbprintln(&b, "}")
	return strings.to_string(b), true
}

// entry_gate is the test an entry runs under: the owner's rank reaches this member's, and below a
// later one where its tab 0 says HasPerk(<that one>) == 0; then each tab's conditions on its ref,
// which may be none (a fist has no weapon).
@(private)
entry_gate :: proc(src: ^Source, chain: []Form_ID, rank: int, e: gamedb.Perk_Entry, pt: Point) -> (text: string, ok: bool) {
	head := src.edids[chain[0]]
	if head == "" {return "", false}
	top := 0
	parts := make([dynamic]string, context.temp_allocator)
	for tab in e.tabs {
		who := Who{pt.ctx, pt.tabs[tab.tab] if tab.tab < len(pt.tabs) else "", ""}
		if who.subject == "" {return "", false}
		conds := tab.conditions
		if tab.tab == 0 {conds, top = drop_rank_tests(chain, rank, conds)}
		if len(conds) == 0 {continue}
		gate := gate_lua(src, conds, who, " and ") or_return
		if len(conds) > 1 {gate = fmt.tprintf("(%s)", gate)}
		append(&parts, gate if tab.tab == 0 else fmt.tprintf("%s and %s", who.subject, gate))
	}
	if pt.only != "" {inject_at(&parts, 0, pt.only)}
	av := fmt.tprintf("%s.av.%s.value", pt.tabs[0], head)
	switch {
	case top == rank + 1: inject_at(&parts, 0, fmt.tprintf("%s == %d", av, rank + 1))
	case top > 0:         inject_at(&parts, 0, fmt.tprintf("%s >= %d and %s <= %d", av, rank + 1, av, top))
	case:                 inject_at(&parts, 0, fmt.tprintf("%s >= %d", av, rank + 1))
	}
	return strings.join(parts[:], " and ", context.temp_allocator), true
}

// drop_rank_tests takes out of tab 0 each HasPerk(<a later member>) == 0 outside an OR run: the
// rank says it. top is the highest rank the entry still runs at, 0 for any.
@(private)
drop_rank_tests :: proc(chain: []Form_ID, rank: int, conds: []gamedb.Condition) -> (kept: []gamedb.Condition, top: int) {
	out := make([dynamic]gamedb.Condition, context.temp_allocator)
	for c, i in conds {
		in_or := .Or in c.flags || i > 0 && .Or in conds[i - 1].flags
		later, found := slice.linear_search(chain, Form_ID(c.param1))
		if !in_or && found && later > rank && c.run_on == .Subject && esm.condition_function(c.function).name == "HasPerk" && truth(c.op, c.value) == .No {
			top = later if top == 0 else min(top, later)
			continue
		}
		append(&out, c)
	}
	return out[:], top
}

// UNBUILT are the conditions with no body yet, which pass (action-state-conditions): an entry
// gated on one would run on every hit, so it is not translated.
@(private)
UNBUILT := [?]string{"IsAttackType", "IsSprinting", "IsBlocking"}

@(private)
gated_on_unbuilt :: proc(e: gamedb.Perk_Entry) -> bool {
	for tab in e.tabs {
		for c in tab.conditions {
			if slice.contains(UNBUILT[:], esm.condition_function(c.function).name) {return true}
		}
	}
	return false
}

// change_lua is what an entry does: Set, Add, Multiply, or Multiply by 1 + AV x k (the owner's AV)
// to its part; Select_Spell puts its spell on the one hit.
@(private)
change_lua :: proc(src: ^Source, pt: Point, e: gamedb.Perk_Entry) -> (text: string, ok: bool) {
	p, v := pt.part, e.values[0]
	#partial switch e.function {
	case .Select_Spell:
		if e.form == 0 {return "", false}
		return fmt.tprintf("%s.apply(%q)", pt.ctx, form_name(src, e.form)), true
	case .Set_Value:      return fmt.tprintf("%s.set = %v", p, v), true
	case .Add_Value:      return fmt.tprintf("%s.add = %s.add + %v", p, p, v), true
	case .Multiply_Value: return fmt.tprintf("%s.mult = %s.mult * %v", p, p, v), true
	case .Multiply_1_Plus_AV_Mult:
		av := av_name(i32(v))
		if av == "" {return "", false}
		return fmt.tprintf("%s.mult = %s.mult * (1 + %s.av.%s.value * %v)", p, p, pt.tabs[0], av, e.values[1]), true
	}
	return "", false
}
