package script_lua

// Fragments: the compiler-generated functions a record calls on its own fragment script. A quest
// stage's run when the stage is set (CK Quest Stages Tab: each stage item whose conditions pass); a
// topic info's when its line begins and ends (CK Topic Info Fragments).

import "core:log"
import "core:slice"
import "core:strings"
import lua "../../../vendor/lua"
import script ".."
import "../../conditions"
import "../../formid"
import "../../gamedb"

// run_quest_steps runs the stages and stops natives queued, oldest first. A fragment that sets a
// stage runs that stage's fragments inside its own SetStage (a nested sync_refs), as Papyrus waits.
run_quest_steps :: proc(vm: ^VM) {
	ws := vm.ctx.ws
	for len(ws.quest_steps) > 0 {
		step := ws.quest_steps[0]
		ordered_remove(&ws.quest_steps, 0)
		if step.stop {
			script.stop_quest(&vm.ctx, step.quest)
		} else {
			run_stage(vm, step.quest, step.stage)
		}
	}
}

// run_stage runs the fragment of each item of a stage whose conditions pass. The conditions ask
// about the player (164 of 185 stage-item conditions run on the subject: GetInCurrentLoc, globals).
@(private = "file")
run_stage :: proc(vm: ^VM, quest: script.Form_ID, stage: u16) {
	st, ok := gamedb.quest_stage(vm.ctx.db, quest, stage)
	if !ok {return}
	file, frags := gamedb.form_fragments(vm.ctx.db, quest)
	for item, i in st.items {
		ctx := script.condition_context(&vm.ctx, formid.PLAYER, 0, quest)
		if !conditions.all(&ctx, item.conditions) {continue}
		for fr in frags {
			if fr.index == stage && int(fr.item) == i {run_fragment(vm, quest, file, fr.function)}
		}
	}
}

// tick_info_fragments runs the topic info fragments dialogue asked for since the last tick, with
// the speaker as akSpeakerRef. An info gets its fragment script the first time one runs.
tick_info_fragments :: proc(vm: ^VM) {
	ws := vm.ctx.ws
	runs := slice.clone(ws.info_runs[:], context.temp_allocator)
	clear(&ws.info_runs)
	for r in runs {
		file, frags := gamedb.form_fragments(vm.ctx.db, r.info)
		slot := u16(1) if r.end else 0
		for fr in frags {
			if fr.index != slot {continue}
			attach_known(vm, r.info, gamedb.form_scripts(vm.ctx.db, r.info))
			run_fragment(vm, r.info, file, fr.function, r.speaker)
		}
	}
}

// run_fragment calls function `fn` of the fragment script `file` on `form`, with ref arguments.
run_fragment :: proc(vm: ^VM, form: script.Form_ID, file, fn: string, args: ..script.Form_ID) {
	L := vm.L
	vm.host_context = context
	top := lua.gettop(L)
	defer lua.settop(L, top)

	if !push_rt_fn(L, "fragment") {return}
	push_ref(L, form)
	lua.pushstring(L, strings.clone_to_cstring(file, context.temp_allocator))
	lua.pushstring(L, strings.clone_to_cstring(fn, context.temp_allocator))
	for a in args {push_ref(L, a)}
	if lua.pcall(L, i32(3 + len(args)), 0, 0) != 0 {
		log.errorf("lua: rt.fragment: %s", to_string(L, -1))
	}
}
