package detection

// The stub model: seen in the cone and range = detected at once; out of sight it fades. The real
// model replaces judge_builtin, here or in a plugin, and nothing else.

// (hole sneak-detection :tags (ai player unclaimed) :sev gap :needs light-at-point) the real detection model: awareness that grows and decays with view direction, distance, movement, sneak (and the Sneak skill), light, noise and cutout cover. It replaces judge behind the same Senses and awareness store.
// (hole invisibility-read :tags (ai unclaimed) :sev gap) the Invisibility AV is written by its effects and read by nothing: an invisible actor is seen, and acting does not end it.
// Senses is what a viewer takes in of one target in one look.
Senses :: struct {
	sight:    f32, // sight.Mode.Cone, 0..1
	distance: f32,
	speed:    f32, // the target's speed, units/s
	sneaking: bool,
	light:    f32, // at the target, 0 dark .. 1 lit
	noise:    f32, // how loud the target is to the viewer, 0 silent
}

FADE :: f32(0.1) // awareness lost per second out of sight (guess)
DETECTED_AT :: f32(0.5)

// judge_builtin is the viewer's awareness of the target after `dt` seconds of these senses.
judge_builtin :: proc "c" (was: Awareness, s: Senses, dt: f32) -> Awareness {
	level := f32(1) if s.sight > 0 else max(was.level - FADE * dt, 0)
	return {level, level >= DETECTED_AT}
}
