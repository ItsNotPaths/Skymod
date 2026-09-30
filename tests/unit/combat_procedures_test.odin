package unit_tests

import "core:testing"
import "../../src/ai"
import "../../src/conditions"
import "../../src/gamedb"
import "../../src/worldstate"

// UseMagic casts its spell at its target, again after its cooldown, as many times as it says;
// UseWeapon closes on its target with a melee weapon (fists here) and swings once in reach.
@(test)
test_combat_procedures :: proc(t: ^testing.T) {
	ACTOR, TARGET, SPELL, MAGIC, MELEE :: gamedb.Form_ID(0xA1), gamedb.Form_ID(0xB1), gamedb.Form_ID(0xC1), gamedb.Form_ID(0xD1), gamedb.Form_ID(0xD2)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	db.ref_by_id[TARGET] = {form_id = TARGET, pos = {1000, 0, 0}}
	target := gamedb.Package_Target{kind = .SpecificRef, form = TARGET}
	db.packages = make(map[gamedb.Form_ID]gamedb.Package, context.temp_allocator)
	db.packages[MAGIC] = {
		tree   = {{procedure = "UseMagic", inputs = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9}}},
		inputs = {{index = 1, kind = .TargetSelector, value = gamedb.Package_Target{kind = .ObjectID, form = SPELL}}, {index = 2, kind = .SingleRef, value = target}, {index = 9, kind = .Int, value = i32(2)}},
	}
	db.packages[MELEE] = {tree = {{procedure = "UseWeapon", inputs = {0, 1, 2}}}, inputs = {{index = 2, kind = .SingleRef, value = target}}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	w: ai.World
	agent := ai.Agent{pack = MAGIC}
	append(&agent.nodes, ai.Node_State{})
	defer delete(agent.nodes)
	c := ai.Proc_Context{cond = conditions.Context{ws = &ws, db = &db, subject = ACTOR}, agent = &agent, w = &w, dt = 1}

	testing.expect_value(t, ai.proc_use_magic(&c), ai.Status.Running)
	testing.expect_value(t, ws.ai.casts[0], worldstate.Cast_Order{ACTOR, SPELL, TARGET})
	for _ in 0 ..< 3 {ai.proc_use_magic(&c)} // the cooldown passes
	testing.expect_value(t, len(ws.ai.casts), 2)

	agent.pack, agent.nodes[0] = MELEE, {}
	testing.expect_value(t, ai.proc_use_weapon(&c), ai.Status.Running)
	testing.expect(t, agent.mover.goal.active && len(ws.swings) == 0, "it closes first")
	c.feet = {950, 0, 0}
	testing.expect_value(t, ai.proc_use_weapon(&c), ai.Status.Done) // one barrage by default
	testing.expect_value(t, len(ws.swings), 1)
}
