package main

// Crosshair interaction: the single place the Activate press is turned into a real action against
// whatever the reticle is actually on (resolve_activation), replacing the old proximity "nearest
// door" scan. One tap does the obvious thing per target kind; a press-and-hold on a physics item
// lifts it into a telekinesis grab you steer with the mouse (aim) and wheel (reach).
//
//   Door       → cross it (go_through, straight from the door's XTEL — no proximity scan).
//   Phys item  → TAP: collect into the pack (stubbed — no player inventory yet, just a log).
//                HOLD: grab it and float it in front of you; release to drop.
//   Container  → open (stubbed — no container/inventory UI yet, just a log).
//   Actor      → talk (dialogue.odin).
//   Other      → activate (stubbed — loot menus hook in here later).
//
// Every activation, a key press or a script's Activate, goes through activate(): OnActivate to the
// ref's scripts, then the default action above unless a script called BlockActivation.
//
// Auto-load doors (invisible cave/dungeon markers) are NOT handled here — the ray never hits them,
// so they stay proximity-fired in frame_traversal, exactly as before.

import "core:log"
import "../actorstate"
import "../ai"
import "../audio"
import "../formats/esm"
import "../gamedb"
import smath "../math"
import "../physics"
import "../script"
import slua "../script/lua"
import "../worldstate"
import "../formid"

// (hole book-screen :tags ui :sev gap) activating a book reads it at once and takes it: there is no reading screen with its text and a Take button.
// (hole flora-seasons :tags (world records) :sev polish) harvesting ignores FLOR PFPC, the chance to yield per season; it always yields.
// (hole flora-harvested-look :tags (render world) :sev polish) a harvested plant looks the same; Skyrim swaps it to its harvested model or hides the produce.
// (hole story-flatter-event :tags (quest dialogue) :sev polish :needs persuasion) no FLAT story event is queued when a flatter check passes.

// GRAB_HOLD_S: an Activate press held longer than this on a physics item promotes from a tap
// (collect) to a telekinesis grab. Short enough to feel like a deliberate hold, long enough that a
// normal tap-to-collect never trips it.
GRAB_HOLD_S :: f32(0.18)

// Telekinesis servo: each tick we drive the held body's velocity toward the aim point (a spot down
// the crosshair ray at `dist`) rather than teleporting it — so it shoves through the world instead
// of tunnelling, and the existing clutter velocity clamps keep it stable. GRAB_GAIN is the spring
// stiffness (1/s); GRAB_MAX_VEL caps the servo speed so a far snap can't fling it.
GRAB_GAIN    :: f32(9)
GRAB_MAX_VEL :: f32(650)

// How far in front of the eye a grabbed item floats, and the wheel's reach range/step.
GRAB_MIN_DIST :: f32(120)
GRAB_MAX_DIST :: f32(600)
GRAB_DIST_0   :: f32(240)
GRAB_SCROLL   :: f32(45) // world units of reach per wheel notch

// Interact holds the live crosshair-interaction state across frames: an in-flight Activate press
// (to tell a tap from a hold) and, once promoted, the active telekinesis grab.
Interact :: struct {
	// An Activate press that STARTED on a grabbable physics item — held until we know tap vs hold.
	pressing:   bool,
	press_body: physics.Body,
	press_form: Form_ID,
	held_s:     f32, // seconds the press has been held

	// Active telekinesis grab (promoted from a long press).
	grabbing: bool,
	body:     physics.Body,
	dist:     f32, // current reach (wheel-adjusted)
}

// tick_interact drives the Activate button against the crosshair target: a tap activates it, a
// hold on a movable item grabs it with telekinesis until the button is let go.
tick_interact :: proc(g: ^Game, tgt: Activation_Target) {
	if g.sim.input.in_menu {return}
	act_down := g.sim.input.activate

	// 1) Already grabbing: steer the body while Activate stays down; release = drop.
	if g.sim.interact.grabbing {
		if sp := active_space(g); act_down && sp != nil && sp.phys != nil {
			grab_update(g)
		} else {
			g.sim.interact.grabbing = false
			log.info("grab: released")
		}
		return
	}

	// 2) A press is in flight on a physics item: measure how long it's held. Cross GRAB_HOLD_S while
	//    still down → promote to a grab; release before that → it was a tap → collect.
	if g.sim.interact.pressing {
		if act_down {
			g.sim.interact.held_s += TICK_DT
			if g.sim.interact.held_s >= GRAB_HOLD_S {
				grab_begin(g)
				g.sim.interact.pressing = false
			}
		} else {
			activate(g, g.sim.interact.press_form, g.sim.ws.player)
			g.sim.interact.pressing = false
		}
		return
	}

	// 3) A fresh Activate edge on what the crosshair is on. An unblocked physics item waits to learn
	//    tap (activate) from hold (grab); anything else activates now.
	if act_down && !g.sim.input_was.activate && tgt.present {
		if tgt.dyn_body != 0 && !worldstate.activation_blocked(&g.sim.ws, tgt.form) {
			g.sim.interact.pressing = true
			g.sim.interact.press_body = tgt.dyn_body
			g.sim.interact.press_form = tgt.form
			g.sim.interact.held_s = 0
		} else {
			activate(g, tgt.form, g.sim.ws.player)
		}
	}
}

