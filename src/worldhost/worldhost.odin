package worldhost

// The engine's answers to plugin.World, from worldstate and gamedb: every seam's host embeds this.

import "base:runtime"
import "../gamedb"
import "../plugin"
import "../worldstate"

Form_ID :: plugin.Form_ID

Data :: struct {
	ctx: runtime.Context,
	ws:  ^worldstate.World_State,
	db:  ^gamedb.DB,
}

world :: proc(d: ^Data) -> plugin.World {
	return {
		data          = d,
		player        = d.ws.player,
		ref           = ref,
		actor_value   = actor_value,
		level         = level,
		faction_rank  = faction_rank,
		relation      = relation,
		hostile       = hostile,
		has_keyword   = has_keyword,
		in_list       = in_list,
		item_count    = item_count,
		awareness     = awareness,
		quest_stage   = quest_stage,
		quest_running = quest_running,
		stage_done    = stage_done,
		global        = global,
		setting       = setting,
		game_hours    = game_hours,
		record        = record,
		has_tag       = has_tag,
	}
}

@(private = "file")
ref :: proc "c" (data: rawptr, ref: Form_ID) -> (r: plugin.Ref) {
	d := (^Data)(data)
	context = d.ctx
	ws, db := d.ws, d.db
	r.base = worldstate.ref_base(ws, db, ref)
	r.cell = worldstate.ref_cell(ws, db, ref)
	r.space = worldstate.ref_space(ws, db, ref)
	r.location = worldstate.ref_location(ws, db, ref)
	r.pos = worldstate.ref_pos(ws, db, ref)
	r.rot = worldstate.ref_rot(ws, db, ref)
	r.scale = worldstate.ref_scale(ws, db, ref)
	r.actor = gamedb.is_actor(db, r.base)
	if r.actor {
		box := worldstate.actor_box(ws, db, ref)
		r.lo, r.hi = box[0], box[1]
		r.dead = worldstate.is_dead(ws, db, ref)
	} else if box, ok := gamedb.base_bounds(db, r.base); ok {
		r.lo, r.hi = box[0] * r.scale, box[1] * r.scale
	}
	r.enabled = worldstate.ref_enabled(ws, db, ref)
	r.loaded = worldstate.ref_3d_loaded(ws, db, ref)
	if c, ok := gamedb.cell_by_formid(db, r.cell); ok {r.interior = c.interior}
	return
}

@(private = "file")
actor_value :: proc "c" (data: rawptr, actor: Form_ID, name: cstring, part: plugin.AV_Part) -> f32 {
	d := (^Data)(data)
	context = d.ctx
	switch part {
	case .Current: return worldstate.av_current(d.ws, d.db, actor, string(name))
	case .Base:    return worldstate.av_base(d.ws, d.db, actor, string(name))
	case .Max:     return worldstate.av_max(d.ws, d.db, actor, string(name))
	}
	return 0
}

@(private = "file")
level :: proc "c" (data: rawptr, actor: Form_ID) -> i32 {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.actor_level(d.ws, d.db, actor)
}

@(private = "file")
faction_rank :: proc "c" (data: rawptr, actor, faction: Form_ID) -> i32 {
	d := (^Data)(data)
	context = d.ctx
	rank, member := worldstate.faction_rank(d.ws, d.db, actor, faction)
	return rank if member else -1
}

@(private = "file")
relation :: proc "c" (data: rawptr, a, b: Form_ID) -> plugin.Relation {
	d := (^Data)(data)
	context = d.ctx
	return plugin.Relation(worldstate.faction_relation(d.ws, d.db, a, b))
}

@(private = "file")
hostile :: proc "c" (data: rawptr, a, b: Form_ID) -> bool {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.hostile(d.ws, d.db, a, b)
}

@(private = "file")
has_tag :: proc "c" (data: rawptr, form: Form_ID, pattern: cstring) -> bool {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.has_tag(d.ws, d.db, form, string(pattern))
}

@(private = "file")
has_keyword :: proc "c" (data: rawptr, form, keyword: Form_ID) -> bool {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.has_keyword(d.ws, d.db, form, keyword)
}

@(private = "file")
in_list :: proc "c" (data: rawptr, list, form: Form_ID) -> bool {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.list_has(d.ws, d.db, list, form)
}

@(private = "file")
item_count :: proc "c" (data: rawptr, container, item: Form_ID) -> i32 {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.inv_count(d.ws, d.db, container, item)
}

@(private = "file")
awareness :: proc "c" (data: rawptr, viewer, target: Form_ID) -> plugin.Awareness {
	d := (^Data)(data)
	context = d.ctx
	a := worldstate.awareness(d.ws, viewer, target)
	return {a.level, a.detected}
}

@(private = "file")
quest_stage :: proc "c" (data: rawptr, quest: Form_ID) -> i32 {
	d := (^Data)(data)
	context = d.ctx
	return i32(worldstate.quest_stage(d.ws, quest))
}

@(private = "file")
quest_running :: proc "c" (data: rawptr, quest: Form_ID) -> bool {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.quest_running(d.ws, d.db, quest)
}

@(private = "file")
stage_done :: proc "c" (data: rawptr, quest: Form_ID, stage: i32) -> bool {
	d := (^Data)(data)
	context = d.ctx
	return stage >= 0 && worldstate.quest_is_stage_done(d.ws, quest, u16(stage))
}

@(private = "file")
global :: proc "c" (data: rawptr, global: Form_ID) -> f32 {
	d := (^Data)(data)
	context = d.ctx
	return worldstate.global_value(d.ws, d.db, global)
}

@(private = "file")
setting :: proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32 {
	d := (^Data)(data)
	context = d.ctx
	return gamedb.setting_float(d.db, string(name), fallback)
}

@(private = "file")
game_hours :: proc "c" (data: rawptr) -> f64 {
	d := (^Data)(data)
	return d.ws.clock.hours
}
