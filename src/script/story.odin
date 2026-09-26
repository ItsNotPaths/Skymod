package script

// The story manager: an event (a script's SendStoryEvent, or the engine's kill, location change,
// crime...) walks the story manager tree (SMBN branches, SMQN quest nodes, SMEN event nodes) and
// starts the quests whose node conditions pass, filling their From_Event aliases from the event.

// (hole story-manager :tags (quest script) :sev blocker :needs (story-records condition-functions)) no event starts a quest: story_event answers false and starts nothing, and the engine sends no events (kill, change location, crime, script event...). 448 SMQN, 99 SMBN and 24 SMEN in Skyrim.esm.

// Story_Event is one event the story manager answers: its type keyword (SCPT for a script event)
// and its data.
Story_Event :: struct {
	keyword:        Form_ID,
	location:       Form_ID,
	ref1, ref2:     Form_ID,
	value1, value2: i32,
}

// story_event runs one event through the story manager tree; true when it started a quest.
story_event :: proc(c: ^Call, e: Story_Event) -> bool {
	return false
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
	return {c.self, arg_form(args, 0), arg_form(args, 1), arg_form(args, 2), arg_i32(args, 3, 0), arg_i32(args, 4, 0)}
}