// tick_cast casts the spell in a hand when its button goes down, at what the crosshair is on, and
// the Sneak button puts the player in or out of sneak mode.
tick_cast :: proc(g: ^Game, tgt: Activation_Target) {
	if g.sim.input.in_menu {return}
	in_, was := g.sim.input, g.sim.input_was
	if in_.sneak && !was.sneak {
		states, player := &g.sim.ws.states, g.sim.ws.player
		if actorstate.current(states, player) == actorstate.SNEAK {actorstate.leave(states, player, actorstate.SNEAK)} else {actorstate.request(states, player, actorstate.SNEAK)}
	}
	c := script.Call{ws = &g.sim.ws, db = &g.db, audio = &g.audio, vfs = &g.v}
	target := tgt.form if tgt.present else 0
	// (hole shouts :tags (magic input player) :sev gap) nothing uses the Voice slot: no Shout action, no shout cooldown or Voice recovery (ShoutRecoveryMult, Get/SetVoiceRecoveryTime), no once-a-day limit on powers, no GetCurrentShoutVariation.
	if in_.cast_left && !was.cast_left {script.cast_hand(&c, g.sim.ws.player, .LeftHand, target)}
	if in_.cast_right && !was.cast_right {script.cast_hand(&c, g.sim.ws.player, .RightHand, target)}
}

// (hole lock-keys :tags player :sev gap) a locked door or container opens like any other: nothing checks for its key.
// (hole lockpicking :tags (ui player ui-train) :sev gap :needs (lock-keys)) no lockpicking screen and no Lockpicking XP.
// activate is the one activation path, for the Activate key and for a script's Activate, by any
// actor: OnActivate is queued for the ref's scripts (it runs at the next tick, after the default
// action, as in Papyrus), then the default action runs unless a script blocked it. `default_only`
// sends no event and ignores the block (abDefaultProcessingOnly). Menus open for the player only.
activate :: proc(g: ^Game, form, by: Form_ID, default_only := false) {
	if !default_only {
		if g.repl_ok {slua.send(&g.sim.repl.vm, form, "OnActivate", by)}
		if worldstate.activation_blocked(&g.sim.ws, form) {return}
	}
	ref, is_record := gamedb.ref_by_formid(&g.db, form)
	base := worldstate.ref_base(&g.sim.ws, &g.db, form)
	if base == 0 {return}
	if j, jailed := g.sim.ws.jailed[by]; jailed && gamedb.is_door(&g.db, base) && worldstate.is_locked(&g.sim.ws, &g.db, form) && worldstate.ref_cell(&g.sim.ws, &g.db, form) == j.cell {
		worldstate.report_crime(&g.sim.ws, &g.db, by, 0, .Escape, 0) // a jailbreak: a locked door of its own cell opened (CRVA escape)
	}
	audio.activate_sound(&g.audio, &g.v, &g.db, &g.sim.ws, form)
	switch kind := Activate_Kind.Door if is_record && ref.has_tp else classify_base(&g.db, base); kind {
	case .Door:
		if !ref.has_tp {break}
		if by != g.sim.ws.player {
			move_through_door(g, by, ref.teleport)
			break
		}
		// Open-interiors mode has its own walk-in, so doors are left to it there.
		if g.interiors_on {break}
		send_parked(g, Evt_Door{Door_Hit{tp_door = ref.teleport.door, tp_pos = ref.teleport.pos, tp_rot = ref.teleport.rot, ok = true}})
	case .Item:
		take_item(g, form, base, by)
	case .Book:
		if by == g.sim.ws.player && read_book(g, form, base) {
			worldstate.set_disabled(&g.sim.ws, form, worldstate.ref_cell(&g.sim.ws, &g.db, form), true) // a learned tome is used up
			worldstate.mark_scene_dirty(&g.sim.ws, form)
			log.infof("read: %q", interact_subject(g, form))
		} else {
			take_item(g, form, base, by)
		}
	case .Flora:
		harvest(g, form, base, by)
	case .Container:
		if by == g.sim.ws.player {send_parked(g, Evt_Open_Container{form})}
	// (hole mount-attach :tags (threading animation player unclaimed) :sev gap :needs (anim-state-snapshot)) a rider must draw on the horse's saddle bone. Wanted: 'attached to (form, bone)' in the actor view, so main draws the rider after the horse; the sim keeps the rider's capsule on the horse.
	// (hole mounts :tags (animation player ai unclaimed) :sev gap :needs (actor-states)) activating a horse opens its dialogue: nobody rides, and IsOnMount, GetMount and Dismount have no state.
	case .Actor, .Body:
		if by != g.sim.ws.player {break}
		if worldstate.is_dead(&g.sim.ws, &g.db, form) {send_parked(g, Evt_Open_Container{form})} else {open_dialogue(g, form)}
	case .None, .Activator:
		if by == g.sim.ws.player && by in g.sim.ws.jailed && ai.is_bed(&g.sim.agents, &g.sim.ws, &g.db, form) {
			worldstate.ask_jail_bed(&g.sim.ws)
			break
		}
		if by == g.sim.ws.player {log.infof("activate: %q [%s] — no menu yet (stub)", interact_subject(g, form), activate_kind_tag[kind])}
	}
}

