package unit_tests

// CTDA tests: the decode, the parameter remap, and the evaluator. Hermetic and synthetic — a
// hand-built plugin plus a worldstate overlay, no game files.
//
// The layout and the function identities were validated against the retail Skyrim.esm with
// `esmdump --ctda`. The records that name their own answer: Arcane Blacksmith gates on actor value
// index 10 (Smithing) >= 60, and Bladesman rank 1 on index 6 (One-Handed) >= 30 plus the Armsman
// perk — the exact vanilla requirements. See docs/conditions.md.

import "core:testing"
import "../../src/conditions"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/worldstate"
import "../../src/formid"

// Plugin-building helpers. File-private per test file, matching the convention already in
// esm_test.odin and bsa_test.odin (which likewise carry their own put_u32).
@(private = "file")
put_u32 :: proc(b: []u8, off: int, v: u32) {
	b[off] = u8(v);b[off + 1] = u8(v >> 8);b[off + 2] = u8(v >> 16);b[off + 3] = u8(v >> 24)
}

@(private = "file")
put_f32 :: proc(b: []u8, off: int, v: f32) {
	put_u32(b, off, transmute(u32)v)
}

@(private = "file")
field :: proc(b: ^[dynamic]u8, type: string, data: []u8) {
	append(b, type[0], type[1], type[2], type[3])
	append(b, u8(len(data)), u8(len(data) >> 8))
	append(b, ..data)
}

@(private = "file")
record :: proc(b: ^[dynamic]u8, type: string, flags, formid: u32, data: []u8) {
	append(b, type[0], type[1], type[2], type[3])
	sz: [4]u8;put_u32(sz[:], 0, u32(len(data)));append(b, ..sz[:])
	fl: [4]u8;put_u32(fl[:], 0, flags);append(b, ..fl[:])
	fi: [4]u8;put_u32(fi[:], 0, formid);append(b, ..fi[:])
	append(b, 0, 0, 0, 0, 0, 0, 0, 0) // version control + form version + unknown
	append(b, ..data)
}

@(private = "file")
group :: proc(b: ^[dynamic]u8, label: []u8, gtype: u32, content: []u8) {
	append(b, 'G', 'R', 'U', 'P')
	sz: [4]u8;put_u32(sz[:], 0, u32(len(content) + 24));append(b, ..sz[:])
	append(b, ..label)
	gt: [4]u8;put_u32(gt[:], 0, gtype);append(b, ..gt[:])
	append(b, 0, 0, 0, 0, 0, 0, 0, 0) // stamp + version + unknown
	append(b, ..content)
}

// ctda builds one 32-byte condition block. `flags` is the low 5 bits of byte 0; with 0x04 (use
// global) pass the GLOB as `global`, which takes the comparison's place.
@(private = "file")
ctda :: proc(b: ^[dynamic]u8, function: u16, op: u8, flags: u8, value: f32, param1: u32, run_on: u32, reference: u32 = 0, param2: u32 = 0, param3: i32 = -1, global: u32 = 0) {
	d: [32]u8
	d[0] = (op << 5) | flags
	put_f32(d[:], 4, value)
	if global != 0 {put_u32(d[:], 4, global)}
	d[8] = u8(function)
	d[9] = u8(function >> 8)
	put_u32(d[:], 12, param1)
	put_u32(d[:], 16, param2)
	put_u32(d[:], 20, run_on)
	put_u32(d[:], 24, reference)
	put_u32(d[:], 28, u32(param3))
	field(b, "CTDA", d[:])
}

