package unit_tests

import "base:runtime"
import "core:testing"
import "../../src/combat"
import "../../src/plugin"

// Fake_Combat answers every query the same way for every actor and keeps what the brain sets.
Fake_Combat :: struct {
	world:      plugin.World,
	ctx:        runtime.Context,
	detected:   bool,
	hostile:    bool,
	aggression: f32,
	confidence: f32,
	aggro:      combat.Aggro,
	sets:       [dynamic]combat.Fighter,
}

fake_combat_host :: proc(h: ^Fake_Combat) -> combat.Host {
	h.world = fake_world(h)
	w := &h.world
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
	load_test_plugins(&p)
	table := combat.BUILTIN
	plugin.apply(&p, combat.SEAM, combat.VERSION, &table)
	h := Fake_Combat{confidence = 2}
	testing.expect_value(t, fight(t, &table, &h, {actor = 0xA1, struck_by = 0x14}), combat.Fight{})
}

// fake_gear_world is one attacker (0xA1, OneHanded 50, UnarmedDamage 4) and a target with
// HeavyArmor 50. 0xC1 is a heavy cuirass (rating 25), 0xD1 a sword (skill 6, crit damage 3).
fake_gear_world :: proc(w: ^plugin.World) {
	w^ = fake_world(nil)
	w.actor_value = proc "c" (data: rawptr, actor: plugin.Form_ID, name: cstring, part: plugin.AV_Part) -> f32 {
		switch name {
		case "OneHanded", "HeavyArmor": return 50
		case "UnarmedDamage":           return 4
		}
		return 0
	}
	w.record = proc "c" (data: rawptr, form: plugin.Form_ID, kind: plugin.Record_Kind, out: rawptr) -> bool {
		s := (^plugin.Equip_Slot)(out)
		switch form {
		case 0xC1: s.gear = {skill = -1, armor_rating = 25, armor_type = .Heavy}
		case 0xD1: s.weapon_type, s.gear = 1, {skill = 6, crit_damage = 3}
		case:      return false
		}
		return kind == .Equip_Slot
	}
}

// A hit scales with the weapon skill, gains a crit's damage and a power or sneak attack's
// multiplier, and loses what the target's armor stops; the hooks' parts change each number.
@(test)
test_damage_gear :: proc(t: ^testing.T) {
	w: plugin.World
	fake_gear_world(&w)
	damage := combat.BUILTIN.damage
	cuirass := []combat.Piece{{0xC1, combat.KEEP}}
	sword := combat.attack(0xA1, 0xB1, 0xD1)
	sword.roll, sword.armor = 0.5, plugin.span(cuirass)
	// 10 x (1 + 0.5 x 50%) = 12.5; the NPC's cuirass: 25 x (1 + 1.5 x 50%) = 43.75 at 0.12% = 5.25%
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-4}
	testing.expect(t, near(damage(&w, sword, 10), 12.5 * (1 - 0.0525)), "sword on armor")
	bare := sword
	bare.armor = {}
	testing.expect_value(t, damage(&w, bare, 10), 12.5)
	fists := bare
	fists.weapon = 0
	testing.expect_value(t, damage(&w, fists, 10), 4) // UnarmedDamage

	perked := bare
	perked.damage = {add = 2, mult = 2}
	testing.expect_value(t, damage(&w, perked, 10), 30) // (10 + 2) x 2 x 1.25
	perked.damage = {set = 1, has_set = true}
	testing.expect_value(t, damage(&w, perked, 10), 1.25)
	pierced := sword
	pierced.armor_pen = {mult = 0}
	testing.expect_value(t, damage(&w, pierced, 10), 12.5) // armor ignored
	doubled := []combat.Piece{{0xC1, {mult = 2}}}
	thick := sword
	thick.armor = plugin.span(doubled)
	testing.expect(t, near(damage(&w, thick, 10), 12.5 * (1 - 0.105)), "a piece's rating doubled")

	// the sword's CRDT adds 3 on a crit: CritChance 0 never, a perk's 60% over the 0.5 roll does
	crit := bare
	crit.crit_chance = {set = 60, has_set = true}
	testing.expect_value(t, damage(&w, crit, 10), 15.5)
	crit.crit_damage = {mult = 2}
	testing.expect_value(t, damage(&w, crit, 10), 18.5)
	crit.roll = 0.7
	testing.expect_value(t, damage(&w, crit, 10), 12.5)
	power := bare
	power.kind = {.Power}
	testing.expect_value(t, damage(&w, power, 10), 25) // 1 + fPowerAttackDefaultBonus
	sneak := bare
	sneak.kind = {.Sneak}
	testing.expect_value(t, damage(&w, sneak, 10), 37.5) // a one-handed sword: x3
	sneak.sneak_mult = {mult = 2.5}
	testing.expect_value(t, damage(&w, sneak, 10), 93.75)
}
