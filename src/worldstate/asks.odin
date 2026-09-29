package worldstate

// Message boxes a script asked for, and the answers. Show queues the message and returns; the box
// pauses the world before the next tick, so the answer is there on the tick after the ask. Neither
// is saved: a script that loads with no answer asks again.

// ask queues a message box, once while it waits, and drops its old answer.
ask :: proc(ws: ^World_State, message: Form_ID) {
	assert_owner(ws)
	delete_key(&ws.answers, message)
	for m in ws.asks {if m == message {return}}
	append(&ws.asks, message)
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
	ws.answers[ws.asks[0]] = pick
	ordered_remove(&ws.asks, 0)
}
