package script_lua

// Fragments: the compiler-generated functions a record calls on its own fragment script. A quest
// stage's run when the stage is set (CK Quest Stages Tab: each stage item whose conditions pass); a
// topic info's when its line begins and ends (CK Topic Info Fragments); a scene's in scenes.odin.

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
	for item, i in st.items {
		ctx := script.condition_context(&vm.ctx, formid.PLAYER, 0, quest)
		if conditions.all(&ctx, item.conditions) {record_fragment(vm, quest, stage, u16(i))}
	}
}

// tick_info_fragments runs the topic info fragments dialogue asked for since the last tick, with
// the speaker as akSpeakerRef.
tick_info_fragments :: proc(vm: ^VM) {
	ws := vm.ctx.ws
	runs := slice.clone(ws.info_runs[:], context.temp_allocator)
	clear(&ws.info_runs)
	for r in runs {record_fragment(vm, r.info, 1 if r.end else 0, 0, r.speaker)}
}

// record_fragment runs the fragment of `form` at (index, item), if it has one. A form whose scripts
// are not attached yet (an info, a scene) gets them first.
record_fragment :: proc(vm: ^VM, form: script.Form_ID, index, item: u16, args: ..script.Form_ID) {
	file, frags := gamedb.form_fragments(vm.ctx.db, form)
	for fr in frags {
		if fr.index != index || fr.item != item {continue}
		attach_known(vm, form, gamedb.form_scripts(vm.ctx.db, form))
		run_fragment(vm, form, file, fr.function, ..args)
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
		log.errorf("lua: rt.fragment %s.%s: %s", file, fn, to_string(L, -1))
	}
}
