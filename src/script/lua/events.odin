package script_lua

// Engine events into scripts. The engine sends an edge when it happens; the scripts run it when
// game_tick drains the queue. Timers are the third kind: tick_updates counts OnUpdate registrations
// down and sends the ones that come due (docs/script-rewrite.md "Events: edges, transitions, timers").

import "core:c"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../gamedb"
import "../../worldstate"
import "../../formid"

// (hole hit-death-events :tags combat :sev gap :needs (combat-damage)) nothing sends OnHit, OnDying or OnDeath: no attack makes a hit, Health at 0 does not kill, and Actor.Kill sets Dead with no events.
// (hole trigger-events :tags physics :sev gap :needs (sensor-bodies)) nothing sends OnTriggerEnter/OnTriggerLeave (448 scripts define one or both); there are no trigger volumes.

// send queues a ref's `event` for the scripts on it and on each alias it fills.
send :: proc(vm: ^VM, form: script.Form_ID, event: string, args: ..any) {
	for r in recipients(vm.ctx.ws, form) {send_own(vm, r, event, ..args)}
}

// recipients is who hears a ref's events: the ref, each alias it fills ("ReferenceAliases receive
// events from the ObjectReference they are pointing at"), then each effect on it (an
// ActiveMagicEffect receives its target's events).
@(private = "file")
recipients :: proc(ws: ^worldstate.World_State, form: script.Form_ID) -> []script.Form_ID {
	holders, _ := ws.alias_holders[form]
	out := make([dynamic]script.Form_ID, 0, 1 + len(holders), context.temp_allocator)
	append(&out, form)
	append(&out, ..holders[:])
	append(&out, ..worldstate.effects_on(ws, form))
	return out[:]
}

// send_own queues `event` for every script on `form` alone, and reports whether `form` has any.
// Args are refs (Form_ID), i32, f32, bool or string.
send_own :: proc(vm: ^VM, form: script.Form_ID, event: string, args: ..any) -> bool {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "send") {return false}
	push_ref(L, form)
	lua.pushstring(L, strings.clone_to_cstring(event, context.temp_allocator))
	for a in args {
		switch x in a {
		case script.Form_ID:
			push_ref(L, x)
		case i32:
			lua.pushinteger(L, lua.Integer(x))
		case f32:
			lua.pushnumber(L, lua.Number(x))
		case bool:
			lua.pushboolean(L, b32(x))
		case string:
			lua.pushstring(L, strings.clone_to_cstring(x, context.temp_allocator))
		case:
			log.errorf("lua: send %s: unsupported arg type %v", event, a.id)
			return false
		}
	}
	if lua.pcall(L, i32(2 + len(args)), 1, 0) != 0 {
		log.errorf("lua: rt.send: %s", to_string(L, -1))
		return false
	}
	return bool(lua.toboolean(L, -1))
}

// send_anim_event delivers an animation event from `sender` to each form that registered for it,
// and to no one else (CK: "will not be relayed to attached aliases or effects"). When `sender`
// itself did not register, its scripts that handle OnAnimationEvent get a one-time warning.
send_anim_event :: proc(vm: ^VM, sender: script.Form_ID, event: string) {
	regs := worldstate.anim_registrants(vm.ctx.ws, sender, event)
	for r in regs {send_own(vm, r, "OnAnimationEvent", sender, event)}
	if slice.contains(regs, sender) {return}

	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "check_anim_handler") {return}
	push_ref(L, sender)
	lua.pushstring(L, strings.clone_to_cstring(event, context.temp_allocator))
	if lua.pcall(L, 2, 0, 0) != 0 {log.errorf("lua: rt.check_anim_handler: %s", to_string(L, -1))}
}

// __anim_event(sender, name) is send_anim_event for Lua: drivers stand in for the animation system.
@(private)
rt_anim_event :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, UPVAL_VM)
	context = vm.host_context
	sender, _ := ref_form(L, 1)
	send_anim_event(vm, sender, to_string(L, 2))
	return 0
}

