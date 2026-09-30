package unit_tests

import "../../src/plugin"

// fake_world answers every query with nothing: no refs, no values, no factions. A test swaps in
// the procs it needs.
fake_world :: proc(data: rawptr) -> plugin.World {
	return {
		data = data,
		player = 0x14,
		ref = proc "c" (data: rawptr, ref: plugin.Form_ID) -> plugin.Ref {return {}},
		actor_value = proc "c" (data: rawptr, actor: plugin.Form_ID, name: cstring, part: plugin.AV_Part) -> f32 {return 0},
		level = proc "c" (data: rawptr, actor: plugin.Form_ID) -> i32 {return 1},
		faction_rank = proc "c" (data: rawptr, actor, faction: plugin.Form_ID) -> i32 {return -1},
		relation = proc "c" (data: rawptr, a, b: plugin.Form_ID) -> plugin.Relation {return .Neutral},
		hostile = proc "c" (data: rawptr, a, b: plugin.Form_ID) -> bool {return false},
		has_keyword = proc "c" (data: rawptr, form, keyword: plugin.Form_ID) -> bool {return false},
		in_list = proc "c" (data: rawptr, list, form: plugin.Form_ID) -> bool {return false},
		item_count = proc "c" (data: rawptr, container, item: plugin.Form_ID) -> i32 {return 0},
		awareness = proc "c" (data: rawptr, viewer, target: plugin.Form_ID) -> plugin.Awareness {return {}},
		quest_stage = proc "c" (data: rawptr, quest: plugin.Form_ID) -> i32 {return 0},
		quest_running = proc "c" (data: rawptr, quest: plugin.Form_ID) -> bool {return false},
		stage_done = proc "c" (data: rawptr, quest: plugin.Form_ID, stage: i32) -> bool {return false},
		global = proc "c" (data: rawptr, global: plugin.Form_ID) -> f32 {return 0},
		setting = proc "c" (data: rawptr, name: cstring, fallback: f32) -> f32 {return fallback},
		game_hours = proc "c" (data: rawptr) -> f64 {return 0},
		record = proc "c" (data: rawptr, form: plugin.Form_ID, kind: plugin.Record_Kind, out: rawptr) -> bool {return false},
		difficulty = proc "c" (data: rawptr) -> i32 {return 0},
	}
}
