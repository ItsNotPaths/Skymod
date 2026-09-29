package script

// The story manager (CK wiki: Story Manager, SM Event Node). An event walks the tree from its SMEN
// node. A node whose conditions fail is skipped with its children; a Stacked node tries its children
// top to bottom, a Random one in random order. A quest node starts one of its quests (or up to Num
// Quests To Run), each gated by its own Story Manager conditions and Hours Until Reset. Starting a
// quest consumes the event unless the node Shares Event.

import "core:log"
import "core:math/rand"
import "core:time"
import "../conditions"
import "../formid"
import "../gamedb"
import "../worldstate"

// Script events come through the natives below. Engine events queue in ws.story_events and the
// script tick runs them; each event family is its own story-* hole at the site the event happens.

Story_Event :: worldstate.Story_Event

// story_event runs one event through the story manager tree; true when it started a quest.
story_event :: proc(c: ^Call, e: Story_Event) -> bool {
	e := e
	started := 0
	for root in c.db.story_roots {
		if walk(c, root, &e, &started) {break}
	}
	return started > 0
}

// walk processes one node; true when the event is consumed.
@(private = "file")
walk :: proc(c: ^Call, form: Form_ID, e: ^Story_Event, started: ^int) -> bool {
	n, ok := gamedb.story_node_of(c.db, form)
	if !ok || (n.kind == .Event && n.event != e.type) {return false}
	ctx := condition_context(c, c.ws.player, 0)
	ctx.event = e
	if !conditions.all(&ctx, n.conditions) {return false}
	if n.kind == .Quest {
		k := start_from_node(c, form, n, e)
		started^ += k
		return k > 0 && n.flags & gamedb.STORY_SHARES_EVENT == 0
	}
	children := slice_clone_temp(n.children)
	if n.flags & gamedb.STORY_RANDOM != 0 {rand.shuffle(children)}
	for child in children {
		if walk(c, child, e, started) {return true}
	}
	return false
}

// SLOW_STORY_MS is a quest start attempt that gets logged.
SLOW_STORY_MS :: 5

// start_from_node starts up to the node's count of its quests; returns how many started.
@(private = "file")
start_from_node :: proc(c: ^Call, node: Form_ID, n: gamedb.Story_Node, e: ^Story_Event) -> int {
	want := int(n.quests_to_run) if n.flags & gamedb.STORY_NUM_QUESTS_TO_RUN != 0 else 1
	if n.max_concurrent > 0 {
		running := 0
		for q in n.quests {
			if worldstate.quest_running(c.ws, c.db, q.quest) {running += 1}
		}
		want = min(want, int(n.max_concurrent) - running)
	}
	started := 0
	for q in pick_order(c, node, n) {
		if started >= want {break}
		t := time.tick_now()
		ok := may_start(c, q, e) && start_quest(c, q.quest, e)
		if ms := time.duration_milliseconds(time.tick_since(t)); ms > SLOW_STORY_MS {
			log.warnf("story: %s event, quest 0x%08X took %.1fms (started=%v)", string(e.type[:]), q.quest, ms, ok)
		}
		if !ok {continue}
		c.ws.story_ran[{node, q.quest}] = true
		c.ws.story_starts[q.quest] = c.ws.clock.hours
		started += 1
	}
	return started
}