// tick_updates is the scheduler: OnUpdate registrations count down by `dt` real seconds, and
// OnUpdateGameTime ones by the game hours that passed, skips included.
tick_updates :: proc(vm: ^VM, ws: ^worldstate.World_State, dt: f32, hours: f64) {
	count_down(vm, &ws.updates, dt, "OnUpdate")
	count_down(vm, &ws.game_updates, f32(hours), "OnUpdateGameTime")
}

// count_down queues `event` on each form whose timer comes due, once a tick at most: a repeating
// timer still overdue after it fires (a skip) waits a full interval. A due form with no script
// instances yet stays due until one exists.
@(private = "file")
count_down :: proc(vm: ^VM, timers: ^map[script.Form_ID]worldstate.Update_Timers, step: f32, event: string) {
	stopped := make([dynamic]script.Form_ID, context.temp_allocator)
	for form, &u in timers {
		if u.single_on {
			u.single -= step
			if u.single <= 0 && send_own(vm, form, event) {u.single_on = false}
		}
		if u.repeat_on {
			u.repeat -= step
			if u.repeat <= 0 && send_own(vm, form, event) {
				u.repeat = u.repeat + u.interval if u.repeat + u.interval > 0 else u.interval
			}
		}
		if !u.single_on && !u.repeat_on {append(&stopped, form)}
	}
	for form in stopped {delete_key(timers, form)}
}

// tick_effects runs the effects' clocks (worldstate.advance_effect). An ended effect whose
// OnEffectFinish went out, and whose instance's state no longer ticks, leaves (docs/script-api.md
// section 3).
tick_effects :: proc(vm: ^VM, ws: ^worldstate.World_State, dt: f32) {
	gone := make([dynamic]script.Form_ID, context.temp_allocator)
	c := vm.ctx
	for h, e in ws.effects {
		if int(e.elapsed + dt) != int(e.elapsed) {script.recheck_effect(&c, h)} // each second
		worldstate.advance_effect(ws, vm.ctx.db, h, dt)
		if e.finished && !ticking(vm, h) {append(&gone, h)}
	}
	for h in gone {
		detach(vm, h)
		worldstate.forget_scripts(ws, h)
		worldstate.remove_effect(ws, h)
	}
	sync_refs(vm)
}

// ticking reports whether an instance on `form` has OnTick in its current state.
@(private = "file")
ticking :: proc(vm: ^VM, form: script.Form_ID) -> bool {
	L := vm.L
	top := lua.gettop(L)
	defer lua.settop(L, top)
	if !push_rt_fn(L, "ticking") {return false}
	push_ref(L, form)
	if lua.pcall(L, 1, 1, 0) != 0 {
		log.errorf("lua: rt.ticking: %s", to_string(L, -1))
		return false
	}
	return bool(lua.toboolean(L, -1))
}

// tick_items sends the inventory events of the items scripts moved since the last tick: OnItemRemoved
// to the old container, OnItemAdded to the new one, then OnContainerChanged to a moved ref (not to a
// destroyed one). The CK does not give this order.
tick_items :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State) {
	for m in ws.item_moves {
		if m.from != 0 {send_item(vm, db, ws, m.from, "OnItemRemoved", m, m.to)}
		if m.to != 0 {send_item(vm, db, ws, m.to, "OnItemAdded", m, m.from)}
		if m.ref != 0 && m.to != 0 {send(vm, m.ref, "OnContainerChanged", m.to, m.from)}
	}
	clear(&ws.item_moves)
}

