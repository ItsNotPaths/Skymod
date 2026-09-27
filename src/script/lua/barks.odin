package script_lua

import "../../dialogue"
import "../../worldstate"

// tick_barks plays the lines actors say outside conversations and scenes: a new one picks its
// line (none that can be said, or a speaker already busy, drops it), then goes response by
// response and ends with its end fragment.
tick_barks :: proc(vm: ^VM, dt: f32) {
	ws := vm.ctx.ws
	n := 0
	for i in 0 ..< len(ws.barks) {
		b := ws.barks[i]
		if !play_bark(vm, &b, dt) {continue}
		ws.barks[n] = b
		n += 1
	}
	resize(&ws.barks, n)
}

@(private = "file")
play_bark :: proc(vm: ^VM, b: ^worldstate.Bark, dt: f32) -> bool {
	c := &vm.ctx
	if b.info == 0 {
		if bark_busy(vm, b.speaker) {return false}
		b.info = dialogue.pick(c, b.speaker, b.topic) if b.topic != 0 else dialogue.pick_subtype(c, b.speaker, string(b.subtype[:]))
		if b.info == 0 {return false}
		dialogue.said(c, b.speaker, b.info)
		b.response, b.left = -1, 0
	}
	b.left -= dt
	if b.left > 0 {return true}
	b.response += 1
	lines := dialogue.responses(c.db, b.info)
	if int(b.response) < len(lines) && !worldstate.is_dead(c.ws, b.speaker) {
		b.left = say_line(vm, b.speaker, b.info, int(b.response))
		return true
	}
	dialogue.finished(c, b.speaker, b.info)
	return false
}

// bark_busy: the speaker talks to the player, acts in a scene, or already says a line.
@(private = "file")
bark_busy :: proc(vm: ^VM, speaker: worldstate.Form_ID) -> bool {
	ws := vm.ctx.ws
	if ws.talking == speaker || worldstate.scene_of_actor(ws, vm.ctx.db, speaker) != 0 {return true}
	for b in ws.barks {
		if b.speaker == speaker && b.info != 0 {return true}
	}
	return false
}
