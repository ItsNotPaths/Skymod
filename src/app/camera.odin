package main

// Free-fly debug camera (ROADMAP Phase 0, step 5): the rig every world gets tested
// from. Z-up, right-handed world (matching Skyrim); yaw rotates about +Z, pitch
// tilts. Driven by platform.Input — no SDL here.

import "core:math"
import smath "../math"
import "../physics"
import "../worldstate"

Camera :: struct {
	pos:   smath.Vec3,
	yaw:   f32, // radians about +Z
	pitch: f32, // radians, clamped off the poles
}

CAM_FOV_Y :: f32(1.22173) // 70°
// Native Skyrim units (≈70/m): near/far span a whole interior, move speed is a few
// metres/s. D32_FLOAT depth keeps this range precise.
CAM_NEAR :: f32(5.0)
// Far reaches across the streamed/LOD world so distant terrain is visible (≈64 cells).
// The 5..262144 span (~52000:1) would starve distant depth under a forward mapping; we use
// REVERSED-Z (perspective_rh_zo_rev) on the FLOAT depth buffer instead, which spreads
// precision ~uniformly across the range and kills the distant LOD/terrain/water z-fighting.
CAM_FAR :: f32(262144.0)
PITCH_LIMIT :: f32(1.55334) // ~89°
LOOK_SENSITIVITY :: f32(0.0025)
MOVE_SPEED :: f32(400.0)
FAST_MULT :: f32(6.0)

camera_forward :: proc(c: Camera) -> smath.Vec3 {
	cp := math.cos(c.pitch)
	return {cp * math.cos(c.yaw), cp * math.sin(c.yaw), math.sin(c.pitch)}
}

// camera_look applies mouse look. `look` is mouse delta px. Aiming is not simulation — it
// runs every rendered frame, never on the fixed tick, or the view quantizes to 60 Hz.
camera_look :: proc(c: ^Camera, look: [2]f32) {
	c.yaw -= look.x * LOOK_SENSITIVITY
	c.pitch = clamp(c.pitch - look.y * LOOK_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
}

// camera_fly moves the free camera. `move` is per-axis input in [-1,1]: x=forward, y=right,
// z=up. No solver, so it runs at render rate and needs no interpolation.
camera_fly :: proc(c: ^Camera, move: smath.Vec3, fast: bool, dt: f32) {
	fwd := camera_forward(c^)
	right := smath.normalize3(smath.cross3(fwd, {0, 0, 1}))
	up := smath.Vec3{0, 0, 1}
	step := MOVE_SPEED * (FAST_MULT if fast else 1) * dt
	c.pos += smath.scale3(fwd, move.x * step)
	c.pos += smath.scale3(right, move.y * step)
	c.pos += smath.scale3(up, move.z * step)
}

// camera_update is look + fly together, for the standalone test harnesses that have no tick loop.
camera_update :: proc(c: ^Camera, move: smath.Vec3, look: [2]f32, fast: bool, dt: f32) {
	camera_look(c, look)
	camera_fly(c, move, fast, dt)
}

// camera_ray builds a world-space ray (origin at the eye) through a screen point given in
// normalized device coords (`ndc`: x right, y up, both [-1,1]). Derived from the camera
// basis + FOV so it matches perspective_rh_zo exactly — used to pick the model under the
// mouse cursor (no matrix inverse needed).
camera_ray :: proc(c: Camera, aspect: f32, ndc: [2]f32) -> (origin, dir: smath.Vec3) {
	fwd := camera_forward(c)
	right := smath.normalize3(smath.cross3(fwd, {0, 0, 1}))
	up := smath.cross3(right, fwd) // camera up (matches look_at_rh's u)
	ty := math.tan(CAM_FOV_Y * 0.5)
	tx := ty * aspect
	d := fwd + smath.scale3(right, ndc.x * tx) + smath.scale3(up, ndc.y * ty)
	return c.pos, smath.normalize3(d)
}

camera_view_proj :: proc(c: Camera, aspect: f32) -> smath.Mat4 {
	return camera_proj(aspect) * camera_view(c)
}

camera_view :: proc(c: Camera) -> smath.Mat4 {
	return smath.look_at_rh(c.pos, c.pos + camera_forward(c), {0, 0, 1})
}

camera_proj :: proc(aspect: f32) -> smath.Mat4 {
	return smath.perspective_rh_zo_rev(CAM_FOV_Y, aspect, CAM_NEAR, CAM_FAR)
}

// The point of view, sim side: the wheel ramps worldstate.Camera.dist, and the tick works out how
// far back the camera fits.

CAMERA_CLEARANCE :: f32(10) // off the wall that pulled the camera in

// tick_view moves the camera a notch for each ZoomIn and ZoomOut since the last tick.
tick_view :: proc(g: ^Game) {
	in_, was := g.sim.input, g.sim.input_was
	if in_.in_menu || g.sim.interact.grabbing {return} // the grab's wheel sets its reach
	for _ in was.zoom_in ..< in_.zoom_in {worldstate.zoom(&g.sim.ws.camera, out = false)}
	for _ in was.zoom_out ..< in_.zoom_out {worldstate.zoom(&g.sim.ws.camera, out = true)}
}

// camera_boom is how far behind `head` the camera sits: its dist, pulled in before the first solid
// body behind the head.
camera_boom :: proc(g: ^Game, head: smath.Vec3) -> f32 {
	dist := g.sim.ws.camera.dist
	if dist == 0 || g.sim.noclip || g.sim.cur_phys == nil {return 0}
	for h in physics.ray_hits(g.sim.cur_phys, head, head - g.sim.input.aim_dir * dist) {
		if h.owner == u64(g.sim.ws.player) || h.owner == u64(worldstate.resolve(&g.sim.ws, g.sim.ws.camera.target)) {continue}
		return max(h.fraction * dist - CAMERA_CLEARANCE, 0)
	}
	return dist
}
