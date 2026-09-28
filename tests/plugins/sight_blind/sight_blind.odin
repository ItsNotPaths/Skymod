package sight_blind

// A test plugin: replaces sight's level with one that sees nothing, and keeps the rest.

import "../../../src/sight"

@(export)
skymod_sight :: proc "c" (version: u32, table: rawptr) -> b32 {
	if version != sight.VERSION {return false}
	(^sight.Table)(table).level = blind
	return true
}

blind :: proc "c" (h: ^sight.Host, viewer, target: sight.Form_ID, mode: sight.Mode) -> f32 {
	return 0
}
