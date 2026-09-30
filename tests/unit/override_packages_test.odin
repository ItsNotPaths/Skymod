package unit_tests

import "core:testing"
import "../../src/ai"
import "../../src/conditions"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"

// In a fight an actor runs only its combat list, inherited through its AI packages template;
// watching one it tries its spectator list first. A HoldPosition in a fight keeps the chase in its place.
@(test)
test_override_packages :: proc(t: ^testing.T) {
	ACTOR, BASE, TEMPLATE, OWN, HOLD, WATCH, COMBAT_LIST, WATCH_LIST, FOE :: gamedb.Form_ID(0xA1), gamedb.Form_ID(0xA2), gamedb.Form_ID(0xA3), gamedb.Form_ID(0xB1), gamedb.Form_ID(0xB2), gamedb.Form_ID(0xB3), gamedb.Form_ID(0xC1), gamedb.Form_ID(0xC2), gamedb.Form_ID(0xD1)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref, context.temp_allocator)
	db.ref_by_id[ACTOR] = {form_id = ACTOR, base = BASE, cell_form_id = 0xE1}
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[BASE] = {packages = {OWN}, template = TEMPLATE, template_flags = esm.ACBS_TEMPLATE_AI_PACKAGES}
	db.actors[TEMPLATE] = {packages = {OWN}, overrides = {combat = COMBAT_LIST, spectator = WATCH_LIST}}
	db.form_lists = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.form_lists[COMBAT_LIST] = {HOLD}
	db.form_lists[WATCH_LIST] = {WATCH}
	any_time := gamedb.Package_Schedule{day_of_week = -1, hour = -1}
	place := gamedb.Package_Input{index = 0, kind = .Location, value = gamedb.Package_Location{kind = .NearPackageStart, radius = 100}}
	db.packages = make(map[gamedb.Form_ID]gamedb.Package, context.temp_allocator)
	db.packages[OWN] = {schedule = any_time, tree = {{procedure = "Wait"}}}
	db.packages[HOLD] = {schedule = any_time, tree = {{procedure = "HoldPosition", inputs = {0}}}, inputs = {place}}
	db.packages[WATCH] = {schedule = any_time, tree = {{procedure = "Wait"}}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	w: ai.World
	defer delete(w.agents)

	w.agents[ACTOR] = {}
	pack, _ := ai.select_package(&w, &ws, &db, ACTOR)
	testing.expect_value(t, pack, OWN)
	w.agents[ACTOR] = {spectating = 1}
	pack, _ = ai.select_package(&w, &ws, &db, ACTOR)
	testing.expect_value(t, pack, WATCH)
	w.agents[ACTOR] = {combat = {state = .Combat, target = FOE}}
	pack, _ = ai.select_package(&w, &ws, &db, ACTOR)
	testing.expect_value(t, pack, HOLD)

	agent := ai.Agent{pack = HOLD, combat = {state = .Combat, target = FOE}}
	append(&agent.nodes, ai.Node_State{})
	defer delete(agent.nodes)
	agent.mover.goal = {active = true, point = {1000, 0, 0}, radius = 141}
	c := ai.Proc_Context{cond = conditions.Context{ws = &ws, db = &db, subject = ACTOR}, agent = &agent, w = &w, dt = 1}
	testing.expect_value(t, ai.proc_hold_position(&c), ai.Status.Running)
	testing.expect_value(t, agent.mover.goal.point, [3]f32{100, 0, 0}) // the edge of its place, round where it began
}