// tick_equips starts and ends the enchantments of gear that went on or off
// (script.sync_constant_effects), then sends OnObjectUnequipped / OnObjectEquipped(akBaseObject,
// akReference) for each item, in order, to the actor and its aliases and effects. Inventory items
// have no reference.
tick_equips :: proc(vm: ^VM, ws: ^worldstate.World_State) {
	c := vm.ctx
	synced := make([dynamic]script.Form_ID, context.temp_allocator)
	for e in ws.equip_changes {
		if !slice.contains(synced[:], e.actor) {
			append(&synced, e.actor)
			script.sync_constant_effects(&c, e.actor)
		}
	}
	for e in ws.equip_changes {
		send(vm, e.actor, "OnObjectEquipped" if e.on else "OnObjectUnequipped", e.item, script.Form_ID(0))
	}
	clear(&ws.equip_changes)
}

// tick_level_ups sends OnLevelUp(akActor, aiLevel, asChoice) for each level-up to every registered
// form, in form order.
tick_level_ups :: proc(vm: ^VM, ws: ^worldstate.World_State) {
	if len(ws.level_ups) == 0 {return}
	listeners := make([dynamic]script.Form_ID, 0, len(ws.level_listeners), context.temp_allocator)
	for form in ws.level_listeners {append(&listeners, form)}
	slice.sort(listeners[:])
	for l in ws.level_ups {
		for form in listeners {send_own(vm, form, "OnLevelUp", l.actor, l.level, l.choice)}
		delete(l.choice)
	}
	clear(&ws.level_ups)
}

// tick_story_events runs the engine's story events through the story manager, in the order they
// happened, then sends each quest an event started its OnStory handler with the event's data.
tick_story_events :: proc(vm: ^VM, ws: ^worldstate.World_State) {
	cc := vm.ctx
	for e in ws.story_events {script.story_event(&cc, e)}
	clear(&ws.story_events)
	for quest in ws.story_quests {
		e, ok := ws.quest_events[quest]
		if !ok {continue}
		switch e.type {
		case worldstate.STORY_SCRIPT:
			send(vm, quest, "OnStoryScript", e.keyword, e.location1, e.ref1, e.ref2, e.value1, e.value2)
		case worldstate.STORY_CHANGE_LOCATION:
			send(vm, quest, "OnStoryChangeLocation", e.ref1, e.location1, e.location2)
		}
	}
	clear(&ws.story_quests)
}

// tick_zone_levels sends OnZoneLevelSet for each zone that took its level, to every registered form
// in form order.
tick_zone_levels :: proc(vm: ^VM, ws: ^worldstate.World_State) {
	if len(ws.zone_level_sets) == 0 {return}
	listeners := make([dynamic]script.Form_ID, 0, len(ws.zone_listeners), context.temp_allocator)
	for form in ws.zone_listeners {append(&listeners, form)}
	slice.sort(listeners[:])
	for zone in ws.zone_level_sets {
		for form in listeners {send_own(vm, form, "OnZoneLevelSet", zone, ws.zone_levels[zone])}
	}
	clear(&ws.zone_level_sets)
}

// send_item sends an inventory event to a container's recipients, each through its own filters.
@(private = "file")
send_item :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, container: script.Form_ID, event: string, m: worldstate.Item_Move, other: script.Form_ID) {
	for r in recipients(ws, container) {
		if item_passes(db, ws, r, m) {send_own(vm, r, event, m.base, m.count, m.ref, other)}
	}
}

// item_passes reports whether `recipient`'s inventory event filters let the move through. A filter
// matches the base or the ref itself, or a FormList holding either (not nested lists).
@(private = "file")
item_passes :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, recipient: script.Form_ID, m: worldstate.Item_Move) -> bool {
	filters, ok := ws.item_filters[recipient]
	if !ok {return true}
	for f in filters {
		if f == m.base || (m.ref != 0 && f == m.ref) {return true}
		members, _ := gamedb.form_list_of(db, f)
		for x in members {
			if x == m.base || (m.ref != 0 && x == m.ref) {return true}
		}
	}
	return false
}

// The script phase of a tick is tick_begin, then whatever the engine runs for scripts (the app's
// activations), then tick_end (docs/script-api.md section 3).