// pick_order is the order a quest node tries its quests: authored (Stacked) or shuffled (Random),
// with the quests that ran this round moved last. When every quest has run, a new round starts.
// (hole story-random-rounds :tags quest :sev polish) NOT VANILLA (user choice 2026-09-26): every Random quest node runs in rounds as if Do All Before Repeating were set, not only the 128 of 197 that set it. It may starve a quest vanilla would pick again, or break a node built to repeat one quest; watch radiant quests.
@(private = "file")
pick_order :: proc(c: ^Call, node: Form_ID, n: gamedb.Story_Node) -> []gamedb.Story_Quest {
	order := slice_clone_temp(n.quests)
	random := n.flags & gamedb.STORY_RANDOM != 0
	if random {rand.shuffle(order)}
	if !random && n.flags & gamedb.STORY_DO_ALL_BEFORE_REPEATING == 0 {return order}
	fresh := make([dynamic]gamedb.Story_Quest, 0, len(order), context.temp_allocator)
	ran := make([dynamic]gamedb.Story_Quest, 0, len(order), context.temp_allocator)
	for q in order {
		append(&ran if c.ws.story_ran[{node, q.quest}] else &fresh, q)
	}
	if len(fresh) == 0 {
		for q in order {delete_key(&c.ws.story_ran, [2]Form_ID{node, q.quest})}
	}
	append(&fresh, ..ran[:])
	return fresh[:]
}

// may_start: the quest is past its Hours Until Reset and its Story Manager conditions pass.
@(private = "file")
may_start :: proc(c: ^Call, q: gamedb.Story_Quest, e: ^Story_Event) -> bool {
	if last, ok := c.ws.story_starts[q.quest]; ok && q.reset_hours > 0 && c.ws.clock.hours - last < f64(q.reset_hours) {
		return false
	}
	qb, _ := gamedb.quest_baseline_of(c.db, q.quest)
	ctx := condition_context(c, c.ws.player, 0, q.quest)
	ctx.event = e
	return conditions.all(&ctx, qb.event_conditions)
}

// start_quest starts a quest the way Quest.Start and the story manager both do: its aliases fill in
// order, and a required alias that cannot fill fails the start; then it resets, unless Run Once.
// `event` is the story event that started it; the quest keeps it for its handlers, aliases and
// conditions. False when the quest runs already or cannot start.
start_quest :: proc(c: ^Call, quest: Form_ID, event: ^Story_Event = nil) -> bool {
	if worldstate.quest_running(c.ws, c.db, quest) {return false}
	if event != nil {c.ws.quest_events[quest] = event^}
	worldstate.quest_set_running(c.ws, quest, true)
	if !fill_aliases(c, quest) {
		worldstate.quest_set_running(c.ws, quest, false)
		clear_aliases(c, quest)
		return false
	}
	if event != nil {append(&c.ws.story_quests, quest)}
	if reset_quest(c, quest) {worldstate.quest_set_running(c.ws, quest, true)}
	queue_stages(c, quest, gamedb.STAGE_START_UP)
	start_quest_scenes(c, quest)
	return true
}

@(private = "file")
slice_clone_temp :: proc(s: []$T) -> []T {
	out := make([]T, len(s), context.temp_allocator)
	copy(out, s)
	return out
}

register_story :: proc(reg: ^Registry) {
	register(reg, "Keyword", "SendStoryEvent", n_send_story_event)
	register(reg, "Keyword", "SendStoryEventAndWait", n_send_story_event_and_wait)
}

// Keyword.SendStoryEvent(akLoc, akRef1, akRef2, aiValue1, aiValue2): `self` is the event keyword.
n_send_story_event :: proc(c: ^Call, args: []Value) -> Value {
	story_event(c, event_of(c, args))
	return nil
}

// SendStoryEventAndWait answers at once in this engine (script-api.md section 4).
n_send_story_event_and_wait :: proc(c: ^Call, args: []Value) -> Value {
	return story_event(c, event_of(c, args))
}

@(private = "file")
event_of :: proc(c: ^Call, args: []Value) -> Story_Event {
	return {
		type      = worldstate.STORY_SCRIPT,
		keyword   = c.self,
		location1 = arg_form(c, args, 0),
		ref1      = arg_form(c, args, 1),
		ref2      = arg_form(c, args, 2),
		value1    = max(arg_i32(args, 3, 0), 0), // a negative value arrives as 0 (CK wiki)
		value2    = max(arg_i32(args, 4, 0), 0),
	}
}
