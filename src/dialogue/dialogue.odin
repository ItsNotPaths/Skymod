package dialogue

// Player dialogue as the CK wiki describes it (build/out/wsQ/wiki: Topic, Topic Info, Dialogue
// Branch): a branch starts a topic, a topic offers the first of its infos that can be said, and an
// info's links are the choices after it. The app drives a conversation through these procs; what
// dialogue remembers lives in worldstate (dialogue.odin there).

import "core:math/rand"
import "core:slice"
import "../conditions"
import "../formid"
import "../gamedb"
// (hole dialogue-script-coupling :tags (plugins dialogue script) :sev struct) dialogue builds a script.Call to run natives and uses script.condition_context, so it imports the script runtime. Investigate whether it needs more than the condition context.
import "../script"
import "../worldstate"

Form_ID :: gamedb.Form_ID

// A line with no voice stays up for its length in characters, at least LINE_MIN_S.
LINE_MIN_S :: f32(2)
LINE_S_PER_CHAR :: f32(0.06)

line_seconds :: proc(text: string) -> f32 {
	return max(LINE_MIN_S, f32(len(text)) * LINE_S_PER_CHAR)
}

// Choice is a topic the player can pick, with the info it plays now. Its text is prompt(info),
// built each frame: tags fill into temp memory.
Choice :: struct {
	topic, info: Form_ID,
}

// Greeting is what the speaker says when the player starts talking. `blocking` is its Blocking or
// Exclusive branch; `info` is 0 when there is nothing to say and the topic list shows at once.
Greeting :: struct {
	info:     Form_ID,
	blocking: Form_ID,
}

// greeting picks the speaker's opening line: its Exclusive branch, else the best valid Blocking
// branch (the higher quest priority wins, then load order), else a Hello. ok=false: the speaker is
// in an Exclusive branch with nothing to say, and the conversation does not open (user decision;
// in vanilla that NPC blocks all dialogue).
greeting :: proc(c: ^script.Call, speaker: Form_ID) -> (g: Greeting, ok: bool) {
	if branch := worldstate.exclusive_branch(c.ws, speaker); branch != 0 {
		b := c.db.branches[branch]
		info := pick(c, speaker, b.start)
		return {info, branch}, info != 0
	}
	best_priority := -1
	for branch in sorted_keys(c.db.branches) {
		b := c.db.branches[branch]
		if b.flags & gamedb.BRANCH_BLOCKING == 0 {continue}
		info := pick(c, speaker, b.start)
		if info == 0 {continue}
		qb, _ := gamedb.quest_baseline_of(c.db, b.quest)
		if int(qb.priority) > best_priority {
			g, best_priority = {info, branch}, int(qb.priority)
		}
	}
	if g.info == 0 {g.info = pick_from(c, speaker, stack(c.db, "HELO"), false)}
	return g, true
}

// topics is the speaker's topic list: the starting topic of each Top-Level branch with a line
// this speaker can say, by topic priority. The Rumors topics are one stack, so one choice. A topic
// in `shown` keeps the line it offered while that line can still be said, so a Random topic does
// not change under the player.
topics :: proc(c: ^script.Call, speaker: Form_ID, shown: []Choice = nil) -> []Choice {
	out := make([dynamic]Choice, context.temp_allocator)
	rumors := false
	for branch in sorted_keys(c.db.branches) {
		b := c.db.branches[branch]
		if b.flags & gamedb.BRANCH_TOP_LEVEL == 0 || b.category != 0 {continue}
		if is_subtype(c.db.topics[b.start], "RUMO") {
			if rumors {continue}
			rumors = true
		}
		if ch, ok := kept(c, speaker, b.start, shown); ok {
			append(&out, ch)
		} else if ch, ok = choice(c, speaker, b.start); ok {
			append(&out, ch)
		}
	}
	context.user_ptr = c.db
	slice.stable_sort_by(out[:], proc(a, b: Choice) -> bool {
		db := (^gamedb.DB)(context.user_ptr)
		return db.topics[a.topic].priority > db.topics[b.topic].priority
	})
	return out[:]
}

