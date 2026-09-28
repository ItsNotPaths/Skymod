package main

// The dialogue placeholder: an ImGui window with the speaker's subtitle and the player's choices.
// The rules live in the dialogue package; this file runs one conversation through them in the sim
// (tick_dialogue, the Cmd_Talk_* commands) and draws it on main from the snapshot's Talk_View. The
// world keeps running while it is open, as in Skyrim.

import "core:fmt"
import "core:log"
import "core:slice"
import imgui "../../vendor/odin-imgui"
import "../audio"
import "../dialogue"
import "../gamedb"
import "../script"
import "../worldstate"


// The topic list takes milliseconds to build, so it is rebuilt this often, not every frame: often
// enough to show what an end fragment's stage opened.
LIST_REFRESH_TICKS :: 15

Conversation :: struct {
	speaker:   Form_ID,
	info:      Form_ID, // the line being said; 0 while the player chooses
	response:  int, // which of its responses shows
	left_s:    f32, // how long that response stays up
	blocking:  Form_ID, // the Blocking or Exclusive branch the greeting came from
	greeting:  bool, // the line is the greeting
	last:      bool, // the conversation ends after this line
	choices:   [dynamic]dialogue.Choice, // the choices on screen
	walk_away: Form_ID, // the topic said when the player backs out of `choices`
	top_level: bool, // `choices` is the speaker's topic list
	listed_at: u64, // the tick it was built at
}

// open_dialogue starts a conversation with an actor the player activated. Actors without a name
// cannot be spoken to (CK Dialogue), nor one a script barred (AllowPCDialogue), nor a scene actor
// flagged No Player Activation (CK Scenes Tab).
open_dialogue :: proc(g: ^Game, speaker: Form_ID) {
	if worldstate.display_name(&g.sim.ws, &g.db, speaker) == "" || worldstate.is_dead(&g.sim.ws, &g.db, speaker) || speaker in g.sim.ws.no_pc_dialogue {return}
	if busy_in_scene(g, speaker) {
		log.infof("%s is busy", worldstate.display_name(&g.sim.ws, &g.db, speaker))
		return
	}
	start_dialogue(g, speaker)
}

// tick_force_greet asks main to open the conversation an NPC's ForceGreet asked for, once no menu
// or conversation is open. The slot stays set until then: the AI reads it as the greet pending.
tick_force_greet :: proc(g: ^Game) {
	fg := g.sim.ws.force_greet
	if fg.speaker == 0 || g.sim.input.in_menu || g.sim.ws.talking != 0 {return}
	g.sim.ws.force_greet = {}
	if !worldstate.is_dead(&g.sim.ws, &g.db, fg.speaker) {start_dialogue(g, fg.speaker, fg.topic, fg.subtype)}
}

// start_dialogue opens the conversation with the speaker's greeting, or its line for `topic`, or
// for `subtype`.
start_dialogue :: proc(g: ^Game, speaker: Form_ID, topic: Form_ID = 0, subtype := "") {
	g.sim.ws.talking = speaker // Hellos ask IsInDialogueWithPlayer
	c := dialogue_call(g)
	greet, ok := dialogue.Greeting{info = dialogue.pick(&c, speaker, topic)}, true
	if subtype != "" {
		greet.info = dialogue.pick_subtype(&c, speaker, subtype)
		ok = greet.info != 0
	} else if topic == 0 {greet, ok = dialogue.greeting(&c, speaker)}
	if !ok {
		g.sim.ws.talking = 0
		return
	}
	clear(&g.sim.talk.choices)
	g.sim.talk.speaker, g.sim.talk.blocking, g.sim.talk.walk_away = speaker, greet.blocking, 0
	if greet.info != 0 {say(g, greet.info, greeting = true)} else {list_topics(g)}
}

// tick_dialogue runs the conversation's time: the showing response's countdown, the topic list's
// refresh, and the end when the speaker dies.
tick_dialogue :: proc(g: ^Game) {
	t := &g.sim.talk
	if t.speaker == 0 {return}
	if worldstate.is_dead(&g.sim.ws, &g.db, t.speaker) {
		close_dialogue(g)
		return
	}
	if t.info != 0 {
		t.left_s -= TICK_DT
		if t.left_s <= 0 {next_response(g)}
	} else if t.top_level && g.sim.clock.total - t.listed_at >= LIST_REFRESH_TICKS {
		list_topics(g)
	}
}

// talk_next skips the response the player saw, if it still shows.
talk_next :: proc(g: ^Game, c: Cmd_Talk_Next) {
	if g.sim.talk.speaker != 0 && g.sim.talk.info == c.info && g.sim.talk.response == c.response {next_response(g)}
}

