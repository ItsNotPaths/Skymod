package script

// The story manager: an event (a script's SendStoryEvent, or the engine's kill, location change,
// crime...) walks the story manager tree (SMBN branches, SMQN quest nodes, SMEN event nodes) and
// starts the quests whose node conditions pass, filling their From_Event aliases from the event.

import "../worldstate"

// Script events come through the natives below. Engine events queue in ws.story_events and the
// script tick runs them; each event family is its own story-* hole at the site the event happens.

// (hole story-manager :tags (quest script) :sev blocker :needs (story-records condition-functions)) story_event answers false and starts nothing: no tree walk, no node conditions (run-on Event Data, GetEventData), no quest start. SCPT events reach it; CLOC is the first engine event (story-change-location). 448 SMQN, 99 SMBN and 24 SMEN in Skyrim.esm.

Story_Event :: worldstate.Story_Event

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
	return {"SCPT", c.self, arg_form(args, 0), arg_form(args, 1), arg_form(args, 2), arg_i32(args, 3, 0), arg_i32(args, 4, 0)}
}
