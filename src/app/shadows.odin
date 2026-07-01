package main

// Cascaded shadow maps — cascade setup (ROADMAP full-scene-lighting Phase D1). Splits the camera
// frustum (out to the shadow distance) into SHADOW_CASCADES slices and fits a directional-light
// orthographic box around each, so near shadows are crisp and far ones still covered. The render
// side (src/render) owns the depth passes + sampling; this just computes the per-cascade light
// view-projection (for both rendering casters and sampling in the lit shader), a light-space
// frustum (to cull casters), and the far split distances (radial, for the shader to pick a cascade).
//
// SPHERE-FIT: each slice is bounded by a SPHERE (not a tight AABB), so the ortho box doesn't change
// size/orientation as the camera rotates — kills shadow-edge shimmer. The light eye is pulled back
// along the sun direction by an extra margin so tall casters (mountains, towers) toward the sun
// still render into the map even though they're outside the camera slice.

import "core:math"
import smath "../math"
import "../render"

CASCADE_PULLBACK :: f32(24000) // world units pulled toward the sun to catch tall off-slice casters
CASCADE_SPLIT_LAMBDA :: f32(0.72) // blend logarithmic↔uniform split distribution

// Cascades is the per-frame shadow setup the renderer consumes. (render.SHADOW_CASCADES is the
// shared cascade count — the same constant the GPU Light_Env array uses.)
Cascades :: struct {
	vp:     [render.SHADOW_CASCADES]smath.Mat4,    // light view-projection per cascade
	frusta: [render.SHADOW_CASCADES]smath.Frustum, // light frustum per cascade (caster culling)
	splits: [render.SHADOW_CASCADES]f32,           // far radial distance covered by each cascade (shader cascade select)
}

// compute_cascades builds the cascade setup from the camera, sun direction (toward the sun), and
// the shadow draw distance (world units). Mirrors camera_view_proj's basis so the slices line up
// with what's actually rendered.
compute_cascades :: proc(cam: Camera, aspect: f32, sun_dir: smath.Vec3, shadow_far: f32) -> Cascades {
	out: Cascades
	fwd := camera_forward(cam)
	right := smath.normalize3(smath.cross3(fwd, {0, 0, 1}))
	up := smath.cross3(right, fwd)
	ty := math.tan(CAM_FOV_Y * 0.5)
	tx := ty * aspect

	sd := smath.normalize3(sun_dir)
	light_up := smath.Vec3{0, 0, 1}
	if abs(sd.z) > 0.99 {
		light_up = {0, 1, 0} // sun near-vertical → avoid a degenerate up
	}

	near := CAM_NEAR
	far := max(shadow_far, near + 1)

	// Slice the [near, far] range — practical split (log/uniform blend) for even screen coverage.
	prev := near
	for i in 0 ..< render.SHADOW_CASCADES {
		p := f32(i + 1) / f32(render.SHADOW_CASCADES)
		logd := near * math.pow(far / near, p)
		uni := near + (far - near) * p
		d_far := CASCADE_SPLIT_LAMBDA * logd + (1 - CASCADE_SPLIT_LAMBDA) * uni
		d_near := prev

		// 8 corners of this slice (camera basis + FOV, same as camera_ray).
		c0 := slice_corners(cam.pos, fwd, right, up, tx, ty, d_near, d_far)
		// Bounding sphere of the corners.
		center := smath.Vec3{0, 0, 0}
		for c in c0 {
			center += c
		}
		center = smath.scale3(center, 1.0 / 8.0)
		radius: f32 = 0
		for c in c0 {
			radius = max(radius, smath.length3(c - center))
		}

		// Eye sits TOWARD the sun (sd points toward the sun) and looks back down the light's
		// travel direction (-sd) at the slice — pulled back an extra margin to catch tall casters.
		eye := center + smath.scale3(sd, radius + CASCADE_PULLBACK)
		view := smath.look_at_rh(eye, center, light_up)
		proj := smath.ortho_rh_zo(-radius, radius, -radius, radius, 0, 2 * radius + CASCADE_PULLBACK)
		vp := proj * view
		out.vp[i] = vp
		out.frusta[i] = smath.frustum_from_vp(vp)
		// Radial far for the shader's cascade pick: the far corners' distance from the eye.
		out.splits[i] = smath.length3(c0[4] - cam.pos)
		prev = d_far
	}
	return out
}

// slice_corners returns the 8 world-space corners of the camera frustum slice between view
// distances `dn` and `df`. Index 0-3 = near face, 4-7 = far face.
@(private = "file")
slice_corners :: proc(eye, fwd, right, up: smath.Vec3, tx, ty, dn, df: f32) -> [8]smath.Vec3 {
	c: [8]smath.Vec3
	dists := [2]f32{dn, df}
	for d, k in dists {
		hh := d * ty
		hw := d * tx
		ctr := eye + smath.scale3(fwd, d)
		c[k * 4 + 0] = ctr - smath.scale3(right, hw) - smath.scale3(up, hh)
		c[k * 4 + 1] = ctr + smath.scale3(right, hw) - smath.scale3(up, hh)
		c[k * 4 + 2] = ctr - smath.scale3(right, hw) + smath.scale3(up, hh)
		c[k * 4 + 3] = ctr + smath.scale3(right, hw) + smath.scale3(up, hh)
	}
	return c
}
