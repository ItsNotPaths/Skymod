package main

// Free-fly debug camera (ROADMAP Phase 0, step 5): the rig every world gets tested
// from. Z-up, right-handed world (matching Skyrim); yaw rotates about +Z, pitch
// tilts. Driven by platform.Input — no SDL here.

import "core:math"
import smath "../math"

Camera :: struct {
	pos:   smath.Vec3,
	yaw:   f32, // radians about +Z
	pitch: f32, // radians, clamped off the poles
}

CAM_FOV_Y :: f32(1.22173) // 70°
// Native Skyrim units (≈70/m): near/far span a whole interior, move speed is a few
// metres/s. D32_FLOAT depth keeps this range precise.
CAM_NEAR :: f32(5.0)
CAM_FAR :: f32(20000.0)
PITCH_LIMIT :: f32(1.55334) // ~89°
LOOK_SENSITIVITY :: f32(0.0025)
MOVE_SPEED :: f32(400.0)
FAST_MULT :: f32(6.0)

camera_forward :: proc(c: Camera) -> smath.Vec3 {
	cp := math.cos(c.pitch)
	return {cp * math.cos(c.yaw), cp * math.sin(c.yaw), math.sin(c.pitch)}
}

// camera_update applies mouse look (when captured) and WASD/QE motion. `move` is
// per-axis input in [-1,1]: x=forward, y=right, z=up. `look` is mouse delta px.
camera_update :: proc(c: ^Camera, move: smath.Vec3, look: [2]f32, fast: bool, dt: f32) {
	c.yaw -= look.x * LOOK_SENSITIVITY
	c.pitch -= look.y * LOOK_SENSITIVITY
	c.pitch = clamp(c.pitch, -PITCH_LIMIT, PITCH_LIMIT)

	fwd := camera_forward(c^)
	right := smath.normalize3(smath.cross3(fwd, {0, 0, 1}))
	up := smath.Vec3{0, 0, 1}
	step := MOVE_SPEED * (FAST_MULT if fast else 1) * dt
	c.pos += smath.scale3(fwd, move.x * step)
	c.pos += smath.scale3(right, move.y * step)
	c.pos += smath.scale3(up, move.z * step)
}

camera_view_proj :: proc(c: Camera, aspect: f32) -> smath.Mat4 {
	eye := c.pos
	center := eye + camera_forward(c)
	view := smath.look_at_rh(eye, center, {0, 0, 1})
	proj := smath.perspective_rh_zo(CAM_FOV_Y, aspect, CAM_NEAR, CAM_FAR)
	return proj * view
}