// links are the choices after `info`: its linked topics with a line this speaker can say. The
// Walk Away topic is left out when the info hides it.
links :: proc(c: ^script.Call, speaker, info: Form_ID) -> []Choice {
	i := c.db.infos[info]
	out := make([dynamic]Choice, context.temp_allocator)
	for topic in i.links {
		if topic == i.walk_away && i.flags & gamedb.INFO_WALK_AWAY_INVISIBLE != 0 {continue}
		if ch, ok := choice(c, speaker, topic); ok {append(&out, ch)}
	}
	return out[:]
}

// choice is a topic as the player sees it, when the speaker has a line in it.
choice :: proc(c: ^script.Call, speaker, topic: Form_ID) -> (Choice, bool) {
	info := pick(c, speaker, topic)
	if info == 0 {return {}, false}
	return {topic, info}, true
}

@(private = "file")
kept :: proc(c: ^script.Call, speaker, topic: Form_ID, shown: []Choice) -> (Choice, bool) {
	for ch in shown {
		if ch.topic == topic && still_valid(c, speaker, ch.info) {return ch, true}
	}
	return {}, false
}

// still_valid: `speaker` can say `info` now.
still_valid :: proc(c: ^script.Call, speaker, info: Form_ID) -> bool {
	i, ok := c.db.infos[info]
	return ok && can_say(c, speaker, info, i)
}

// pick is the info `speaker` says for `topic`, or 0. A Rumors topic draws on every Rumors topic.
pick :: proc(c: ^script.Call, speaker, topic: Form_ID) -> Form_ID {
	t, ok := c.db.topics[topic]
	if !ok {return 0}
	infos := stack(c.db, "RUMO") if is_subtype(t, "RUMO") else t.infos
	return pick_from(c, speaker, infos, t.do_all)
}

// pick_from walks an info stack top down and takes the first info that can be said. A Random one
// starts a pile that grows until a valid info that is not Random, or is Random End; one of the pile
// is said. With Do All Before Repeating, the pile skips what was said this round.
@(private)
pick_from :: proc(c: ^script.Call, speaker: Form_ID, infos: []Form_ID, do_all: bool, to := formid.PLAYER) -> Form_ID {
	pile := make([dynamic]Form_ID, context.temp_allocator)
	for id in infos {
		info := c.db.infos[id]
		if !can_say(c, speaker, id, info, to) {continue}
		append(&pile, id)
		if info.flags & gamedb.INFO_RANDOM == 0 || info.flags & gamedb.INFO_RANDOM_END != 0 {break}
	}
	if len(pile) <= 1 {return pile[0] if len(pile) == 1 else 0}
	if do_all {
		fresh := make([dynamic]Form_ID, context.temp_allocator)
		for id in pile {if !worldstate.random_said(c.ws, speaker, id) {append(&fresh, id)}}
		if len(fresh) == 0 {
			for id in pile {worldstate.set_random_said(c.ws, speaker, id, false)}
		} else {
			pile = fresh
		}
	}
	return rand.choice(pile[:])
}

// can_say: the info's quest runs, its quest's dialogue conditions and its own pass, and Say Once
// and Hours Until Reset allow it.
@(private)
can_say :: proc(c: ^script.Call, speaker, id: Form_ID, info: gamedb.Info, to := formid.PLAYER) -> bool {
	quest := c.db.topics[info.topic].quest
	if quest != 0 && !worldstate.quest_running(c.ws, c.db, quest) {return false}
	if at, said := worldstate.info_said_at(c.ws, speaker, id); said {
		if info.flags & gamedb.INFO_SAY_ONCE != 0 {return false}
		if f64(info.reset_hours) > c.ws.clock.hours - at {return false}
	}
	ctx := script.condition_context(c, speaker, to, quest)
	qb, _ := gamedb.quest_baseline_of(c.db, quest)
	return conditions.all(&ctx, qb.dialogue_conditions) && conditions.all(&ctx, info.conditions)
}