// talk_choose says the line for a choice the player picked, if it is still on offer.
talk_choose :: proc(g: ^Game, ch: dialogue.Choice) {
	t := &g.sim.talk
	if t.speaker == 0 || t.info != 0 || !slice.contains(t.choices[:], ch) {return}
	c := dialogue_call(g)
	info := ch.info if dialogue.still_valid(&c, t.speaker, ch.info) else dialogue.pick(&c, t.speaker, ch.topic) // the line shown
	if info != 0 {say(g, info)}
}

// Talk_View is the conversation as main draws it.
Talk_View :: struct {
	speaker:  Form_ID, // 0 = no conversation
	name:     Text_Span,
	info:     Form_ID, // the line showing, 0 while the player chooses
	response: int,
	line:     Text_Span,
	choices:  [dynamic]Talk_Choice,
}

Talk_Choice :: struct {
	choice: dialogue.Choice,
	prompt: Text_Span,
}

view_talk :: proc(g: ^Game, s: ^Snapshot) {
	t, v := &g.sim.talk, &s.talk
	clear(&v.choices)
	v.speaker, v.info, v.response = t.speaker, t.info, t.response
	if t.speaker == 0 {return}
	c := dialogue_call(g)
	v.name = add_text(s, worldstate.display_name(&g.sim.ws, &g.db, t.speaker))
	if t.info != 0 {
		v.line = add_text(s, dialogue.line_text(&c, t.info, t.response))
		return
	}
	for ch in t.choices {append(&v.choices, Talk_Choice{ch, add_text(s, dialogue.prompt(&c, ch.info))})}
}

// dialogue_menu draws the conversation: the subtitle while a line plays, else the choices.
dialogue_menu :: proc(g: ^Game) {
	v := &g.snap.talk
	imgui.TextUnformatted(fmt.ctprintf("%s", text(&g.snap, v.name)))
	imgui.Separator()
	if v.info != 0 {
		imgui.TextWrapped(fmt.ctprintf("%s", text(&g.snap, v.line)))
		if imgui.Button("Next") {push(&g.commands, Cmd_Talk_Next{v.info, v.response})}
		return
	}
	for ch, i in v.choices {
		if imgui.Button(fmt.ctprintf("%s##%d", text(&g.snap, ch.prompt), i)) {
			push(&g.commands, Cmd_Talk_Choose{ch.choice})
			return
		}
	}
	if imgui.Button("(leave)") {push(&g.commands, Cmd_Talk_Leave{})}
}

// sync_dialogue_menu keeps the dialogue menu open exactly while the sim has a conversation.
sync_dialogue_menu :: proc(g: ^Game) {
	if g.snap.talk.speaker != 0 && g.menu == .None {
		g.menu = .Dialogue
	} else if g.snap.talk.speaker == 0 && g.menu == .Dialogue {
		g.menu = .None
	}
}

// back_out is the player leaving: the Walk Away line of the choices on screen plays as it ends.
back_out :: proc(g: ^Game) {
	t := &g.sim.talk
	if t.info == 0 && t.walk_away != 0 {
		c := dialogue_call(g)
		if info := dialogue.pick(&c, t.speaker, t.walk_away); info != 0 {
			say(g, info, last = true)
			return
		}
	}
	close_dialogue(g)
}

close_dialogue :: proc(g: ^Game) {
	if g.sim.talk.info != 0 {
		c := dialogue_call(g)
		dialogue.finished(&c, g.sim.talk.speaker, g.sim.talk.info)
	}
	g.sim.talk.info, g.sim.talk.speaker = 0, 0
	g.sim.ws.talking = 0
}

@(private = "file")
say :: proc(g: ^Game, info: Form_ID, greeting := false, last := false) {
	t := &g.sim.talk
	c := dialogue_call(g)
	dialogue.said(&c, t.speaker, info)
	worldstate.set_talked_to_pc(&g.sim.ws, t.speaker)
	clear(&t.choices)
	t.info, t.response, t.greeting, t.last = info, -1, greeting, last
	t.walk_away, t.top_level = 0, false
	next_response(g)
}

// list_topics shows the speaker's topic list.
@(private = "file")
list_topics :: proc(g: ^Game) {
	t := &g.sim.talk
	c := dialogue_call(g)
	shown := dialogue.topics(&c, t.speaker, t.choices[:] if t.top_level else nil)
	clear(&t.choices)
	append(&t.choices, ..shown)
	t.top_level, t.listed_at = true, g.sim.clock.total
}

