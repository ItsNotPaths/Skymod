package conditions

// The host side of the condition function seam (src/condfn).

import "core:time"
import "../condfn"
import "../gamedb"
import "../plugin"
import "../worldhost"

table := condfn.BUILTIN // plugins' functions, asked before the engine's
plugin_ms: f64 // time in table.eval since the profile last took it

// ask is the plugins' answer to a condition, else the engine function's; answered=false when
// neither has the function.
@(private)
ask :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool) {
	wd := worldhost.Data{context, ctx.ws, ctx.db}
	w := worldhost.world(&wd)
	h := condfn.Host{&w}
	call := condfn.Call{c.function, on, ctx.subject, ctx.target, ctx.quest, c.param1, c.param2, c.param3, plugin.span(transmute([]u8)c.text)}
	t := time.tick_now()
	a := table.eval(&h, call)
	plugin_ms += time.duration_milliseconds(time.tick_since(t))
	if a.answered {return a.value, true}
	fn := lookup(c.function) or_return
	return fn(ctx, c, on)
}