// tick_begin advances the script clocks, gives the refs of `loaded` cells their scripts (and OnInit),
// then queues load/attach transitions against `attached`, due OnUpdate timers and moved items.
tick_begin :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, t: ^Transitions, loaded, attached: []script.Form_ID, dt: f32) {
	hours := advance_clocks(vm, db, ws, dt)
	worldstate.av_regen(ws, db, play_seconds(db, ws, dt, hours))
	sync_refs(vm)
	tick_effects(vm, ws, dt)
	for cell in loaded {attach_cell(vm, db, cell)}
	tick_transitions(vm, db, ws, t, attached)
	tick_location(ws, t, worldstate.ref_location(ws, db, formid.PLAYER))
	tick_updates(vm, ws, dt, hours)
	tick_items(vm, db, ws)
	tick_zone_levels(vm, ws)
	tick_equips(vm, ws)
	tick_level_ups(vm, ws)
	tick_story_events(vm, ws)
}

// tick_end runs every queued event, then OnTick. Returns how many events ran.
tick_end :: proc(vm: ^VM, dt: f32) -> int {
	ran := drain(vm)
	call_rt(vm, "tick", f64(dt))
	worldstate.end_first_tick(vm.ctx.ws)
	return ran
}

// drain runs every queued event. Returns how many events ran.
drain :: proc(vm: ^VM) -> int {
	return call_rt(vm, "drain")
}

// advance_clocks moves the game clock by one tick at TimeScale, then every script clock field by
// the real and game time that passed. Returns the game hours. A new game or an old save starts the
// clock from the globals.
@(private = "file")
advance_clocks :: proc(vm: ^VM, db: ^gamedb.DB, ws: ^worldstate.World_State, dt: f32) -> f64 {
	g := worldstate.global_value
	if ws.clock.state == .Unset {
		worldstate.start_clock(
			ws,
			g(ws, db, formid.GAME_YEAR),
			g(ws, db, formid.GAME_MONTH),
			g(ws, db, formid.GAME_DAY),
			g(ws, db, formid.GAME_HOUR),
			g(ws, db, formid.GAME_DAYS_PASSED),
		)
	}
	before := ws.clock.hours
	hours := worldstate.advance_clock(ws, dt, g(ws, db, formid.TIMESCALE))
	if math.floor(before) != math.floor(ws.clock.hours) {script.restock_vendors(db, ws)}
	call_rt(vm, "advance", f64(dt), hours)
	return hours
}

// play_seconds is how much play the tick's game hours stand for at TimeScale: `dt`, plus any skip
// (a wait regenerates as if played through).
@(private = "file")
play_seconds :: proc(db: ^gamedb.DB, ws: ^worldstate.World_State, dt: f32, hours: f64) -> f32 {
	scale := worldstate.global_value(ws, db, formid.TIMESCALE)
	return f32(hours * 3600 / f64(scale)) if scale > 0 else dt
}

// call_rt calls skymod.rt[name] with number arguments and returns its result as an int.
@(private)
call_rt :: proc(vm: ^VM, name: cstring, args: ..f64) -> int {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, name) {return 0}
	for a in args {lua.pushnumber(L, lua.Number(a))}
	if lua.pcall(L, i32(len(args)), 1, 0) != 0 {
		log.errorf("lua: rt.%s: %s", name, to_string(L, -1))
		return 0
	}
	return int(lua.tointeger(L, -1))
}

// push_rt_fn pushes skymod.rt[name]. The caller restores the stack.
@(private)
push_rt_fn :: proc(L: ^lua.State, name: cstring) -> bool {
	lua.getglobal(L, "require")
	lua.pushstring(L, "skymod.rt")
	if lua.pcall(L, 1, 1, 0) != 0 {
		log.errorf("lua: require skymod.rt: %s", to_string(L, -1))
		return false
	}
	lua.getfield(L, -1, name)
	return true
}