// A perk gated the way Bladesman is: needs a prerequisite perk AND One-Handed at 30.
@(private = "file")
build_perk_plugin :: proc(out: ^[dynamic]u8) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	// AVIF for One-Handed, so the index -> name bridge resolves. Its formID must sit in the
	// engine's actor-value block for index 6.
	avif := make([dynamic]u8, 0, 64);defer delete(avif)
	field(&avif, "EDID", transmute([]u8)string("AVOneHanded\x00"))
	field(&avif, "DESC", transmute([]u8)string("Swords.\x00"))
	avif_grp := make([dynamic]u8, 0, 128);defer delete(avif_grp)
	av_form, _ := esm.actor_value_form(6)
	record(&avif_grp, "AVIF", 0, av_form, avif[:])

	perk_grp := make([dynamic]u8, 0, 256);defer delete(perk_grp)
	// 0x0A01 Armsman: no take-conditions.
	arms := make([dynamic]u8, 0, 96);defer delete(arms)
	field(&arms, "EDID", transmute([]u8)string("TestArmsman\x00"))
	field(&arms, "FULL", transmute([]u8)string("Armsman\x00"))
	field(&arms, "DESC", transmute([]u8)string("Hit harder.\x00"))
	field(&arms, "DATA", []u8{0, 0, 1, 1, 0})
	record(&perk_grp, "PERK", 0, 0x0000_0A01, arms[:])

	// 0x0A02 Bladesman: has-perk(Armsman) AND actor-value-6 >= 30. One entry after, whose OWN
	// condition must NOT be picked up as a take-gate.
	blade := make([dynamic]u8, 0, 160);defer delete(blade)
	field(&blade, "EDID", transmute([]u8)string("TestBladesman\x00"))
	field(&blade, "FULL", transmute([]u8)string("Bladesman\x00"))
	field(&blade, "DESC", transmute([]u8)string("Crit more.\x00"))
	ctda(&blade, 448, 0, 0, 1, 0x0000_0A01, 0) // has-perk Armsman == 1
	ctda(&blade, 277, 3, 0, 30, 6, 0)              // actor value index 6 >= 30
	field(&blade, "DATA", []u8{0, 0, 1, 1, 0})
	field(&blade, "PRKE", []u8{0, 1, 0})
	field(&blade, "DATA", []u8{0, 0, 0})
	ctda(&blade, 560, 0, 0, 1, 0x0000_0B01, 0) // an ENTRY gate — must be excluded
	field(&blade, "PRKF", {})
	record(&perk_grp, "PERK", 0, 0x0000_0A02, blade[:])

	record(out, "TES4", 0, 0, tes4[:])
	group(out, transmute([]u8)string("AVIF"), 0, avif_grp[:])
	group(out, transmute([]u8)string("PERK"), 0, perk_grp[:])
}

// The decoder reads the layout, and index_perk takes ONLY the conditions before the first PRKE.
@(test)
test_ctda_decode_and_take_gate :: proc(t: ^testing.T) {
	out := make([dynamic]u8, 0, 1024);defer delete(out)
	build_perk_plugin(&out)
	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	p, ok := gamedb.perk_of(&db, 0x0000_0A02)
	testing.expect(t, ok, "perk decoded")
	// Two take-conditions; the entry's condition stayed out.
	testing.expect_value(t, len(p.take_conditions), 2)

	c0 := p.take_conditions[0]
	testing.expect_value(t, c0.function, u16(448))
	testing.expect_value(t, c0.op, esm.Condition_Op.Equal)
	testing.expect_value(t, c0.value, f32(1))
	testing.expect_value(t, c0.flags, esm.Condition_Flags{})
	testing.expect_value(t, c0.run_on, esm.Condition_Run_On.Subject)
	// 448's param1 IS a form, so it was remapped.
	testing.expect_value(t, gamedb.condition_param1_form(c0), gamedb.Form_ID(0x0000_0A01))

	c1 := p.take_conditions[1]
	testing.expect_value(t, c1.function, u16(277))
	testing.expect_value(t, c1.op, esm.Condition_Op.GreaterOrEqual)
	testing.expect_value(t, c1.value, f32(30))
	// 277's param1 is an actor value INDEX, so it must NOT have been remapped.
	testing.expect_value(t, c1.param1, u64(6))

	// A perk with no conditions gets no slice.
	a, aok := gamedb.perk_of(&db, 0x0000_0A01)
	testing.expect(t, aok, "armsman decoded")
	testing.expect_value(t, len(a.take_conditions), 0)
}

