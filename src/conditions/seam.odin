package conditions

// The host side of the condition function seam (src/condfn).

import "base:runtime"
import "../condfn"
import "../gamedb"
import "../plugin"
import "../worldstate"

table := condfn.BUILTIN // plugins' functions, asked before the engine's

// ask is the plugins' answer to a condition, else the engine function's; answered=false when
// neither has the function.
@(private)
ask :: proc(ctx: ^Context, c: gamedb.Condition, on: Form_ID) -> (value: f32, answered: bool) {
	d := Seam_Data{context, ctx.ws, ctx.db}
	h := condfn.Host{&d, seam_actor_value, seam_has_keyword, seam_faction_rank, seam_quest_stage, seam_global, seam_base}
	call := condfn.Call{c.function, on, ctx.subject, ctx.target, ctx.quest, c.param1, c.param2, c.param3, plugin.span(transmute([]u8)c.text)}
	if a := table.eval(&h, call); a.answered {return a.value, true}
	fn := lookup(c.function) or_return
	return fn(ctx, c, on)
}

@(private = "file")
Seam_Data :: struct {
	ctx: runtime.Context,
	ws:  ^worldstate.World_State,
	db:  ^gamedb.DB,
}

@(private = "file")
seam_actor_value :: proc "c" (data: rawptr, actor: Form_ID, name: cstring) -> f32 {
	d := (^Seam_Data)(data)
	context = d.ctx
	return worldstate.av_current(d.ws, d.db, actor, string(name))
}

@(private = "file")
seam_has_keyword :: proc "c" (data: rawptr, form, keyword: Form_ID) -> bool {
	d := (^Seam_Data)(data)
	context = d.ctx
	return worldstate.has_keyword(d.ws, d.db, form, keyword)
}

@(private = "file")
seam_faction_rank :: proc "c" (data: rawptr, actor, faction: Form_ID) -> i32 {
	d := (^Seam_Data)(data)
	context = d.ctx
	rank, member := worldstate.faction_rank(d.ws, d.db, actor, faction)
	return rank if member else -1
}

@(private = "file")
seam_quest_stage :: proc "c" (data: rawptr, quest: Form_ID) -> i32 {
	d := (^Seam_Data)(data)
	context = d.ctx
	return i32(worldstate.quest_stage(d.ws, quest))
}

@(private = "file")
seam_global :: proc "c" (data: rawptr, global: Form_ID) -> f32 {
	d := (^Seam_Data)(data)
	context = d.ctx
	return worldstate.global_value(d.ws, d.db, global)
}

@(private = "file")
seam_base :: proc "c" (data: rawptr, ref: Form_ID) -> Form_ID {
	d := (^Seam_Data)(data)
	context = d.ctx
	return worldstate.ref_base(d.ws, d.db, ref)
}
