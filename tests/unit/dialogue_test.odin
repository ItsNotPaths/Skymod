package unit_tests

import "core:slice"
import "core:testing"
import "../../src/dialogue"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

@(private = "file")
Talk :: struct {
	db: gamedb.DB,
	ws: worldstate.World_State,
	c:  script.Call,
}

@(private = "file")
GLOBAL_EXCLUSIVE, GLOBAL_BLOCKING :: gamedb.Form_ID(0xB01), gamedb.Form_ID(0xB02)

// global_is: GetGlobalValue(global) == 1.
@(private = "file")
global_is :: proc(global: gamedb.Form_ID) -> []gamedb.Condition {
	c := make([]gamedb.Condition, 1, context.temp_allocator)
	c[0] = {function = 74, op = .Equal, value = 1, param1 = u64(global)}
	return c
}

// One quest's dialogue: a Hello said once, two Top-Level topics and one with nothing to say, a line
// whose links hide its Walk Away topic, a Blocking branch of a higher quest, an Exclusive branch,
// and a Random topic that does all before repeating.
@(private = "file")
talk_init :: proc(tk: ^Talk) {
	Q, HIGH :: gamedb.Form_ID(0xC01), gamedb.Form_ID(0xC02)
	tk.db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	tk.db.quest_baseline[Q] = {start_game_enabled = true, priority = 10}
	tk.db.quest_baseline[HIGH] = {start_game_enabled = true, priority = 50}
	tk.db.topics = make(map[gamedb.Form_ID]gamedb.Topic)
	tk.db.branches = make(map[gamedb.Form_ID]gamedb.Branch)
	tk.db.infos = make(map[gamedb.Form_ID]gamedb.Info)

	topic :: proc(db: ^gamedb.DB, id, quest, branch: gamedb.Form_ID, infos: []gamedb.Form_ID, priority: f32 = 50, subtype := "CUST", do_all := false) {
		t := gamedb.Topic{quest = quest, branch = branch, priority = priority, infos = slice.clone(infos, context.temp_allocator), do_all = do_all}
		copy(t.subtype_name[:], subtype)
		db.topics[id] = t
	}
	topic(&tk.db, 0x101, Q, 0, {0x201}, subtype = "HELO")
	tk.db.infos[0x201] = {topic = 0x101, flags = gamedb.INFO_SAY_ONCE}

	tk.db.branches[0x301] = {quest = Q, flags = gamedb.BRANCH_TOP_LEVEL, start = 0x102}
	topic(&tk.db, 0x102, Q, 0x301, {0x202}, priority = 50)
	tk.db.infos[0x202] = {topic = 0x102, prompt = "Ask A", links = slice.clone([]gamedb.Form_ID{0x103, 0x104}, context.temp_allocator), walk_away = 0x104, flags = gamedb.INFO_WALK_AWAY | gamedb.INFO_WALK_AWAY_INVISIBLE}
	topic(&tk.db, 0x103, Q, 0x301, {0x203})
	tk.db.infos[0x203] = {topic = 0x103, prompt = "Go on", reset_hours = 2}
	topic(&tk.db, 0x104, Q, 0x301, {0x204})
	tk.db.infos[0x204] = {topic = 0x104, prompt = "Bye then"}

	tk.db.branches[0x302] = {quest = Q, flags = gamedb.BRANCH_TOP_LEVEL, start = 0x105}
	topic(&tk.db, 0x105, Q, 0x302, {0x205}, priority = 60)
	tk.db.infos[0x205] = {topic = 0x105, prompt = "Ask B"}
	tk.db.branches[0x303] = {quest = Q, flags = gamedb.BRANCH_TOP_LEVEL, start = 0x106}
	topic(&tk.db, 0x106, Q, 0x303, {0x206}, priority = 70)
	tk.db.infos[0x206] = {topic = 0x106, prompt = "Never", conditions = global_is(0xDEAD)}

	tk.db.branches[0x304] = {quest = HIGH, flags = gamedb.BRANCH_BLOCKING, start = 0x107}
	topic(&tk.db, 0x107, HIGH, 0x304, {0x207})
	tk.db.infos[0x207] = {topic = 0x107, conditions = global_is(GLOBAL_BLOCKING)}
	tk.db.branches[0x305] = {quest = Q, flags = gamedb.BRANCH_BLOCKING, start = 0x108}
	topic(&tk.db, 0x108, Q, 0x305, {0x208})
	tk.db.infos[0x208] = {topic = 0x108, conditions = global_is(GLOBAL_BLOCKING)}

	tk.db.branches[0x306] = {quest = Q, flags = gamedb.BRANCH_EXCLUSIVE, start = 0x109}
	topic(&tk.db, 0x109, Q, 0x306, {0x209})
	tk.db.infos[0x209] = {topic = 0x109, conditions = global_is(GLOBAL_EXCLUSIVE)}

	topic(&tk.db, 0x10A, Q, 0, {0x20A, 0x20B, 0x20C}, do_all = true)
	tk.db.infos[0x20A] = {topic = 0x10A, flags = gamedb.INFO_RANDOM}
	tk.db.infos[0x20B] = {topic = 0x10A, flags = gamedb.INFO_RANDOM}
	tk.db.infos[0x20C] = {topic = 0x10A, flags = gamedb.INFO_RANDOM | gamedb.INFO_RANDOM_END}

	worldstate.init(&tk.ws)
	tk.c = {ws = &tk.ws, db = &tk.db}
}

