package combat_calm

// A test plugin: replaces the combat brain with one under which nobody fights.

import "../../../src/combat"
import "../../../src/plugin"

@(export)
skymod_combat :: proc "c" (version: u32, table: rawptr) -> b32 {
	if version != combat.VERSION {return false}
	(^combat.Table)(table).tick = calm
	return true
}

calm :: proc "c" (inp: ^combat.Input) {
	for f in plugin.items(inp.fighters) {inp.host.set(inp.host.data, f.actor, {})}
}
