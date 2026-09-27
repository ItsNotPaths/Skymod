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
import "../audio"
import "../formats/esm"
import "../gamedb"
import smath "../math"
import "../input"
import "../physics"
import "../render"
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

// Telekinesis servo: each frame we drive the held body's velocity toward the aim point (a spot down
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

// frame_interact resolves the crosshair target for this frame and drives the Activate action against
// it. Runs after frame_traversal (auto doors) and frame_inspect, before frame_hud (which publishes
// g.fr.act to the prompt and draws). A no-op'd target just leaves the reticle.
frame_interact :: proc(g: ^Game) {
	if g.menu != .None {return}
	g.fr.act = resolve_activation(g)
	act_down := input.held(&g.imgr, "Activate")

	// 1) Already grabbing: steer the body while Activate stays down; release = drop.
	if g.interact.grabbing {
		if act_down && g.fr.active_scene != nil && g.fr.active_scene.phys != nil {
			grab_update(g)
		} else {
			g.interact.grabbing = false
			log.info("grab: released")
		}
		return
	}

	// 2) A press is in flight on a physics item: measure how long it's held. Cross GRAB_HOLD_S while
	//    still down → promote to a grab; release before that → it was a tap → collect.
	if g.interact.pressing {
		if act_down {
			g.interact.held_s += g.p.dt
			if g.interact.held_s >= GRAB_HOLD_S {
				grab_begin(g)
				g.interact.pressing = false
			}
		} else {
			activate(g, g.interact.press_form, formid.PLAYER)
			g.interact.pressing = false
		}
		return
	}

	// 3) A fresh Activate edge on what the crosshair is on. An unblocked physics item waits to learn
	//    tap (activate) from hold (grab); anything else activates now.
	if input.fired(&g.imgr, "Activate") && g.fr.act.present {
		tgt := g.fr.act
		if tgt.dyn_body != 0 && !worldstate.activation_blocked(&g.ws, tgt.form) {
			g.interact.pressing = true
			g.interact.press_body = tgt.dyn_body
			g.interact.press_form = tgt.form
			g.interact.held_s = 0
		} else {
			activate(g, tgt.form, formid.PLAYER)
		}
	}
}

// frame_cast casts the spell in a hand when its button fires, at what the crosshair is on, and
// the Sneak key puts the player in or out of sneak mode.
frame_cast :: proc(g: ^Game) {
	if g.menu != .None {return}
	if input.fired(&g.imgr, "Sneak") {worldstate.set_sneaking(&g.ws, formid.PLAYER, !worldstate.is_sneaking(&g.ws, formid.PLAYER))}
	c := script.Call{ws = &g.ws, db = &g.db}
	target := g.fr.act.form if g.fr.act.present else 0
	if input.fired(&g.imgr, "CastLeft") {script.cast_hand(&c, formid.PLAYER, .LeftHand, target)}
	if input.fired(&g.imgr, "CastRight") {script.cast_hand(&c, formid.PLAYER, .RightHand, target)}
}

// (hole lockpicking :tags (ui player) :sev gap) a locked door or container opens like any other: no key check, no lockpicking screen, no Lockpicking XP.
// activate is the one activation path, for the Activate key and for a script's Activate, by any
// actor: OnActivate is queued for the ref's scripts (it runs at the next tick, after the default
// action, as in Papyrus), then the default action runs unless a script blocked it. `default_only`
// sends no event and ignores the block (abDefaultProcessingOnly). Menus open for the player only.
activate :: proc(g: ^Game, form, by: Form_ID, default_only := false) {
	if !default_only {
		if g.repl_ok {slua.send(&g.repl.vm, form, "OnActivate", by)}
		if worldstate.activation_blocked(&g.ws, form) {return}
	}
	ref, is_record := gamedb.ref_by_formid(&g.db, form)
	base := worldstate.ref_base(&g.ws, &g.db, form)
	if base == 0 {return}
	audio.activate_sound(&g.audio, &g.v, &g.db, &g.ws, form)
	switch kind := Activate_Kind.Door if is_record && ref.has_tp else classify_base(&g.db, base); kind {
	case .Door:
		if !ref.has_tp {break}
		if by != formid.PLAYER {
			move_through_door(g, by, ref.teleport)
			break
		}
		// Open-interiors mode has its own walk-in, so doors are left to it there.
		if g.interiors_on {break}
		hit := Door_Hit{tp_door = ref.teleport.door, tp_pos = ref.teleport.pos, tp_rot = ref.teleport.rot, ok = true}
		if np, nyaw, tk := go_through(&g.trav, hit); tk != .None {
			player_teleport(g, np, nyaw, 0)
			traversal_finish_load(g, tk)
		}
	case .Item:
		take_item(g, form, base, by)
	case .Book:
		if by == formid.PLAYER && read_book(g, form, base) {
			worldstate.set_disabled(&g.ws, form, worldstate.ref_cell(&g.ws, &g.db, form), true) // a learned tome is used up
			worldstate.mark_scene_dirty(&g.ws, form)
			log.infof("read: %q", interact_subject(g, form))
		} else {
			take_item(g, form, base, by)
		}
	case .Flora:
		harvest(g, form, base, by)
	case .Container:
		if by == formid.PLAYER {open_container(g, form)}
	// (hole mounts :tags (animation player ai unclaimed) :sev gap :needs (actor-states)) activating a horse opens its dialogue: nobody rides, and IsOnMount, GetMount and Dismount have no state.
	case .Actor, .Body:
		if by != formid.PLAYER {break}
		if worldstate.is_dead(&g.ws, form) {open_container(g, form)} else {open_dialogue(g, form)}
	case .None, .Activator:
		if by == formid.PLAYER {log.infof("activate: %q [%s] — no menu yet (stub)", interact_subject(g, form), activate_kind_tag[kind])}
	}
}

