package script

// Perk entry points: a value the engine asks for (a spell's magnitude, a price) runs through the
// entry-point entries of every perk its owner has.

import "core:math/rand"
import "core:slice"
import "../conditions"
import "../gamedb"
import "../worldstate"

@(private = "file")
Ranked_Entry :: struct {
	entry: gamedb.Perk_Entry,
	order: int,
}

// (hole perk-entry-ties :tags (player records) :sev polish) entries of equal priority run in perk-list order; Skyrim's tie order is fixed but unexplained: the engine walks an actor's AIPerkData array in order (NoahBoddie perk-entry-point-extender), and how entries are inserted is only in the binary (searched 2026-09-26; findings.md section 7).
// perk_value runs `value` through `owner`'s entries on `point`, highest priority first, so the
// lowest runs last and wins a Set (CK wiki Perk; findings.md section 7). An entry applies when
// every condition tab passes: tab 0 runs on the owner, tab i on args[i-1].
perk_value :: proc(c: ^Call, point: gamedb.Entry_Point, owner: Form_ID, value: f32, args: ..Form_ID) -> f32 {
	entries := make([dynamic]Ranked_Entry, context.temp_allocator)
	for perk in worldstate.perk_list(c.ws, c.db, owner) {
		p, _ := gamedb.perk_of(c.db, perk)
		for e in p.entries {
			if e.kind == .Entry_Point && e.point == point && tabs_pass(c, e, owner, args) {append(&entries, Ranked_Entry{e, len(entries)})}
		}
	}
	slice.sort_by(entries[:], proc(a, b: Ranked_Entry) -> bool {
		return a.entry.priority > b.entry.priority || a.entry.priority == b.entry.priority && a.order < b.order
	})
	v := value
	for r in entries {v = apply_entry(c, r.entry, owner, v)}
	return v
}

@(private = "file")
tabs_pass :: proc(c: ^Call, e: gamedb.Perk_Entry, owner: Form_ID, args: []Form_ID) -> bool {
	for t in e.tabs {
		subject := owner
		if t.tab > 0 {subject = args[t.tab - 1] if int(t.tab) <= len(args) else 0}
		ctx := condition_context(c, subject, owner)
		if !conditions.all(&ctx, t.conditions) {return false}
	}
	return true
}

@(private = "file")
apply_entry :: proc(c: ^Call, e: gamedb.Perk_Entry, owner: Form_ID, v: f32) -> f32 {
	x := e.values[0]
	av_times :: proc(c: ^Call, e: gamedb.Perk_Entry, owner: Form_ID) -> f32 {
		i := int(e.values[0])
		if i < 0 || i >= len(gamedb.AV_NAMES) {return 0}
		return worldstate.av_current(c.ws, c.db, owner, gamedb.AV_NAMES[i]) * e.values[1]
	}
	#partial switch e.function {
	case .Set_Value:
		return x
	case .Add_Value:
		return v + x
	case .Multiply_Value:
		return v * x
	case .Add_Range_To_Value:
		return v + rand.float32_range(min(x, e.values[1]), max(x, e.values[1]))
	case .Absolute_Value:
		return abs(v)
	case .Negative_Absolute_Value:
		return -abs(v)
	case .Add_AV_Mult:
		return v + av_times(c, e, owner)
	case .Set_AV_Mult:
		return av_times(c, e, owner)
	case .Multiply_AV_Mult:
		return v * av_times(c, e, owner)
	case .Multiply_1_Plus_AV_Mult:
		return v * (1 + av_times(c, e, owner))
	}
	return v
}
