package sight

// What one ref sees of another, 0..1, at three levels (Mode). The player sees through the camera; an
// NPC through its eyes, facing its heading. Line of sight (CK wiki HasLOS, GetLineOfSight,
// RegisterForLOS; build/out/wsQ/wiki/) sits on top: three picks at the target's bottom, middle and
// top, any clear one is enough, and an NPC sees only actors.

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

Mode :: enum u8 {
	Raw, // how much of the target the eye sees along its three picks; cutouts dim, solids block
	Cone, // Raw, counting only picks inside the view cone and range
	Detect, // the viewer's awareness of the target (detection)
}

// NPC_EYE is how high an NPC's eye sits, as a part of its height.
NPC_EYE :: f32(0.9)

// (hole view-cone-source :tags ai :sev polish) unsourced: the NPC view cone is 190 degrees from memory (fDetectionViewCone); Skyrim.esm has no such GMST (build/out/wsW/gmst.txt).
VIEW_CONE :: f32(190)

// (hole sight-seam :tags (plugins query) :sev struct) sight reads worldstate and physics directly, so a plugin can neither call it nor replace it. Wanted: host queries a plugin can call (viewer and target in, level out).
level :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID, mode: Mode) -> f32 {
	switch mode {
	case .Raw:    return seen(ws, db, viewer, target, false)
	case .Cone:   return seen(ws, db, viewer, target, true)
	case .Detect: return worldstate.awareness(ws, viewer, target).level
	}
	return 0
}

has_los :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID) -> bool {
	if viewer != ws.player && !is_actor(ws, db, target) {return false}
	return seen(ws, db, viewer, target, viewer == ws.player) > 0
}

// range is how far an NPC sees: fSneakMaxDistance, times fSneakExteriorDistanceMult outdoors.
range :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer: Form_ID) -> f32 {
	r := gamedb.setting_float(db, "fSneakMaxDistance", 2500)
	if c, ok := gamedb.cell_by_formid(db, worldstate.ref_cell(ws, db, viewer)); ok && !c.interior {
		r *= gamedb.setting_float(db, "fSneakExteriorDistanceMult", 2.1)
	}
	return r
}

// (hole light-at-point :tags (query ai unclaimed) :sev gap :needs (day-night weather-select)) nothing says how lit a point is (placed lights, sun), so detection cannot weigh light; every point reads fully lit. It runs on the sim: build it from LIGH refs, the cell lighting and the game clock and weather, never from render's lighting state.
// light_at is how lit a point is, 0 dark .. 1 fully lit.
light_at :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, p: smath.Vec3) -> f32 {
	return 1
}

// seen is the mean visibility of the target's three picks; `cone` counts only picks inside its view.
@(private)
seen :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer, target: Form_ID, cone: bool) -> f32 {
	if view.space == nil || !worldstate.ref_3d_loaded(ws, db, target) {return 0}
	eye := view.eye
	if viewer != ws.player {
		if !worldstate.ref_3d_loaded(ws, db, viewer) {return 0}
		eye = worldstate.ref_pos(ws, db, viewer) + {0, 0, worldstate.actor_box(ws, db, viewer)[1].z * NPC_EYE}
	}
	reach := range(ws, db, viewer)
	sum: f32
	for p in target_picks(ws, db, target) {
		if cone && !in_cone(ws, db, viewer, eye, p, reach) {continue}
		sum += visibility(viewer, target, eye, p)
	}
	return sum / 3
}

@(private)
in_cone :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, viewer: Form_ID, eye, p: smath.Vec3, reach: f32) -> bool {
	if viewer == ws.player {
		c := view.vp * [4]f32{p.x, p.y, p.z, 1}
		return c.w > 0 && abs(c.x) <= c.w && abs(c.y) <= c.w
	}
	d := p - eye
	if smath.length3(d) > reach {return false}
	return abs(worldstate.turn_to(ws, db, viewer, d)) <= VIEW_CONE / 2
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

// (hole cutout-cover-source :tags query :sev polish) unsourced: how much one cutout surface (a leaf canopy wall, a fence) hides; a guess.
CUTOUT_COVER :: f32(0.4)

// visibility is how much of the ray reaches the target, 0..1: a solid body blocks it, each cutout
// surface dims it.
@(private)
visibility :: proc(viewer, target: Form_ID, from, to: smath.Vec3) -> f32 {
	v := f32(1)
	for h in physics.ray_hits(view.space, from, to, cutouts = true) {
		if h.owner == u64(viewer) {continue}
		if h.owner == u64(target) {return v}
		if !h.cutout {return 0}
		v *= 1 - CUTOUT_COVER
	}
	return v
}

@(private)
is_actor :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, ref: Form_ID) -> bool {
	return gamedb.is_actor(db, worldstate.ref_base(ws, db, ref))
}