// move_through_door puts an actor other than the player at a load door's far side.
@(private = "file")
move_through_door :: proc(g: ^Game, actor: Form_ID, tp: esm.Teleport) {
	worldstate.relocate(&g.ws, actor, worldstate.ref_cell(&g.ws, &g.db, tp.door), tp.pos, tp.rot)
}

// tick_activations runs the activations scripts requested since the last tick.
tick_activations :: proc(g: ^Game) {
	for a in g.ws.activations {activate(g, a.target, a.by, a.default_only)}
	clear(&g.ws.activations)
}

// grab_begin lifts the pressed item into a telekinesis grab at a comfortable default reach.
@(private = "file")
grab_begin :: proc(g: ^Game) {
	g.interact.grabbing = true
	g.interact.body = g.interact.press_body
	g.interact.dist = GRAB_DIST_0
	log.infof("grab: holding 0x%08X — mouse to aim, wheel for reach, release to drop", u32(g.interact.press_form))
}

// grab_update servos the held body toward the aim point (down the crosshair ray at the wheel-set
// reach) each frame. Velocity-driven (not teleported) so it collides on the way and the clutter
// clamps keep it stable; the body stays awake because we set its velocity every frame.
@(private = "file")
grab_update :: proc(g: ^Game) {
	if g.p.input.scroll != 0 {
		g.interact.dist = clamp(g.interact.dist + g.p.input.scroll * GRAB_SCROLL, GRAB_MIN_DIST, GRAB_MAX_DIST)
	}
	ro, rd := camera_ray(g.cam, render.aspect(&g.r), {0, 0}) // crosshair
	target := ro + rd * g.interact.dist
	cur := physics.body_position(g.fr.active_scene.phys, g.interact.body)
	vel := (target - cur) * GRAB_GAIN
	if sp := smath.length3(vel); sp > GRAB_MAX_VEL {
		vel = vel * (GRAB_MAX_VEL / sp)
	}
	physics.kick(g.fr.active_scene.phys, g.interact.body, vel) // wakes + sets velocity
}

// take_item puts a world item in an actor's pack: its whole stack goes in (OnItemAdded, and
// OnContainerChanged to the ref's scripts, next tick) and the ref leaves the world, carried.
take_item :: proc(g: ^Game, form, base, by: Form_ID) {
	c := script.Call{ws = &g.ws, db = &g.db}
	script.take(&c, form, base, by)
	if by == formid.PLAYER {log.infof("take: %q", interact_subject(g, form))}
}

// read_book is the player reading a book: OnRead to its ref (for a book in the pack, a carried
// ref of it), then what reading teaches. True when the book is used up.
read_book :: proc(g: ^Game, ref, base: Form_ID) -> bool {
	if g.repl_ok && ref != 0 {
		slua.sync_refs(&g.repl.vm) // a stack script.item_stack just made gets its instance first
		slua.send(&g.repl.vm, ref, "OnRead")
	}
	return worldstate.read_book(&g.ws, &g.db, formid.PLAYER, base)
}

// harvest gives an actor a plant's produce, rolled at its zone level, once until its cell resets.
harvest :: proc(g: ^Game, form, base, by: Form_ID) {
	produce, ok := g.db.produce[base]
	if !ok || worldstate.harvested(&g.ws, form) {return}
	c := script.Call{ws = &g.ws, db = &g.db}
	rolled := make([dynamic]gamedb.Content_Entry, context.temp_allocator)
	worldstate.roll(&g.ws, &g.db, produce, worldstate.zone_level(&g.ws, &g.db, gamedb.zone_of(&g.db, form)), 1, &rolled)
	for e in rolled {script.move_items(&c, {base = e.item, to = by, count = e.count})}
	worldstate.set_harvested(&g.ws, form, worldstate.ref_cell(&g.ws, &g.db, form))
	if by == formid.PLAYER {log.infof("harvest: %q", interact_subject(g, form))}
}

// interact_subject is a ref's display name for a log line, or a placeholder when it's unnamed.
@(private = "file")
interact_subject :: proc(g: ^Game, form: Form_ID) -> string {
	name := gamedb.name_of(&g.db, form)
	return name if name != "" else "(unnamed)"
}
