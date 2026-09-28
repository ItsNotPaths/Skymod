package detection_blind

// A test plugin: replaces detection's judge with one that never detects, and keeps the built-in tick.

import "../../../src/detection"

@(export)
skymod_detection :: proc "c" (version: u32, table: rawptr) -> b32 {
	if version != detection.VERSION {return false}
	(^detection.Table)(table).judge = blind
	return true
}

blind :: proc "c" (was: detection.Awareness, s: detection.Senses, dt: f32) -> detection.Awareness {
	return {}
}