// The evaluator: a real gate passes only once both halves are satisfied.
@(test)
test_conditions_evaluate :: proc(t: ^testing.T) {
	out := make([dynamic]u8, 0, 1024);defer delete(out)
	build_perk_plugin(&out)
	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	ctx := conditions.Context{db = &db, ws = &ws, subject = formid.PLAYER}
	p, _ := gamedb.perk_of(&db, 0x0000_0A02)

	// Nothing taken, no skill: both halves fail.
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "gate closed at the start")

	// The prerequisite perk alone is not enough.
	worldstate.perk_add(&ws, formid.PLAYER, 0x0000_0A01)
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "skill still too low")

	// Skill just under the bar still fails — the operator is >=, not >. 277 reads the base, so a
	// fortify does not open it.
	ONE_HANDED :: "OneHanded"
	worldstate.av_set_base(&ws, formid.PLAYER, ONE_HANDED, 29)
	worldstate.av_mod(&ws, formid.PLAYER, ONE_HANDED, 5)
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "29 is below 30")

	worldstate.av_set_base(&ws, formid.PLAYER, ONE_HANDED, 30)
	testing.expect(t, conditions.all(&ctx, p.take_conditions), "gate opens at exactly 30")

	// Losing the prerequisite closes it again.
	worldstate.perk_remove(&ws, formid.PLAYER, 0x0000_0A01)
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "gate closed without the prerequisite")
}

// An empty list passes, an unknown function passes, and OR runs group correctly.
@(test)
test_conditions_and_or_grouping :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ctx := conditions.Context{db = &db, ws = &ws, subject = formid.PLAYER}

	testing.expect(t, conditions.all(&ctx, {}), "an empty list passes")

	// An unimplemented function must not hide content.
	unknown := []gamedb.Condition{{function = 9999, op = .Equal, value = 1}}
	testing.expect(t, conditions.all(&ctx, unknown), "an unknown function evaluates true")

	// has-perk on two perks, neither held.
	A :: gamedb.Form_ID(0xA1)
	B :: gamedb.Form_ID(0xB1)
	has :: proc(p: gamedb.Form_ID, or_next: bool) -> gamedb.Condition {
		return gamedb.Condition{function = 448, op = .Equal, value = 1, param1 = u64(p), flags = {.Or} if or_next else {}}
	}

	// AND: both required.
	and_list := []gamedb.Condition{has(A, false), has(B, false)}
	testing.expect(t, !conditions.all(&ctx, and_list), "AND fails with neither")
	worldstate.perk_add(&ws, formid.PLAYER, A)
	testing.expect(t, !conditions.all(&ctx, and_list), "AND fails with only one")
	worldstate.perk_add(&ws, formid.PLAYER, B)
	testing.expect(t, conditions.all(&ctx, and_list), "AND passes with both")

	// OR: the first condition carries the flag, joining it to the second. Either suffices.
	worldstate.perk_remove(&ws, formid.PLAYER, A)
	worldstate.perk_remove(&ws, formid.PLAYER, B)
	or_list := []gamedb.Condition{has(A, true), has(B, false)}
	testing.expect(t, !conditions.all(&ctx, or_list), "OR fails with neither")
	worldstate.perk_add(&ws, formid.PLAYER, A)
	testing.expect(t, conditions.all(&ctx, or_list), "OR passes on the first alone")
	worldstate.perk_remove(&ws, formid.PLAYER, A)
	worldstate.perk_add(&ws, formid.PLAYER, B)
	testing.expect(t, conditions.all(&ctx, or_list), "OR passes on the second alone")

	// A group followed by a required AND term: (A OR B) AND C.
	C :: gamedb.Form_ID(0xC1)
	mixed := []gamedb.Condition{has(A, true), has(B, false), has(C, false)}
	testing.expect(t, !conditions.all(&ctx, mixed), "the trailing AND term still gates")
	worldstate.perk_add(&ws, formid.PLAYER, C)
	testing.expect(t, conditions.all(&ctx, mixed), "(A OR B) AND C passes")
}

// A perk whose take-gate carries the fields quest and dialogue conditions use: a global comparison,
// a string parameter, an alias parameter, and a quest alias run-on.
@(private = "file")
build_quest_style_plugin :: proc(out: ^[dynamic]u8) {
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0800)
	field(&tes4, "HEDR", hedr[:])

	perk_grp := make([dynamic]u8, 0, 256);defer delete(perk_grp)
	p := make([dynamic]u8, 0, 256);defer delete(p)
	field(&p, "EDID", transmute([]u8)string("TestQuestStyle\x00"))
	ctda(&p, 448, 0, 0x04, 0, 0x0000_0A01, 0, global = 0x0000_0E01)  // HasPerk == global
	ctda(&p, 629, 0, 0, 1, 0x0000_0C01, 0)                           // GetVMQuestVariable
	field(&p, "CIS2", transmute([]u8)string("::done_var\x00"))
	ctda(&p, 650, 0, 0x02, 1, 3, 0, param2 = 0x0000_0D01)            // IsLinkedTo(alias 3, keyword)
	ctda(&p, 72, 0, 0, 1, 0x0000_0F01, 5, param3 = 2)                // GetIsID, run on alias 2
	field(&p, "DATA", []u8{0, 0, 1, 1, 0})
	record(&perk_grp, "PERK", 0, 0x0000_0A02, p[:])

	record(out, "TES4", 0, 0, tes4[:])
	group(out, transmute([]u8)string("PERK"), 0, perk_grp[:])
}

