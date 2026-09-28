package worldstate

// Camera is the player's point of view, saved with the game. `dist` is how far behind the head the
// camera sits: 0 is first person, and the player's own body hides there. The wheel ramps it in
// ZOOM_STEP notches between THIRD_MIN and THIRD_MAX, and a notch past THIRD_MIN jumps the gap to 0.
Camera :: struct {
	dist:   f32,
	target: Form_ID, // Game.SetCameraTarget: the actor the camera follows; 0 = the player
}

ZOOM_STEP :: f32(40)
THIRD_MIN :: f32(80) // the closest third person
THIRD_MAX :: f32(400)

// zoom moves the camera one notch out or in.
zoom :: proc(c: ^Camera, out: bool) {
	d := c.dist + (ZOOM_STEP if out else -ZOOM_STEP)
	c.dist = (THIRD_MIN if out else 0) if d < THIRD_MIN else min(d, THIRD_MAX)
}

first_person :: proc(c: Camera) -> bool {return c.dist == 0}
