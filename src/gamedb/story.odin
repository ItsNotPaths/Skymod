package gamedb

// The story manager tree (SMBN branch, SMQN quest and SMEN event nodes). Each node names its parent
// (PNAM) and the sibling before it (SNAM); the event nodes are the roots. An event walks down from
// the root of its type, and a quest node starts its quests (script/story.odin).

import "core:slice"
import "../formats/esm"

Story_Node_Kind :: enum u8 {
	Branch,
	Quest,
	Event,
}

// Story_Node flags (DNAM). Random and the quest-node bits, from xEdit.
STORY_RANDOM :: 0x0000_0001
STORY_DO_ALL_BEFORE_REPEATING :: 0x0001_0000
STORY_SHARES_EVENT :: 0x0002_0000
STORY_NUM_QUESTS_TO_RUN :: 0x0004_0000

Story_Node :: struct {
	kind:           Story_Node_Kind,
	parent:         Form_ID,
	previous:       Form_ID, // the sibling before this one; 0 for the first
	flags:          u32,
	max_concurrent: u32, // XNAM; 0 = no limit
	conditions:     []Condition, // owned
	event:          [4]u8, // an event node's type ("KILL")
	quests:         []Story_Quest, // a quest node's quests, in order (owned)
	quests_to_run:  u32, // MNAM, with STORY_NUM_QUESTS_TO_RUN
	children:       []Form_ID, // in sibling order, built once every plugin is read (owned)
}

// Story_Quest is one quest a quest node can start, and how long before it may start again.
Story_Quest :: struct {
	quest:       Form_ID,
	reset_hours: f32, // RNAM / 24; 0 = no wait
}

@(private)
index_story_node :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	n := Story_Node{kind = .Branch if rec.type == "SMBN" else .Quest if rec.type == "SMQN" else .Event}
	quests := make([dynamic]Story_Quest, db.allocator)
	conds_at := -1
	for f, i in fl {
		switch f.type {
		case "PNAM":
			if v, vok := esm.field_u32(f); vok {n.parent = esm.remap_form(fm, v)}
		case "SNAM":
			if v, vok := esm.field_u32(f); vok {n.previous = esm.remap_form(fm, v)}
		case "CTDA":
			if conds_at < 0 {conds_at = i}
		case "DNAM":
			n.flags, _ = esm.field_u32(f)
		case "XNAM":
			n.max_concurrent, _ = esm.field_u32(f)
		case "MNAM":
			n.quests_to_run, _ = esm.field_u32(f)
		case "ENAM":
			if len(f.data) >= 4 {copy(n.event[:], f.data[:4])}
		case "NNAM":
			if v, vok := esm.field_u32(f); vok {append(&quests, Story_Quest{quest = esm.remap_form(fm, v)})}
		case "RNAM":
			// Stored in hours × 24 (xEdit scales it by 1/24): vanilla's common 576 is a day.
			if raw, fok := esm.field_f32(f); fok && len(quests) > 0 {quests[len(quests) - 1].reset_hours = raw / 24}
		}
	}
	if conds_at >= 0 {n.conditions = index_conditions(db, esm.condition_run(fl, conds_at), fm)}
	n.quests = quests[:]
	if old, existed := db.story_nodes[rec.form_id]; existed {free_story_node(db, old)}
	db.story_nodes[rec.form_id] = n
}

// order_story_nodes gives each node its children, and the tree its roots, in sibling order: each
// chain of previous-sibling links in turn, chains by their first node's form order.
// (hole story-sibling-order :tags (quest records) :sev polish) SNAM is no total order: 7 of 117 vanilla parents have several chains or two nodes after one sibling (DungeonNode, the event root). Chains go by form order; the engine's tie-break is unsourced.
@(private)
order_story_nodes :: proc(db: ^DB) {
	by_parent := make(map[Form_ID][dynamic]Form_ID, 256, context.temp_allocator)
	for form, n in db.story_nodes {
		if n.parent not_in by_parent {by_parent[n.parent] = make([dynamic]Form_ID, context.temp_allocator)}
		append(&by_parent[n.parent], form)
	}
	for parent, &kids in by_parent {
		ordered := sibling_order(db, kids[:])
		if parent == 0 {
			db.story_roots = ordered
		} else if n, ok := &db.story_nodes[parent]; ok {
			n.children = ordered
		} else {
			delete(ordered, db.allocator) // a parent no plugin defines
		}
	}
}

@(private = "file")
sibling_order :: proc(db: ^DB, kids: []Form_ID) -> []Form_ID {
	slice.sort(kids)
	after := make(map[Form_ID][dynamic]Form_ID, len(kids), context.temp_allocator)
	for k in kids {
		prev := db.story_nodes[k].previous
		if !slice.contains(kids, prev) {continue}
		if prev not_in after {after[prev] = make([dynamic]Form_ID, context.temp_allocator)}
		append(&after[prev], k)
	}
	out := make([dynamic]Form_ID, 0, len(kids), db.allocator)
	placed := make(map[Form_ID]bool, len(kids), context.temp_allocator)
	chain :: proc(k: Form_ID, after: map[Form_ID][dynamic]Form_ID, placed: ^map[Form_ID]bool, out: ^[dynamic]Form_ID) {
		if placed[k] {return}
		placed[k] = true
		append(out, k)
		if nexts, ok := after[k]; ok {
			for next in nexts {chain(next, after, placed, out)}
		}
	}
	for k in kids {
		if !slice.contains(kids, db.story_nodes[k].previous) {chain(k, after, &placed, &out)}
	}
	for k in kids {chain(k, after, &placed, &out)} // a loop of siblings
	return out[:]
}

story_node_of :: proc(db: ^DB, form: Form_ID) -> (Story_Node, bool) {
	return db.story_nodes[form]
}

@(private)
free_story_node :: proc(db: ^DB, n: Story_Node) {
	free_conditions(db, n.conditions)
	delete(n.quests, db.allocator)
	delete(n.children, db.allocator)
}

@(private)
free_story_nodes :: proc(db: ^DB) {
	for _, n in db.story_nodes {free_story_node(db, n)}
	delete(db.story_nodes)
	delete(db.story_roots, db.allocator)
}
