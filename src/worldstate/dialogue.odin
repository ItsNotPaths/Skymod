package worldstate

// What dialogue remembers: which lines each speaker said and when, and the Exclusive branch a
// speaker is in. Say Once and the reset timers are saved for every quest; vanilla forgets Say Once
// on a restart for quests that are not Start Game Enabled (CK Topic Info), a bug we do not keep.

Speaker_Info :: [2]Form_ID // {speaker, info}

// Courier_Remove is a Courier.RemoveRef that waits while its courier talks to the player.
Courier_Remove :: struct {
	courier, container, item, count: Form_ID,
	to_player:                       bool,
}

// Force_Greet is an NPC waiting to start a conversation with the player: the AI asks, the app opens it. Not saved.
Force_Greet :: struct {
	speaker, topic: Form_ID, // topic 0: the speaker's usual greeting
	subtype:        string, // with no topic: its line from every topic of this subtype (PFGT)
}

// Bark is a line an actor says outside a conversation or a scene (a Hello, idle chatter, the Say
// procedure). The AI asks with `info` 0 and a topic or a subtype stack; the script tick picks the
// line and plays it response by response. Not saved.
// Bark subtypes the engine says itself (DIAL SNAM).
SUBTYPE_HIT :: [4]u8{'H', 'I', 'T', '_'}
SUBTYPE_DEATH :: [4]u8{'D', 'E', 'T', 'H'}

Bark :: struct {
	speaker, to: Form_ID,
	topic:       Form_ID, // 0: say from the `subtype` stack
	subtype:     [4]u8,
	info:        Form_ID,
	response:    i32,
	left:        f32,
}

// speaking: the actor has a line asked for or playing.
speaking :: proc(ws: ^World_State, actor: Form_ID) -> bool {
	for b in ws.barks {
		if b.speaker == actor {return true}
	}
	return false
}

// Info_Run is a topic info fragment to run on the script thread: begin when a line starts, end
// when its last response is done.
Info_Run :: struct {
	info, speaker: Form_ID,
	end:           bool,
}

// info_said records that `speaker` said `info` now.
info_said :: proc(ws: ^World_State, speaker, info: Form_ID) {
	ws.infos_said[{speaker, info}] = ws.clock.hours
}

set_talked_to_pc :: proc(ws: ^World_State, speaker: Form_ID) {
	ws.talked_to_pc[speaker] = true
}

// info_said_at is the game hour `speaker` last said `info`.
info_said_at :: proc(ws: ^World_State, speaker, info: Form_ID) -> (f64, bool) {
	return ws.infos_said[{speaker, info}]
}

talked_to_pc :: proc(ws: ^World_State, speaker: Form_ID) -> bool {
	return speaker in ws.talked_to_pc
}

// exclusive_branch is the Exclusive branch `speaker` is in; 0 when none.
exclusive_branch :: proc(ws: ^World_State, speaker: Form_ID) -> Form_ID {
	return ws.exclusive[speaker]
}

set_exclusive_branch :: proc(ws: ^World_State, speaker, branch: Form_ID) {
	if branch == 0 {delete_key(&ws.exclusive, speaker)} else {ws.exclusive[speaker] = branch}
}

// random_said: `speaker` said this Random info in the current round of its topic (Do All Before
// Repeating).
random_said :: proc(ws: ^World_State, speaker, info: Form_ID) -> bool {
	return {speaker, info} in ws.random_said
}

set_random_said :: proc(ws: ^World_State, speaker, info: Form_ID, said: bool) {
	if said {ws.random_said[{speaker, info}] = true} else {delete_key(&ws.random_said, Speaker_Info{speaker, info})}
}