// said records that `speaker` says `info` now and queues its begin fragment. A line from an
// Exclusive branch puts the speaker in it; a line from another branch takes it out.
said :: proc(c: ^script.Call, speaker, info: Form_ID) {
	worldstate.info_said(c.ws, speaker, info)
	i := c.db.infos[info]
	t := c.db.topics[i.topic]
	if t.do_all && i.flags & gamedb.INFO_RANDOM != 0 {worldstate.set_random_said(c.ws, speaker, info, true)}
	if t.branch != 0 {
		exclusive := c.db.branches[t.branch].flags & gamedb.BRANCH_EXCLUSIVE != 0
		worldstate.set_exclusive_branch(c.ws, speaker, t.branch if exclusive else 0)
	}
	append(&c.ws.info_runs, worldstate.Info_Run{info = info, speaker = speaker})
}

// finished queues the end fragment of a line whose last response is done.
finished :: proc(c: ^script.Call, speaker, info: Form_ID) {
	append(&c.ws.info_runs, worldstate.Info_Run{info = info, speaker = speaker, end = true})
}

// responses are the lines of an info, or of the SharedInfo it takes them from.
responses :: proc(db: ^gamedb.DB, info: Form_ID) -> []gamedb.Response {
	i := db.infos[info]
	if i.shared != 0 {return db.infos[i.shared].responses}
	return i.responses
}

// prompt is what the player says to reach `info`: its own prompt, else its topic's text, tags
// filled in. A Rumors info with neither says the game setting's line.
prompt :: proc(c: ^script.Call, info: Form_ID) -> string {
	i := c.db.infos[info]
	raw := i.prompt
	if raw == "" {raw = gamedb.name_of(c.db, i.topic)}
	if raw == "" && is_subtype(c.db.topics[i.topic], "RUMO") {raw = "Heard any rumors lately?"} // sTopicSubtypeTextPlayerDialogueRumors
	return worldstate.fill_tags(c.ws, c.db, raw, c.db.topics[i.topic].quest)
}

// line_text is response `n` of `info` as shown, tags filled in; "" past its last.
line_text :: proc(c: ^script.Call, info: Form_ID, n: int) -> string {
	lines := responses(c.db, info)
	if n < 0 || n >= len(lines) {return ""}
	return worldstate.fill_tags(c.ws, c.db, lines[n].text, c.db.topics[c.db.infos[info].topic].quest)
}

// pick_subtype is the line `speaker` says to `to` from every topic of one subtype (Hellos, Idle); 0
// when none.
pick_subtype :: proc(c: ^script.Call, speaker: Form_ID, subtype: string, to := formid.PLAYER) -> Form_ID {
	return pick_from(c, speaker, stack(c.db, subtype), false, to)
}

// stack joins the infos of every topic of one subtype (Hellos, Rumors), which stack across
// quests: the higher quest priority first, then load order.
@(private)
stack :: proc(db: ^gamedb.DB, subtype: string) -> []Form_ID {
	topics := make([dynamic]Form_ID, context.temp_allocator)
	for id, t in db.topics {
		if is_subtype(t, subtype) {append(&topics, id)}
	}
	context.user_ptr = db
	slice.sort_by(topics[:], proc(a, b: Form_ID) -> bool {
		db := (^gamedb.DB)(context.user_ptr)
		pa, _ := gamedb.quest_baseline_of(db, db.topics[a].quest)
		pb, _ := gamedb.quest_baseline_of(db, db.topics[b].quest)
		return pa.priority > pb.priority if pa.priority != pb.priority else a < b
	})
	out := make([dynamic]Form_ID, context.temp_allocator)
	for t in topics {append(&out, ..db.topics[t].infos)}
	return out[:]
}

@(private)
is_subtype :: proc(t: gamedb.Topic, subtype: string) -> bool {
	t := t
	return string(t.subtype_name[:]) == subtype
}

@(private)
sorted_keys :: proc(m: map[Form_ID]$V) -> []Form_ID {
	keys := make([dynamic]Form_ID, 0, len(m), context.temp_allocator)
	for k in m {append(&keys, k)}
	slice.sort(keys[:])
	return keys[:]
}
