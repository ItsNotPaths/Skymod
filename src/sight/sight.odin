package sight

// Line of sight (CK wiki HasLOS, GetLineOfSight, RegisterForLOS; build/out/wsQ/wiki/). The player
// sees through the camera: three picks at the target's top, middle and bottom, each inside the view
// and unblocked. An NPC sees only actors.

import smath "../math"
import "../formid"
import "../gamedb"
import "../physics"
import "../worldstate"

Form_ID :: formid.Form_ID

// View is what the player sees, published by the app before each script phase.
View :: struct {
	space: ^physics.World, // the active scene's physics; nil = nothing to see
	eye:   smath.Vec3,
	vp:    smath.Mat4,
}

view: View

// NPC_EYE is how high an NPC's eye sits, as a part of its height.
NPC_EYE :: f32(0.9)

// (hole los-detection :tags (query ai) :sev gap :needs (ai-agent)) an NPC's LOS is one ray from its eye to the target's middle; Skyrim asks the detection system (view cone, light, sneak).
has_los :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID) -> bool {
	if view.space == nil || !worldstate.ref_3d_loaded(ws, db, target) {return false}
	picks := target_picks(ws, db, target)
	if viewer == formid.PLAYER {
		for p in picks {
			if in_view(p) && clear(viewer, target, view.eye, p) {return true}
		}
		return false
	}
	if !is_actor(ws, db, target) || !worldstate.ref_3d_loaded(ws, db, viewer) {return false}
	box := worldstate.actor_box(ws, db, viewer)
	eye := worldstate.ref_pos(ws, db, viewer) + {0, 0, box[1].z * NPC_EYE}
	return clear(viewer, target, eye, picks[1])
}

// target_picks are the target's bottom, middle and top, inside its bounds.
@(private)
target_picks :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, target: Form_ID) -> [3]smath.Vec3 {
	lo, hi: f32
	if is_actor(ws, db, target) {
		box := worldstate.actor_box(ws, db, target)
		lo, hi = box[0].z, box[1].z
	} else if box, ok := gamedb.base_bounds(db, worldstate.ref_base(ws, db, target)); ok {
		s := worldstate.ref_scale(ws, db, target)
		lo, hi = box[0].z * s, box[1].z * s
	}
	pos := worldstate.ref_pos(ws, db, target)
	h := hi - lo
	return {pos + {0, 0, lo + 0.1 * h}, pos + {0, 0, lo + 0.5 * h}, pos + {0, 0, lo + 0.9 * h}}
}

// clear reports whether the first body on the ray that is not the viewer's is the target's.
@(private)
clear :: proc(viewer, target: Form_ID, from, to: smath.Vec3) -> bool {
	for h in physics.ray_hits(view.space, from, to) {
		if h.owner == u64(viewer) {continue}
		return h.owner == u64(target)
	}
	return true
}

@(private)
in_view :: proc(p: smath.Vec3) -> bool {
	c := view.vp * [4]f32{p.x, p.y, p.z, 1}
	return c.w > 0 && abs(c.x) <= c.w && abs(c.y) <= c.w
}

@(private)
is_actor :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, ref: Form_ID) -> bool {
	return gamedb.is_actor(db, worldstate.ref_base(ws, db, ref))
}
