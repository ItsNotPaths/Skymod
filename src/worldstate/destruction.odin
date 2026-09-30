package worldstate

// Destructible refs: each one's damage, the stage it puts the ref in (its base's DEST stages, from
// high health percent to low), and what a stage does: disable or destroy the ref, cap damage, ignore
// hits, burn on its own.

import "../formats/esm"
import "../gamedb"

// (hole destruction-visuals :tags (world vfx) :sev gap) a stage swaps in no model (DMDL) and throws no explosion or debris: only its flags apply.
// Destruction_Change is a ref entering another stage, for OnDestructionStageChanged.
Destruction_Change :: struct {
	ref:      Form_ID,
	old, now: i32,
}

// destruction_stage is the stage `ref` is in: the last whose health percent its health is at or
// below; -1 when it is in none.
destruction_stage :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID) -> (index: i32, stage: esm.Destruction_Stage) {
	d, ok := gamedb.destructible_of(db, ref_base(ws, db, ref))
	if !ok || d.health <= 0 {return -1, {}}
	percent := (1 - ws.destruction[ref] / f32(d.health)) * 100
	index = -1
	for s in d.stages {
		if percent <= f32(s.health_pct) {index, stage = i32(s.index), s}
	}
	return
}

// damage_object takes `amount` off a destructible ref's health. A hit (`external`) does nothing to a
// ref whose stage ignores hits, and no damage passes a stage that caps it.
damage_object :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID, amount: f32, external: bool) {
	d, ok := gamedb.destructible_of(db, ref_base(ws, db, ref))
	if !ok || d.health <= 0 || amount <= 0 {return}
	old, stage := destruction_stage(ws, db, ref)
	if old >= 0 && (stage.flags & esm.DSTD_CAP_DAMAGE != 0 || external && stage.flags & esm.DSTD_IGNORE_EXTERNAL != 0) {return}
	set_destruction(ws, db, ref, min(ws.destruction[ref] + amount, f32(d.health)), old)
}

// set_destruction sets a ref's damage and applies the stage it lands in: its event, and a disable or
// destroy flag.
set_destruction :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID, damage: f32, old: i32) {
	if damage > 0 {ws.destruction[ref] = damage} else {delete_key(&ws.destruction, ref)}
	now, stage := destruction_stage(ws, db, ref)
	if now == old {return}
	append(&ws.destruction_changes, Destruction_Change{ref, old, now})
	cell := ref_cell(ws, db, ref)
	set_destroyed(ws, ref, cell, now >= 0 && stage.flags & esm.DSTD_DESTROY != 0)
	if now >= 0 && stage.flags & esm.DSTD_DISABLE != 0 {set_disabled(ws, ref, cell, true)}
	mark_scene_dirty(ws, ref)
}

// destroy_object is SetDestroyed: true takes the ref to its last stage, false makes it whole.
destroy_object :: proc(ws: ^World_State, db: ^gamedb.DB, ref: Form_ID, destroyed: bool) {
	old, _ := destruction_stage(ws, db, ref)
	d, ok := gamedb.destructible_of(db, ref_base(ws, db, ref))
	if !ok {
		set_destroyed(ws, ref, ref_cell(ws, db, ref), destroyed) // no stages: only the flag
		return
	}
	set_destruction(ws, db, ref, f32(d.health) if destroyed else 0, old)
	set_destroyed(ws, ref, ref_cell(ws, db, ref), destroyed)
}

// tick_destruction burns each damaged ref whose stage damages itself (an oil pool), `dt` seconds.
tick_destruction :: proc(ws: ^World_State, db: ^gamedb.DB, dt: f32) {
	refs := make([dynamic]Form_ID, context.temp_allocator)
	for ref in ws.destruction {append(&refs, ref)}
	for ref in refs {
		if _, stage := destruction_stage(ws, db, ref); stage.self_dps > 0 {damage_object(ws, db, ref, f32(stage.self_dps) * dt, false)}
	}
}
