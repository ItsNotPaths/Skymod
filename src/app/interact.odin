package main

// Crosshair interaction: the single place the Activate press is turned into a real action against
// whatever the reticle is actually on (resolve_activation), replacing the old proximity "nearest
// door" scan. One tap does the obvious thing per target kind; a press-and-hold on a physics item
// lifts it into a telekinesis grab you steer with the mouse (aim) and wheel (reach).
//
//   Door       → cross it (go_through, straight from the picked door's XTEL — no proximity scan).
//   Phys item  → TAP: collect into the pack (stubbed — no player inventory yet, just a log).
//                HOLD: grab it and float it in front of you; release to drop.
//   Container  → open (stubbed — no container/inventory UI yet, just a log).
//   Other      → activate (stubbed — dialogue/loot menus hook in here later).
//
// Auto-load doors (invisible cave/dungeon markers) are NOT handled here — the ray never hits them,
// so they stay proximity-fired in frame_traversal, exactly as before.

import "core:log"
import "../gamedb"
import smath "../math"
import "../input"
import "../physics"
import "../render"

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
			collect_stub(g, g.interact.press_form)
			g.interact.pressing = false
		}
		return
	}

	// 3) A fresh Activate edge: dispatch on what the crosshair is on.
	if input.fired(&g.imgr, "Activate") && g.fr.act.present {
		tgt := g.fr.act
		switch {
		case tgt.kind == .Door:
			// Cross straight from the picked door's XTEL — no proximity "nearest door" scan. (Open-
			// interiors mode has its own walk-in, so we leave doors to it there and do nothing here.)
			if g.interiors_on {break}
			hit := Door_Hit{tp_door = tgt.tp_door, tp_pos = tgt.tp_pos, tp_rot = tgt.tp_rot, ok = true}
			if np, nyaw, kind := go_through(&g.trav, hit); kind != .None {
				g.cam.pos, g.cam.yaw, g.cam.pitch = np, nyaw, 0
				traversal_finish_load(g, kind)
			}
		case tgt.dyn_body != 0:
			// A movable physics item: begin a press so the release/hold resolves to collect vs grab.
			g.interact.pressing = true
			g.interact.press_body = tgt.dyn_body
			g.interact.press_form = tgt.form
			g.interact.held_s = 0
		case tgt.kind == .Container:
			log.infof("activate: open container %q — container/inventory UI not built yet (stub)", interact_subject(tgt))
		case:
			log.infof("activate: %q [%s] — no menu yet (stub)", interact_subject(tgt), activate_kind_tag[tgt.kind])
		}
	}
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

// collect_stub is the tap-to-pick-up path: it belongs in the player's inventory, which doesn't exist
// yet, so for now it just logs (the item stays in the world). Real pickup (remove the ref + add the
// base item to the pack) hooks in here once inventory lands.
@(private = "file")
collect_stub :: proc(g: ^Game, form: Form_ID) {
	name := gamedb.name_of(&g.db, form)
	if name == "" {name = "(unnamed)"}
	log.infof("collect: pick up %q (0x%08X) — player inventory not built yet (stub)", name, u32(form))
}

// interact_subject is the target's display name for a log line, or a placeholder when it's unnamed.
@(private = "file")
interact_subject :: proc(t: Activation_Target) -> string {
	return t.name if t.name != "" else "(unnamed)"
}
