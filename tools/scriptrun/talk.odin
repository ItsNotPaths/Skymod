package main

import "core:fmt"
import "core:strings"
import "core:time"
import "../../src/conditions"
import "../../src/dialogue"
import "../../src/formats/esm"
import "../../src/formid"
import "../../src/script"
import "../../src/gamedb"
import slua "../../src/script/lua"
import "../../src/worldstate"

// talk opens a conversation with the first placed actor named `name`, as the player would: its
// greeting, then its topic list, each with the time it took.
talk :: proc(vm: ^slua.VM, db: ^gamedb.DB, name: string) {
	speaker: gamedb.Form_ID
	find: for _, cell in db.actor_refs {
		for r in cell {
			if strings.equal_fold(worldstate.display_name(vm.ctx.ws, db, r.form_id), name) {
				speaker = r.form_id
				break find
			}
		}
	}
	if speaker == 0 {
		fmt.printfln("== talk %s: no placed actor has that name", name)
		return
	}
	c := vm.ctx
	c.ws.talking = speaker
	defer c.ws.talking = 0
	start := time.now()
	greet, ok := dialogue.greeting(&c, speaker)
	took := time.since(start)
	fmt.printfln("== talk %s [0x%08X]: greeting in %v", name, u32(speaker), took)
	if !ok {
		fmt.println("  (in an Exclusive branch with nothing to say)")
		return
	}
	if greet.info != 0 {
		fmt.printfln("  greeting info 0x%08X, branch 0x%08X", u32(greet.info), u32(greet.blocking))
		why(&c, speaker, greet.info)
		for r in dialogue.responses(db, greet.info) {fmt.printfln("  > %s", r.text)}
	}
	start = time.now()
	topics := dialogue.topics(&c, speaker)
	took = time.since(start)
	fmt.printfln("  topics (%d, in %v):", len(topics), took)
	for ch, i in topics {
		fmt.printfln("  - %s  [topic 0x%08X info 0x%08X]", ch.prompt, u32(ch.topic), u32(ch.info))
		if i < 2 {why(&c, speaker, ch.info)}
	}
}

// why prints each condition of an info and its quest's dialogue conditions with what it answered.
why :: proc(c: ^script.Call, speaker, info: gamedb.Form_ID) {
	i := c.db.infos[info]
	quest := c.db.topics[i.topic].quest
	qb, _ := gamedb.quest_baseline_of(c.db, quest)
	ctx := script.condition_context(c, speaker, formid.PLAYER, quest)
	for list, k in ([2][]gamedb.Condition{qb.dialogue_conditions, i.conditions}) {
		for cond in list {
			name := esm.CONDITION_FUNCTIONS[cond.function].name if int(cond.function) < len(esm.CONDITION_FUNCTIONS) else "?"
			fmt.printfln("      %s %s(%v) run_on %v %v %v -> %v", "quest" if k == 0 else "info", name, cond.param1, cond.run_on, cond.op, cond.value, conditions.test(&ctx, cond))
		}
	}
}
