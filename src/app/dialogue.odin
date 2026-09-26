package main

// The dialogue placeholder: an ImGui window with the speaker's subtitle and the player's choices.
// The rules live in the dialogue package; this file only runs one conversation through them. The
// world keeps running while it is open, as in Skyrim.

import "core:fmt"
import "core:log"
import imgui "../../vendor/odin-imgui"
import "../dialogue"
import "../gamedb"
import "../script"
import "../worldstate"

// (hole dialogue-barks :tags (dialogue ai) :sev gap :needs (ai-agent)) NPCs say nothing unless the player starts a conversation: no Hello as the player passes, no idle chatter, no combat or detection lines (HELO, IDLE, combat and detection topics).
// (hole force-greet :tags (dialogue ai quest) :sev gap :needs (ai-agent)) no ForceGreet package walks an NPC to the player to start a conversation, so a quest that waits for one stalls until the player talks to that NPC.

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
	if worldstate.display_name(&g.ws, &g.db, speaker) == "" || worldstate.is_dead(&g.ws, speaker) || speaker in g.ws.no_pc_dialogue {return}
	if busy_in_scene(g, speaker) {
		log.infof("%s is busy", worldstate.display_name(&g.ws, &g.db, speaker))
		return
	}
	g.ws.talking = speaker // Hellos ask IsInDialogueWithPlayer
	c := dialogue_call(g)
	greet, ok := dialogue.greeting(&c, speaker)
	if !ok {
		g.ws.talking = 0
		return
	}
	g.menu = .Dialogue
	clear(&g.talk.choices)
	g.talk.speaker, g.talk.blocking, g.talk.walk_away = speaker, greet.blocking, 0
	if greet.info != 0 {say(g, greet.info, greeting = true)} else {list_topics(g)}
}

// dialogue_menu draws the conversation: the subtitle while a line plays, else the choices.
dialogue_menu :: proc(g: ^Game) {
	t := &g.talk
	imgui.TextUnformatted(fmt.ctprintf("%s", worldstate.display_name(&g.ws, &g.db, t.speaker)))
	imgui.Separator()
	if t.info != 0 {
		lines := dialogue.responses(&g.db, t.info)
		if t.response < len(lines) {imgui.TextWrapped(fmt.ctprintf("%s", lines[t.response].text))}
		t.left_s -= g.p.dt
		if imgui.Button("Next") {t.left_s = 0}
		if t.left_s <= 0 {next_response(g)}
		return
	}
	if t.top_level && g.tick.total - t.listed_at >= LIST_REFRESH_TICKS {list_topics(g)}
	for ch, i in t.choices {
		if !imgui.Button(fmt.ctprintf("%s##%d", ch.prompt, i)) {continue}
		c := dialogue_call(g)
		info := dialogue.pick(&c, t.speaker, ch.topic) // a Random topic picks again
		say(g, info if info != 0 else ch.info)
		return
	}
	if imgui.Button("(leave)") {back_out(g)}
}

// back_out is the player leaving: the Walk Away line of the choices on screen plays as it ends.
back_out :: proc(g: ^Game) {
	t := &g.talk
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
	if g.talk.info != 0 {
		c := dialogue_call(g)
		dialogue.finished(&c, g.talk.speaker, g.talk.info)
	}
	g.talk.info = 0
	g.ws.talking = 0
	if g.menu == .Dialogue {g.menu = .None}
}

@(private = "file")
say :: proc(g: ^Game, info: Form_ID, greeting := false, last := false) {
	t := &g.talk
	c := dialogue_call(g)
	dialogue.said(&c, t.speaker, info)
	worldstate.set_talked_to_pc(&g.ws, t.speaker)
	clear(&t.choices)
	t.info, t.response, t.greeting, t.last = info, -1, greeting, last
	t.walk_away, t.top_level = 0, false
	next_response(g)
}

// list_topics shows the speaker's topic list.
@(private = "file")
list_topics :: proc(g: ^Game) {
	t := &g.talk
	c := dialogue_call(g)
	clear(&t.choices)
	append(&t.choices, ..dialogue.topics(&c, t.speaker))
	t.top_level, t.listed_at = true, g.tick.total
}

// next_response shows the line's next response; past the last one the line is done.
@(private = "file")
next_response :: proc(g: ^Game) {
	t := &g.talk
	t.response += 1
	lines := dialogue.responses(&g.db, t.info)
	if t.response < len(lines) {
		t.left_s = dialogue.line_seconds(lines[t.response].text)
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
	t := &g.talk
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
// frame_subtitles shows the lines scenes are saying now.
frame_subtitles :: proc(g: ^Game) {
	lines := make([dynamic]cstring, context.temp_allocator)
	for _, run in g.ws.scenes {
		for a in run.actions {
			if a.info == 0 || worldstate.ref_grid_cell(&g.ws, &g.db, a.speaker) not_in g.ws.attached {continue}
			responses := dialogue.responses(&g.db, a.info)
			if int(a.response) >= len(responses) {continue}
			append(&lines, fmt.ctprintf("%s: %s", worldstate.display_name(&g.ws, &g.db, a.speaker), responses[a.response].text))
		}
	}
	if len(lines) == 0 {return}
	w, h := ui_screen_size()
	imgui.SetNextWindowPos({w * 0.5, h - 40}, .Always, {0.5, 1})
	if imgui.Begin("Subtitles (placeholder)", nil, {.NoTitleBar, .NoResize, .NoMove, .AlwaysAutoResize, .NoMouseInputs, .NoNavInputs, .NoFocusOnAppearing}) {
		for l in lines {imgui.TextUnformatted(l)}
	}
	imgui.End()
}

@(private = "file")
busy_in_scene :: proc(g: ^Game, actor: Form_ID) -> bool {
	scene := worldstate.scene_of_actor(&g.ws, &g.db, actor)
	if scene == 0 {return false}
	s := g.db.scenes[scene]
	for a in s.actors {
		if worldstate.alias_ref(&g.ws, s.quest, a.alias) == actor {return a.flags & gamedb.SCENE_ACTOR_NO_PLAYER_ACTIVATION != 0}
	}
	return false
}

// dialogue_call is a script call with the VM's quest variables, which GetVMQuestVariable reads.
@(private = "file")
dialogue_call :: proc(g: ^Game) -> script.Call {
	if g.repl_ok {return g.repl.vm.ctx}
	return {ws = &g.ws, db = &g.db}
}