@(test)
test_ctda_decode_quest_fields :: proc(t: ^testing.T) {
	out := make([dynamic]u8, 0, 1024);defer delete(out)
	build_quest_style_plugin(&out)
	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	p, ok := gamedb.perk_of(&db, 0x0000_0A02)
	testing.expect(t, ok, "perk decoded")
	if !testing.expect_value(t, len(p.take_conditions), 4) {return}
	cs := p.take_conditions

	testing.expect_value(t, cs[0].flags, esm.Condition_Flags{.Use_Global})
	testing.expect_value(t, cs[0].global, gamedb.Form_ID(0x0000_0E01))
	testing.expect_value(t, cs[0].value, f32(0))

	testing.expect_value(t, gamedb.condition_param1_form(cs[1]), gamedb.Form_ID(0x0000_0C01))
	testing.expect_value(t, cs[1].text, "::done_var")
	testing.expect_value(t, cs[1].param3, i32(-1))

	testing.expect_value(t, cs[2].flags, esm.Condition_Flags{.Use_Aliases})
	testing.expect_value(t, cs[2].param1, u64(3))
	testing.expect_value(t, gamedb.condition_param2_form(cs[2]), gamedb.Form_ID(0x0000_0D01))
	testing.expect_value(t, cs[2].text, "")

	testing.expect_value(t, cs[3].run_on, esm.Condition_Run_On.QuestAlias)
	testing.expect_value(t, cs[3].param3, i32(2))
}

// Which parameters are forms: the table's kind, and a Ref only without the alias or packdata flag.
@(test)
test_ctda_param_kinds :: proc(t: ^testing.T) {
	testing.expect_value(t, esm.condition_function(72).name, "GetIsID")
	testing.expect_value(t, esm.condition_function(9999).name, "")
	testing.expect(t, esm.condition_param_is_form({function = 448}, 0), "HasPerk takes a perk")
	testing.expect(t, !esm.condition_param_is_form({function = 277}, 0), "GetBaseActorValue takes an index")
	testing.expect(t, esm.condition_param_is_form({function = 650}, 0), "IsLinkedTo takes a ref")
	testing.expect(t, !esm.condition_param_is_form({function = 650, flags = {.Use_Aliases}}, 0), "or an alias")
	testing.expect(t, !esm.condition_param_is_form({function = 650, flags = {.Use_Pack_Data}}, 0), "or package data")
	testing.expect(t, esm.condition_param_is_form({function = 650}, 1), "and a keyword")
	testing.expect(t, !esm.condition_param_is_form({function = 629}, 1), "a string is not a form")
}

// A global comparison reads the global's live value; Swap asks the target instead of the subject.
@(test)
test_conditions_global_and_swap :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	OTHER :: gamedb.Form_ID(0x0000_0B0B)
	PERK :: gamedb.Form_ID(0xA1)
	GLOB :: gamedb.Form_ID(0xE1)
	ctx := conditions.Context{db = &db, ws = &ws, subject = formid.PLAYER, target = OTHER}
	worldstate.perk_add(&ws, formid.PLAYER, PERK)

	global := []gamedb.Condition{{function = 448, op = .Equal, flags = {.Use_Global}, global = GLOB, param1 = u64(PERK)}}
	worldstate.set_global(&ws, GLOB, 1)
	testing.expect(t, conditions.all(&ctx, global), "has the perk == global 1")
	worldstate.set_global(&ws, GLOB, 0)
	testing.expect(t, !conditions.all(&ctx, global), "has the perk != global 0")

	swapped := []gamedb.Condition{{function = 448, op = .Equal, value = 1, flags = {.Swap}, param1 = u64(PERK)}}
	testing.expect(t, !conditions.all(&ctx, swapped), "swap asks the target, which lacks the perk")
	worldstate.perk_add(&ws, OTHER, PERK)
	testing.expect(t, conditions.all(&ctx, swapped), "the target has it now")
}

