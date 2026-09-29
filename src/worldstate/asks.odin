package worldstate

// Message boxes a script or the engine asked for, and the answers. Show queues the message and
// returns; the box pauses the world before the next tick, so the answer is there on the tick after
// the ask. Neither is saved: a script that loads with no answer asks again.

Ask :: struct {
	message:  Form_ID,
	args:     [9]f32, // Show's arguments, which fill the %-tokens of the text
	can_back: bool,   // backing out answers len(buttons): none of them. Papyrus's own asks cannot.
}

// ask queues a message box, once while it waits, and drops its old answer.
ask :: proc(ws: ^World_State, message: Form_ID, args := [9]f32{}, can_back := false) {
	assert_owner(ws)
	delete_key(&ws.answers, message)
	for &a in ws.asks {
		if a.message == message {
			a.args, a.can_back = args, can_back
			return
		}
	}
	append(&ws.asks, Ask{message, args, can_back})
}

// answer is the button the player picked on the last box of `message`; -1 when none.
answer :: proc(ws: ^World_State, message: Form_ID) -> i32 {
	assert_owner(ws)
	return ws.answers[message] or_else -1
}

// take_ask records the pick for the oldest ask and drops it from the queue.
take_ask :: proc(ws: ^World_State, pick: i32) {
	assert_owner(ws)
	if len(ws.asks) == 0 {return}
	ws.answers[ws.asks[0].message] = pick
	ordered_remove(&ws.asks, 0)
}
