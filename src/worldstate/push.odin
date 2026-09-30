package worldstate

import "core:math/linalg"
import "../gamedb"

// (hole push-speed :tags (physics combat) :sev polish) unsourced: how fast a knockback force pushes an actor and how quickly the push fades; PUSH_SPEED and PUSH_FADE are guesses.
PUSH_SPEED :: f32(128) // units a second per point of force
PUSH_FADE :: f32(4)    // the push loses this share of itself each second

// push_actor sends `actor` away from `from` along the ground with `force` (PushActorAway).
push_actor :: proc(ws: ^World_State, db: ^gamedb.DB, from, actor: Form_ID, force: f32) {
	d := ref_pos(ws, db, actor) - ref_pos(ws, db, from)
	dir := linalg.normalize0([2]f32{d.x, d.y})
	ws.pushes[actor] = dir * force * PUSH_SPEED
}

// take_push is the push velocity `actor` moves with this tick; the push fades as it goes.
take_push :: proc(ws: ^World_State, actor: Form_ID, dt: f32) -> [2]f32 {
	p, ok := &ws.pushes[actor]
	if !ok {return {}}
	v := p^
	p^ *= max(1 - PUSH_FADE * dt, 0)
	if linalg.length(p^) < 1 {delete_key(&ws.pushes, actor)}
	return v
}
