package unit_tests

import "core:testing"
import "../../src/gamedb"
import "../../src/plugin"
import "../../src/worldhost"
import "../../src/worldstate"

// record_world is a World over `db` for the record view tests.
record_world :: proc(d: ^worldhost.Data, ws: ^worldstate.World_State, db: ^gamedb.DB) -> plugin.World {
	d^ = {context, ws, db}
	return worldhost.world(d)
}

@(test)
test_record_spell :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.spells)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	cond := []gamedb.Condition{{function = 448, value = 1, text = "hi"}}
	fx := []gamedb.Magic_Effect_Ref{{effect = 0xE1, magnitude = 25, duration = 10, conditions = cond}}
	db.spells[0x5A] = {info = {cost = 40}, scroll = true, effects = fx}

	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	s: plugin.Spell
	testing.expect(t, plugin.record(&w, 0x5A, .Spell, &s), "found")
	testing.expect_value(t, s.size, u32(size_of(plugin.Spell)))
	testing.expect_value(t, s.info.cost, 40)
	testing.expect(t, s.scroll, "scroll")
	e := plugin.items(s.effects)
	testing.expect_value(t, len(e), 1)
	testing.expect_value(t, e[0].magnitude, 25)
	testing.expect_value(t, string(plugin.items(plugin.items(e[0].conditions)[0].text)), "hi")
	testing.expect(t, !plugin.record(&w, 0x5B, .Spell, &s), "no such spell")
}

// A plugin built against a shorter view gets the fields it knows and nothing past them.
@(test)
test_record_older_view :: proc(t: ^testing.T) {
	db: gamedb.DB
	defer delete(db.spells)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db.spells[0x5A] = {info = {cost = 40}, scroll = true}

	Old_Spell :: struct {
		using header: plugin.Header,
		info:         [size_of(plugin.Spell{}.info)]u8,
	}
	buf: struct {
		old:  Old_Spell,
		rest: [64]u8, // past the old view: must stay untouched
	}
	buf.rest = 0xAB
	d: worldhost.Data
	w := record_world(&d, &ws, &db)
	testing.expect(t, plugin.record(&w, 0x5A, .Spell, &buf.old), "found")
	testing.expect_value(t, buf.old.size, u32(size_of(Old_Spell)))
	for b in buf.rest {testing.expect_value(t, b, 0xAB)}
}
