package script_lua

// Console quest verbs: sqs and sqo read the quest store; the verbs that move a quest are Lua in
// QUEST_VERBS, over the Quest natives, so they run what a script's call runs.

import "core:c"
import "core:fmt"
import "core:slice"
import lua "../../../vendor/lua"
import script ".."
import "../../gamedb"
import "../../worldstate"

@(private)
QUEST_VERBS :: `
local function quest(q)
  if not q then error("no such quest", 0) end
  return q
end
cmd.def("setstage", function(q, n) print(quest(q):SetCurrentStageID(n)) end, "setstage <quest> <stage>")
cmd.def("getstage", function(q) print(quest(q):GetCurrentStageID()) end, "getstage <quest>")
cmd.def("startquest", function(q) print(quest(q):Start()) end, "startquest <quest>")
cmd.def("stopquest", function(q) quest(q):Stop() end, "stopquest <quest>")
cmd.def("completequest", function(q) quest(q):CompleteQuest() end, "completequest <quest>")
cmd.def("resetquest", function(q) quest(q):Reset() end, "resetquest <quest>")
cmd.def("movetoqt", function(q)
  local r = __quest_target(quest(q))
  if r then player:MoveTo(r) else print("no target") end
end, "movetoqt <quest> — move to the target of its first shown objective")
cmd.def("kill", function(r) (r or sel):Kill() end, "kill [actor] (default: selection)")
`

repl_register_quest_verbs :: proc(repl: ^Repl) -> bool {
	lua.pushlightuserdata(repl.vm.L, &repl.vm)
	lua.pushcclosure(repl.vm.L, quest_target, 1)
	lua.setglobal(repl.vm.L, "__quest_target")
	if !do_string(&repl.vm, QUEST_VERBS) {return false}
	repl_register_cmd(repl, "sqs", "sqs <quest> — its stages: done marks, the current one, log text", repl_sqs, &repl.vm)
	repl_register_cmd(repl, "sqo", "sqo — the objectives shown now, per running quest", repl_sqo, &repl.vm)
	return true
}

@(private = "file")
repl_sqs :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context
	ws, db := vm.ctx.ws, vm.ctx.db
	quest, _ := ref_form(L, 1)
	qb, ok := db.quest_baseline[quest]
	if !ok {
		console_print(L, "not a quest")
		return 0
	}
	running := "running" if worldstate.quest_running(ws, db, quest) else "stopped"
	console_print(L, fmt.tprintf("%s: %s, stage %d", ref_label(vm, quest), running, worldstate.quest_stage(ws, quest)))
	stages := make([dynamic]u16, context.temp_allocator)
	for stage in qb.stages {append(&stages, stage)}
	slice.sort(stages[:])
	for stage in stages {
		done := "x" if worldstate.quest_is_stage_done(ws, quest, stage) else " "
		console_print(L, fmt.tprintf("  [%s] %4d  %s", done, stage, qb.stage_log[stage]))
	}
	return 0
}

@(private = "file")
repl_sqo :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context
	ws, db := vm.ctx.ws, vm.ctx.db
	quests := make([dynamic]gamedb.Form_ID, context.temp_allocator)
	for quest in ws.quests {append(&quests, quest)}
	slice.sort(quests[:])
	for quest in quests {
		objs := shown_objectives(ws, quest)
		if len(objs) == 0 || !worldstate.quest_running(ws, db, quest) {continue}
		console_print(L, fmt.tprintf("%s 0x%08X", ref_label(vm, quest), u64(quest)))
		for obj in objs {console_print(L, fmt.tprintf("  %4d  %s", obj, db.quest_baseline[quest].objective_text[obj]))}
	}
	return 0
}

// quest_target(quest) is the first target of the quest's lowest objective that is shown and not
// done, or None.
@(private = "file")
quest_target :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context
	quest, _ := ref_form(L, 1)
	cc := vm.ctx
	for obj in shown_objectives(vm.ctx.ws, quest) {
		if targets := script.objective_targets(&cc, quest, obj); len(targets) > 0 {
			push_ref(L, targets[0])
			return 1
		}
	}
	push_none(L)
	return 1
}

// shown_objectives are a quest's objectives that are displayed and neither completed nor failed,
// lowest first.
@(private = "file")
shown_objectives :: proc(ws: ^worldstate.World_State, quest: gamedb.Form_ID) -> []u16 {
	objs := make([dynamic]u16, context.temp_allocator)
	q, ok := worldstate.quest_get(ws, quest)
	if !ok {return nil}
	for obj, st in q.objectives {
		if st & {.Completed, .Failed} == {} && .Displayed in st {append(&objs, obj)}
	}
	slice.sort(objs[:])
	return objs[:]
}

// console_print prints one line through the console's print.
console_print :: proc(L: ^lua.State, line: string) {
	lua.getglobal(L, "print")
	lua.pushstring(L, tcstr("%s", line))
	lua.pcall(L, 1, 0, 0)
}