// Run-on Quest Alias and alias parameters read the owning quest's aliases; with no quest in the
// context they cannot answer, so they pass. Run-on Event Data reads the story event.
@(test)
test_conditions_aliases_and_events :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	QUEST :: gamedb.Form_ID(0x0000_0C01)
	BASE :: gamedb.Form_ID(0x0000_0D01)
	ref := worldstate.create_ref(&ws, BASE, 0, {}, {}, 1)
	h, _ := formid.alias_handle(QUEST, 2)
	worldstate.fill_alias(&ws, h, ref)

	is_base := []gamedb.Condition{{function = 72, op = .Equal, value = 1, param1 = u64(BASE), run_on = .QuestAlias, param3 = 2}}
	none := conditions.Context{db = &db, ws = &ws, subject = formid.PLAYER}
	testing.expect(t, conditions.all(&none, is_base), "no owning quest: passes")
	ctx := conditions.Context{db = &db, ws = &ws, subject = formid.PLAYER, quest = QUEST}
	testing.expect(t, conditions.all(&ctx, is_base), "the alias holds a ref of that base")
	empty := []gamedb.Condition{{function = 72, op = .Equal, value = 1, param1 = u64(BASE), run_on = .QuestAlias, param3 = 3}}
	testing.expect(t, !conditions.all(&ctx, empty), "an empty alias is a real answer")

	alias_ref := []gamedb.Condition{{function = 566, op = .Equal, value = 1, param1 = 2}}
	testing.expect(t, !conditions.all(&ctx, alias_ref), "the player is not in alias 2")
	ctx.subject = ref
	testing.expect(t, conditions.all(&ctx, alias_ref), "the ref is")

	e := worldstate.Story_Event{type = "KILL", ref1 = ref}
	on_event := []gamedb.Condition{{function = 72, op = .Equal, value = 1, param1 = u64(BASE), run_on = .EventData, param3 = conditions.EVENT_ACTOR_1}}
	testing.expect(t, conditions.all(&ctx, on_event), "no event: passes")
	ctx.event = &e
	e.ref1 = formid.PLAYER
	testing.expect(t, !conditions.all(&ctx, on_event), "actor 1 is the player")
	e.ref1 = ref
	testing.expect(t, conditions.all(&ctx, on_event), "actor 1 is the ref")
}

// A few bodies over the stores: quest stages, globals, factions.
@(test)
test_conditions_quest_and_faction_reads :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ctx := conditions.Context{db = &db, ws = &ws, subject = formid.PLAYER}
	QUEST :: gamedb.Form_ID(0x0000_0C01)
	FACTION :: gamedb.Form_ID(0x0000_0F01)
	GLOB :: gamedb.Form_ID(0x0000_0E01)

	stage := []gamedb.Condition{{function = 58, op = .GreaterOrEqual, value = 20, param1 = u64(QUEST)}}
	done := []gamedb.Condition{{function = 59, op = .Equal, value = 1, param1 = u64(QUEST), param2 = 10}}
	testing.expect(t, !conditions.all(&ctx, stage) && !conditions.all(&ctx, done), "an untouched quest")
	worldstate.quest_set_stage(&ws, QUEST, 10)
	worldstate.quest_set_stage(&ws, QUEST, 20)
	testing.expect(t, conditions.all(&ctx, stage) && conditions.all(&ctx, done), "stage 20, 10 done")

	glob := []gamedb.Condition{{function = 74, op = .Equal, value = 3, param1 = u64(GLOB)}}
	worldstate.set_global(&ws, GLOB, 3)
	testing.expect(t, conditions.all(&ctx, glob), "GetGlobalValue")

	member := []gamedb.Condition{{function = 71, op = .Equal, value = 1, param1 = u64(FACTION)}}
	rank := []gamedb.Condition{{function = 73, op = .Equal, value = -1, param1 = u64(FACTION)}}
	testing.expect(t, !conditions.all(&ctx, member) && conditions.all(&ctx, rank), "not in the faction")
	worldstate.faction_set_rank(&ws, formid.PLAYER, FACTION, -1)
	testing.expect(t, !conditions.all(&ctx, member) && conditions.all(&ctx, rank), "rank -1 is not a member")
	worldstate.faction_set_rank(&ws, formid.PLAYER, FACTION, 0)
	testing.expect(t, conditions.all(&ctx, member), "rank 0 is")
}
