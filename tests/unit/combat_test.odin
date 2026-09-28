package unit_tests

import "base:runtime"
import "core:testing"
import "../../src/combat"
import "../../src/plugin"

// Fake_Combat answers every query the same way for every actor and keeps what the brain sets.
Fake_Combat :: struct {
	ctx:        runtime.Context,
	detected:   bool,
	hostile:    bool,
	aggression: f32,
	confidence: f32,
	aggro:      combat.Aggro,
	sets:       [dynamic]combat.Fighter,
}

fake_combat_host :: proc(h: ^Fake_Combat) -> combat.Host {
	w := fake_world(h)
	w.awareness = proc "c" (data: rawptr, viewer, target: plugin.Form_ID) -> plugin.Awareness {return {0, (^Fake_Combat)(data).detected}}
	w.hostile = proc "c" (data: rawptr, a, b: plugin.Form_ID) -> bool {return (^Fake_Combat)(data).hostile}
	w.actor_value = proc "c" (data: rawptr, actor: plugin.Form_ID, name: cstring, part: plugin.AV_Part) -> f32 {
		h := (^Fake_Combat)(data)
		return h.confidence if name == "Confidence" else h.aggression
	}
	return {
		w,
		h,
		proc "c" (data: rawptr, actor: combat.Form_ID) -> combat.Aggro {return (^Fake_Combat)(data).aggro},
		proc "c" (data: rawptr, actor: combat.Form_ID, f: combat.Fight) {
			h := (^Fake_Combat)(data)
			context = h.ctx
			append(&h.sets, combat.Fighter{actor = actor, fight = f})
		},
	}
}

// fight runs one tick for NPC 0xA1 with the player 300 units away, and returns its fight.
fight :: proc(t: ^testing.T, table: ^combat.Table, h: ^Fake_Combat, f: combat.Fighter) -> combat.Fight {
	h.ctx = context
	h.sets = make([dynamic]combat.Fighter, context.temp_allocator)
	actors := []plugin.Actor{{id = 0xA1, space = 1}, {id = 0x14, space = 1, pos = {300, 0, 0}}}
	fighters := []combat.Fighter{f}
	inp := combat.Input{fake_combat_host(h), table, 1 / 60.0, plugin.span(actors), plugin.span(fighters)}
	table.tick(&inp)
	testing.expect_value(t, len(h.sets), 1)
	return h.sets[0].fight if len(h.sets) == 1 else {}
}

@(test)
test_combat_brain :: proc(t: ^testing.T) {
	table := combat.BUILTIN
	h := Fake_Combat{confidence = 2}
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1, struck_by = 0x14}).state, combat.State.Combat) // turns on whoever hit it
	h.confidence = 0
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1, struck_by = 0x14}).state, combat.State.Flee) // a coward runs
	h = {confidence = 2, detected = true, hostile = true, aggression = 1}
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1}), combat.Fight{.Combat, 0x14, 0}) // attacks a hostile it sees
	h = {confidence = 2, aggro = {on = true, warn = 500}}
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1}).state, combat.State.Warn) // inside its warn radius
	h.aggro = {}
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1}), combat.Fight{})
}

// A plugin that replaces the brain decides every fight.
@(test)
test_combat_plugin :: proc(t: ^testing.T) {
	p: plugin.Plugins
	defer plugin.destroy(&p)
	plugin.load(&p, {TEST_PLUGINS})
	table := combat.BUILTIN
	plugin.apply(&p, combat.SEAM, combat.VERSION, &table)
	h := Fake_Combat{confidence = 2}
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1, struck_by = 0x14}), combat.Fight{})
}