@(private = "file")
talk_destroy :: proc(tk: ^Talk) {
	worldstate.destroy(&tk.ws)
	delete(tk.db.quest_baseline)
	delete(tk.db.topics)
	delete(tk.db.branches)
	delete(tk.db.infos)
}

@(test)
test_dialogue_greeting_and_topics :: proc(t: ^testing.T) {
	tk: Talk
	talk_init(&tk)
	defer talk_destroy(&tk)
	A :: gamedb.Form_ID(0xA01)

	g, ok := dialogue.greeting(&tk.c, A)
	testing.expect(t, ok && g.info == 0x201 && g.blocking == 0, "a Hello")
	dialogue.said(&tk.c, A, 0x201)
	g, ok = dialogue.greeting(&tk.c, A)
	testing.expect(t, ok && g.info == 0, "Say Once: no second Hello")

	topics := dialogue.topics(&tk.c, A)
	if testing.expect_value(t, len(topics), 2) {
		testing.expect(t, topics[0].prompt == "Ask B" && topics[1].prompt == "Ask A", "by topic priority, the silent topic left out")
	}
	links := dialogue.links(&tk.c, A, 0x202)
	testing.expect(t, len(links) == 1 && links[0].info == 0x203, "the hidden Walk Away topic is not a choice")

	dialogue.said(&tk.c, A, 0x203)
	testing.expect_value(t, len(dialogue.links(&tk.c, A, 0x202)), 0)
	worldstate.skip_game_time(&tk.ws, 3)
	testing.expect_value(t, len(dialogue.links(&tk.c, A, 0x202)), 1) // Hours Until Reset passed

	worldstate.set_global(&tk.ws, GLOBAL_BLOCKING, 1)
	g, _ = dialogue.greeting(&tk.c, A)
	testing.expect(t, g.info == 0x207 && g.blocking == 0x304, "the higher quest's Blocking branch wins")
}

@(test)
test_dialogue_exclusive_and_random :: proc(t: ^testing.T) {
	tk: Talk
	talk_init(&tk)
	defer talk_destroy(&tk)
	A :: gamedb.Form_ID(0xA01)

	dialogue.said(&tk.c, A, 0x209)
	testing.expect_value(t, worldstate.exclusive_branch(&tk.ws, A), 0x306)
	_, ok := dialogue.greeting(&tk.c, A)
	testing.expect(t, !ok, "in an Exclusive branch with nothing to say: no conversation")
	worldstate.set_global(&tk.ws, GLOBAL_EXCLUSIVE, 1)
	g, gok := dialogue.greeting(&tk.c, A)
	testing.expect(t, gok && g.info == 0x209 && g.blocking == 0x306, "the Exclusive branch greets")
	dialogue.said(&tk.c, A, 0x202)
	testing.expect_value(t, worldstate.exclusive_branch(&tk.ws, A), 0) // a line from another branch

	seen: map[gamedb.Form_ID]bool
	defer delete(seen)
	for _ in 0 ..< 3 {
		info := dialogue.pick(&tk.c, A, 0x10A)
		dialogue.said(&tk.c, A, info)
		seen[info] = true
	}
	testing.expect_value(t, len(seen), 3) // Do All Before Repeating
	testing.expect(t, dialogue.pick(&tk.c, A, 0x10A) != 0, "then a new round")

	testing.expect(t, len(tk.ws.info_runs) > 0 && !tk.ws.info_runs[0].end, "a said line queues its begin fragment")
	dialogue.finished(&tk.c, A, 0x202)
	testing.expect(t, tk.ws.info_runs[len(tk.ws.info_runs) - 1].end, "and its end one")
}