// move_through_door puts an actor other than the player at a load door's far side.
@(private = "file")
move_through_door :: proc(g: ^Game, actor: Form_ID, tp: esm.Teleport) {
	worldstate.relocate(&g.sim.ws, actor, worldstate.ref_cell(&g.sim.ws, &g.db, tp.door), tp.pos, tp.rot)
}

// tick_activations runs the activations scripts requested since the last tick.
tick_activations :: proc(g: ^Game) {
	for a in g.sim.ws.activations {activate(g, a.target, a.by, a.default_only)}
	clear(&g.sim.ws.activations)
}

// grab_begin lifts the pressed item into a telekinesis grab at a comfortable default reach.
@(private = "file")
grab_begin :: proc(g: ^Game) {
	g.sim.interact.grabbing = true
	g.sim.interact.body = g.sim.interact.press_body
	g.sim.interact.dist = GRAB_DIST_0
	log.infof("grab: holding 0x%08X — mouse to aim, wheel for reach, release to drop", u32(g.sim.interact.press_form))
}

// grab_update servos the held body toward the aim point (down the crosshair ray at the wheel-set
// reach) each frame. Velocity-driven (not teleported) so it collides on the way and the clutter
// clamps keep it stable; the body stays awake because we set its velocity every frame.
@(private = "file")
grab_update :: proc(g: ^Game) {
	turned := g.sim.input.wheel - g.sim.input_was.wheel
	g.sim.interact.dist = clamp(g.sim.interact.dist + turned * GRAB_SCROLL, GRAB_MIN_DIST, GRAB_MAX_DIST)
	target := g.sim.input.eye + g.sim.input.aim_dir * g.sim.interact.dist
	phys := active_space(g).phys
	cur := physics.body_position(phys, g.sim.interact.body)
	vel := (target - cur) * GRAB_GAIN
	if sp := smath.length3(vel); sp > GRAB_MAX_VEL {
		vel = vel * (GRAB_MAX_VEL / sp)
	}
	physics.kick(phys, g.sim.interact.body, vel) // wakes + sets velocity
}

// take_item puts a world item in an actor's pack: its whole stack goes in (OnItemAdded, and
// OnContainerChanged to the ref's scripts, next tick) and the ref leaves the world, carried.
take_item :: proc(g: ^Game, form, base, by: Form_ID) {
	c := script.Call{ws = &g.sim.ws, db = &g.db}
	script.take(&c, form, base, by)
	if by == g.sim.ws.player {log.infof("take: %q", interact_subject(g, form))}
}

// read_book is the player reading a book: OnRead to its ref (for a book in the pack, a carried
// ref of it), then what reading teaches. True when the book is used up.
read_book :: proc(g: ^Game, ref, base: Form_ID) -> bool {
	if g.repl_ok && ref != 0 {
		slua.sync_refs(&g.sim.repl.vm) // a stack script.item_stack just made gets its instance first
		slua.send(&g.sim.repl.vm, ref, "OnRead")
	}
	return worldstate.read_book(&g.sim.ws, &g.db, g.sim.ws.player, base)
}

// harvest gives an actor a plant's produce, rolled at its zone level, once until its cell resets.
harvest :: proc(g: ^Game, form, base, by: Form_ID) {
	produce, ok := g.db.produce[base]
	if !ok || worldstate.harvested(&g.sim.ws, form) {return}
	c := script.Call{ws = &g.sim.ws, db = &g.db}
	rolled := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	worldstate.roll(&g.sim.ws, &g.db, produce, worldstate.zone_level(&g.sim.ws, &g.db, gamedb.zone_of(&g.db, form)), 1, &rolled)
	for e in rolled {script.move_items(&c, {base = e.item, to = by, count = e.count})}
	worldstate.set_harvested(&g.sim.ws, form, worldstate.ref_cell(&g.sim.ws, &g.db, form))
	if by == g.sim.ws.player {log.infof("harvest: %q", interact_subject(g, form))}
}

// interact_subject is a ref's display name for a log line, or a placeholder when it's unnamed.
@(private = "file")
interact_subject :: proc(g: ^Game, form: Form_ID) -> string {
	name := gamedb.name_of(&g.db, form)
	return name if name != "" else "(unnamed)"
}