// next_response shows the line's next response; past the last one the line is done.
@(private = "file")
next_response :: proc(g: ^Game) {
	t := &g.sim.talk
	t.response += 1
	lines := dialogue.responses(&g.db, t.info)
	if t.response < len(lines) {
		t.left_s = dialogue.line_seconds(lines[t.response].text)
		if h, secs := audio.say(&g.audio, &g.v, &g.db, &g.sim.ws, t.speaker, t.info, lines[t.response].number, placed = false); h != 0 {
			t.left_s = secs
		}
		return
	}
	line_done(g)
}

// line_done follows a finished line (CK Topic Info, Link To): Goodbye ends the conversation,
// Invisible Continue says the linked topic, else the links become the choices. A greeting from a
// Blocking branch with no links offers its starting topic; any other line with none goes back to
// the topic list.
@(private = "file")
line_done :: proc(g: ^Game) {
	t := &g.sim.talk
	c := dialogue_call(g)
	id := t.info
	info := g.db.infos[id]
	dialogue.finished(&c, t.speaker, id)
	t.info = 0
	if t.last || info.flags & gamedb.INFO_GOODBYE != 0 {
		close_dialogue(g)
		return
	}
	if info.flags & gamedb.INFO_INVISIBLE_CONTINUE != 0 && len(info.links) > 0 {
		if next := dialogue.pick(&c, t.speaker, info.links[0]); next != 0 {
			say(g, next)
			return
		}
	}
	append(&t.choices, ..dialogue.links(&c, t.speaker, id))
	t.walk_away = info.walk_away if info.flags & gamedb.INFO_WALK_AWAY != 0 else 0
	if len(t.choices) == 0 && t.greeting && t.blocking != 0 {
		if ch, ok := dialogue.choice(&c, t.speaker, g.db.branches[t.blocking].start); ok {append(&t.choices, ch)}
	}
	if len(t.choices) == 0 {list_topics(g)}
}

// (hole scene-subtitles :tags (ui dialogue) :sev gap) scene lines show in an ImGui box for every speaker in an attached cell, however far away; Skyrim shows them near the player unless the line forces its subtitle, and the real screen is dialogue-screen.
// view_subtitles fills the snapshot with the lines scenes and barks are saying now.
view_subtitles :: proc(g: ^Game, s: ^Snapshot) {
	clear(&s.subtitles)
	subtitle :: proc(g: ^Game, s: ^Snapshot, speaker, info: Form_ID, response: i32) {
		if info == 0 || worldstate.ref_grid_cell(&g.sim.ws, &g.db, speaker) not_in g.sim.ws.attached {return}
		c := dialogue_call(g)
		if line := dialogue.line_text(&c, info, int(response)); line != "" {
			append(&s.subtitles, add_text(s, fmt.tprintf("%s: %s", worldstate.display_name(&g.sim.ws, &g.db, speaker), line)))
		}
	}
	for _, run in g.sim.ws.scenes {
		for a in run.actions {subtitle(g, s, a.speaker, a.info, a.response)}
	}
	for b in g.sim.ws.barks {subtitle(g, s, b.speaker, b.info, b.response)}
}

// frame_subtitles shows the snapshot's subtitle lines.
frame_subtitles :: proc(g: ^Game) {
	if len(g.snap.subtitles) == 0 {return}
	w, h := ui_screen_size()
	imgui.SetNextWindowPos({w * 0.5, h - 40}, .Always, {0.5, 1})
	if imgui.Begin("Subtitles (placeholder)", nil, {.NoTitleBar, .NoResize, .NoMove, .AlwaysAutoResize, .NoMouseInputs, .NoNavInputs, .NoFocusOnAppearing}) {
		for l in g.snap.subtitles {imgui.TextUnformatted(fmt.ctprintf("%s", text(&g.snap, l)))}
	}
	imgui.End()
}

@(private = "file")
busy_in_scene :: proc(g: ^Game, actor: Form_ID) -> bool {
	scene := worldstate.scene_of_actor(&g.sim.ws, &g.db, actor)
	if scene == 0 {return false}
	s := g.db.scenes[scene]
	for a in s.actors {
		if worldstate.alias_ref(&g.sim.ws, s.quest, a.alias) == actor {return a.flags & gamedb.SCENE_ACTOR_NO_PLAYER_ACTIVATION != 0}
	}
	return false
}

// dialogue_call is a script call with the VM's quest variables, which GetVMQuestVariable reads.
@(private = "file")
dialogue_call :: proc(g: ^Game) -> script.Call {
	if g.repl_ok {return g.sim.repl.vm.ctx}
	return {ws = &g.sim.ws, db = &g.db}
}
