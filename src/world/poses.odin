package world

// The dynamic bodies as main draws them: each one's last step, keyed by the ref it stands for, so
// drawing needs neither the physics world nor a body ID.

import smath "../math"
import "../physics"

// Pose_Key names a dynamic body by its ref: `part` is the collision-body index of an articulated
// ref's body, or WHOLE for a ref one body carries. The dev drop-test balls use ref 0 and their index.
Pose_Key :: struct {
	form: Form_ID,
	part: i32,
}

WHOLE :: i32(-1)

Body_Step :: struct {
	from, to: physics.Pose,
}

Poses :: struct {
	at: map[Pose_Key]Body_Step,
}

// capture_poses fills `p` with the last step of every dynamic body of the space's live refs.
capture_poses :: proc(sp: ^Space, p: ^Poses) {
	clear(&p.at)
	if sp == nil || sp.phys == nil {return}
	for _, &c in sp.cells {
		for &r in c.refs {
			if r.dyn_body != 0 {add_pose(p, sp.phys, {r.form_id, WHOLE}, r.dyn_body)}
			for b, i in r.dyn_bodies {
				if b != 0 {add_pose(p, sp.phys, {r.form_id, i32(i)}, b)}
			}
		}
	}
}

// mark_posed flags the scene's instances that `p` has a pose for, so drawing looks theirs up. A
// flag outlives its body harmlessly: the lookup misses and the instance draws where it was placed.
mark_posed :: proc(s: ^Scene, p: ^Poses) {
	for key in p.at {
		if inst, _, ok := find_resident(s, key.form); ok {inst.posed = true}
	}
}

add_pose :: proc(p: ^Poses, w: ^physics.World, key: Pose_Key, b: physics.Body) {
	from, to := physics.body_step(w, b)
	p.at[key] = {from, to}
}

// posed is a body's transform `alpha` (0..1) of the way through its last step; false when `p` has
// no such body.
posed :: proc(p: ^Poses, key: Pose_Key, alpha: f32) -> (m: smath.Mat4, ok: bool) {
	st := p.at[key] or_return
	return physics.pose_blend(st.from, st.to, alpha), true
}

poses_destroy :: proc(p: ^Poses) {
	delete(p.at)
}
