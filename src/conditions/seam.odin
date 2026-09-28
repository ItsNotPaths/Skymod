package conditions

// The host side of the condition function seam (src/condfn).

import "../condfn"
import "../gamedb"
import "../plugin"
import "../worldhost"

table := condfn.BUILTIN // plugins' functions, asked before the engine's

// ask is the plugins' answer to a condition, else the engine function's; answered=false when
// neither has the function.
@(private)
ask :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool) {
	wd := worldhost.Data{context, ctx.ws, ctx.db}
	h := condfn.Host{worldhost.world(&wd)}
	call := condfn.Call{c.function, on, ctx.subject, ctx.target, ctx.quest, c.param1, c.param2, c.param3, plugin.span(transmute([]u8)c.text)}
	if a := table.eval(&h, call); a.answered {return a.value, true}
	fn := lookup(c.function) or_return
	return fn(ctx, c, on)
}
