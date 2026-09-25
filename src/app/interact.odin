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
//   Other      → activate (stubbed — dialogue/loot menus hook in here later).
//
// Every activation, a key press or a script's Activate, goes through activate(): OnActivate to the
// ref's scripts, then the default action above unless a script called BlockActivation.
//
// Auto-load doors (invisible cave/dungeon markers) are NOT handled here — the ray never hits them,
// so they stay proximity-fired in frame_traversal, exactly as before.

import "core:log"
import "../gamedb"
import smath "../math"
import "../input"
import "../physics"
import "../render"
import "../script"
import slua "../script/lua"
import "../worldstate"
import "../formid"

// (hole activate-verbs :tags (ui player) :sev gap :needs (container-screen)) the activation verbs are logs — a tapped item is never moved into a pack and a container never opens anything. The screens they would open are their own holes (ui/source.odin).
// (hole dialogue-system :tags dialogue :sev blocker :needs (dialogue-records dialogue-screen)) activating an actor logs a line. No topic tree, no voice, no menu.

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

// (hole npc-activate :tags ai :sev gap :needs (ai-agent)) only the player's activations run the default action; an NPC activating a door or an item (a script's Activate) only sends OnActivate.
// (hole created-ref-activation :tags script :sev gap) a ref made at runtime (PlaceAtMe) has no default activation; it only gets OnActivate.

// activate is the one activation path, for the Activate key and for a script's Activate: OnActivate
// is queued for the ref's scripts (it runs at the next tick, after the default action, as in
// Papyrus), then the default action runs unless a script blocked it. `default_only` sends no event
// and ignores the block (abDefaultProcessingOnly).
activate :: proc(g: ^Game, form, by: Form_ID, default_only := false) {
	if !default_only {
		if g.repl_ok {slua.send(&g.repl.vm, form, "OnActivate", by)}
		if worldstate.activation_blocked(&g.ws, form) {return}
	}
	if by != formid.PLAYER {return}
	ref, ok := gamedb.ref_by_formid(&g.db, form)
	if !ok {return}
	switch kind := Activate_Kind.Door if ref.has_tp else classify_base(&g.db, ref.base); kind {
	case .Door:
		// Open-interiors mode has its own walk-in, so doors are left to it there.
		if g.interiors_on {break}
		hit := Door_Hit{tp_door = ref.teleport.door, tp_pos = ref.teleport.pos, tp_rot = ref.teleport.rot, ok = true}
		if np, nyaw, tk := go_through(&g.trav, hit); tk != .None {
			player_teleport(g, np, nyaw, 0)
			traversal_finish_load(g, tk)
		}
	case .Item:
		log.infof("collect: pick up %q (0x%08X) — player inventory not built yet (stub)", interact_subject(g, form), u32(form))
	case .Container:
		log.infof("activate: open container %q — container/inventory UI not built yet (stub)", interact_subject(g, form))
	case .None, .Actor, .Activator, .Flora, .Book:
		log.infof("activate: %q [%s] — no menu yet (stub)", interact_subject(g, form), activate_kind_tag[kind])
	}
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

// interact_subject is a ref's display name for a log line, or a placeholder when it's unnamed.
@(private = "file")
interact_subject :: proc(g: ^Game, form: Form_ID) -> string {
	name := gamedb.name_of(&g.db, form)
	return name if name != "" else "(unnamed)"
}
