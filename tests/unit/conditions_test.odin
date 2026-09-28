package unit_tests

// CTDA tests: the decode, the parameter remap, and the evaluator. Hermetic and synthetic — a
// hand-built plugin plus a worldstate overlay, no game files.
//
// The layout and the function identities were validated against the retail Skyrim.esm with
// `esmdump --ctda`. The records that name their own answer: Arcane Blacksmith gates on actor value
// index 10 (Smithing) >= 60, and Bladesman rank 1 on index 6 (One-Handed) >= 30 plus the Armsman
// perk — the exact vanilla requirements. See docs/conditions.md.

import "core:testing"
import "../../src/actorstate"
import "../../src/conditions"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"
import "../../src/formid"

// Plugin-building helpers. File-private per test file, matching the convention already in
// esm_test.odin and bsa_test.odin (which likewise carry their own put_u32).
@(private = "file")
put_u32 :: proc(b: []u8, off: int, v: u32) {
	b[off] = u8(v);b[off + 1] = u8(v >> 8);b[off + 2] = u8(v >> 16);b[off + 3] = u8(v >> 24)
}

@(private = "file")
put_u16 :: proc(b: []u8, off: int, v: u16) {
	b[off] = u8(v);b[off + 1] = u8(v >> 8)
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

	ctx := conditions.Context{db = &db, ws = &ws, subject = ws.player}
	p, _ := gamedb.perk_of(&db, 0x0000_0A02)

	// Nothing taken, no skill: both halves fail.
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "gate closed at the start")

	// The prerequisite perk alone is not enough.
	worldstate.perk_add(&ws, ws.player, 0x0000_0A01)
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "skill still too low")

	// Skill just under the bar still fails — the operator is >=, not >. 277 reads the base, so a
	// fortify does not open it.
	ONE_HANDED :: "OneHanded"
	worldstate.av_set_base(&ws, ws.player, ONE_HANDED, 29)
	worldstate.av_mod(&ws, ws.player, ONE_HANDED, 5)
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "29 is below 30")

	worldstate.av_set_base(&ws, ws.player, ONE_HANDED, 30)
	testing.expect(t, conditions.all(&ctx, p.take_conditions), "gate opens at exactly 30")

	// Losing the prerequisite closes it again.
	worldstate.perk_remove(&ws, ws.player, 0x0000_0A01)
	testing.expect(t, !conditions.all(&ctx, p.take_conditions), "gate closed without the prerequisite")
}

// An empty list passes, an unknown function passes, and OR runs group correctly.
@(test)
test_conditions_and_or_grouping :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ctx := conditions.Context{db = &db, ws = &ws, subject = ws.player}

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
	worldstate.perk_add(&ws, ws.player, A)
	testing.expect(t, !conditions.all(&ctx, and_list), "AND fails with only one")
	worldstate.perk_add(&ws, ws.player, B)
	testing.expect(t, conditions.all(&ctx, and_list), "AND passes with both")

	// OR: the first condition carries the flag, joining it to the second. Either suffices.
	worldstate.perk_remove(&ws, ws.player, A)
	worldstate.perk_remove(&ws, ws.player, B)
	or_list := []gamedb.Condition{has(A, true), has(B, false)}
	testing.expect(t, !conditions.all(&ctx, or_list), "OR fails with neither")
	worldstate.perk_add(&ws, ws.player, A)
	testing.expect(t, conditions.all(&ctx, or_list), "OR passes on the first alone")
	worldstate.perk_remove(&ws, ws.player, A)
	worldstate.perk_add(&ws, ws.player, B)
	testing.expect(t, conditions.all(&ctx, or_list), "OR passes on the second alone")

	// A group followed by a required AND term: (A OR B) AND C.
	C :: gamedb.Form_ID(0xC1)
	mixed := []gamedb.Condition{has(A, true), has(B, false), has(C, false)}
	testing.expect(t, !conditions.all(&ctx, mixed), "the trailing AND term still gates")
	worldstate.perk_add(&ws, ws.player, C)
	testing.expect(t, conditions.all(&ctx, mixed), "(A OR B) AND C passes")

	// The CK flags every member of a trailing OR run, the last one too: C AND (A OR B).
	trailing := []gamedb.Condition{has(C, false), has(A, true), has(B, true)}
	worldstate.perk_remove(&ws, ws.player, B)
	testing.expect(t, !conditions.all(&ctx, trailing), "a trailing OR group still gates")
	worldstate.perk_add(&ws, ws.player, A)
	testing.expect(t, conditions.all(&ctx, trailing), "C AND (A OR B) passes")
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
	ctx := conditions.Context{db = &db, ws = &ws, subject = ws.player, target = OTHER}
	worldstate.perk_add(&ws, ws.player, PERK)

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
	none := conditions.Context{db = &db, ws = &ws, subject = ws.player}
	testing.expect(t, conditions.all(&none, is_base), "no owning quest: passes")
	ctx := conditions.Context{db = &db, ws = &ws, subject = ws.player, quest = QUEST}
	testing.expect(t, conditions.all(&ctx, is_base), "the alias holds a ref of that base")
	empty := []gamedb.Condition{{function = 72, op = .Equal, value = 1, param1 = u64(BASE), run_on = .QuestAlias, param3 = 3}}
	testing.expect(t, !conditions.all(&ctx, empty), "an empty alias is a real answer")

	alias_ref := []gamedb.Condition{{function = 566, op = .Equal, value = 1, param1 = 2}}
	testing.expect(t, !conditions.all(&ctx, alias_ref), "the player is not in alias 2")
	ctx.subject = ref
	testing.expect(t, conditions.all(&ctx, alias_ref), "the ref is")

	e := worldstate.Story_Event{type = {'K', 'I', 'L', 'L'}, ref1 = ref}
	on_event := []gamedb.Condition{{function = 72, op = .Equal, value = 1, param1 = u64(BASE), run_on = .EventData, param3 = conditions.EVENT_ACTOR_1}}
	testing.expect(t, conditions.all(&ctx, on_event), "no event: passes")
	ctx.event = &e
	e.ref1 = ws.player
	testing.expect(t, !conditions.all(&ctx, on_event), "actor 1 is the player")
	e.ref1 = ref
	testing.expect(t, conditions.all(&ctx, on_event), "actor 1 is the ref")

	// GetEventData: param1 packs the function (low 16 bits) and the member (high 16 bits).
	e.value1 = 5
	value := []gamedb.Condition{{function = 576, op = .Equal, value = 5, param1 = 2 | conditions.EVENT_VALUE_1 << 16}}
	testing.expect(t, conditions.all(&ctx, value), "GetValue V1")
	is_id := []gamedb.Condition{{function = 576, op = .Equal, value = 1, param1 = 0 | conditions.EVENT_ACTOR_1 << 16, param2 = u64(BASE)}}
	testing.expect(t, conditions.all(&ctx, is_id), "GetIsID R1 reads the ref's base")
	e.ref1 = ws.player
	testing.expect(t, !conditions.all(&ctx, is_id), "the player is not that base")
}

// A few bodies over the stores: quest stages, globals, factions.
@(test)
test_conditions_quest_and_faction_reads :: proc(t: ^testing.T) {
	db: gamedb.DB
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ctx := conditions.Context{db = &db, ws = &ws, subject = ws.player}
	QUEST :: gamedb.Form_ID(0x0000_0C01)
	FACTION :: gamedb.Form_ID(0x0000_0F01)
	GLOB :: gamedb.Form_ID(0x0000_0E01)

	stage := []gamedb.Condition{{function = 58, op = .GreaterOrEqual, value = 20, param1 = u64(QUEST)}}
	done := []gamedb.Condition{{function = 59, op = .Equal, value = 1, param1 = u64(QUEST), param2 = 10}}
	testing.expect(t, !conditions.all(&ctx, stage) && !conditions.all(&ctx, done), "an untouched quest")
	worldstate.quest_set_stage(&ws, QUEST, 10)
	worldstate.quest_set_stage(&ws, QUEST, 20)
	testing.expect(t, conditions.all(&ctx, stage) && conditions.all(&ctx, done), "stage 20, 10 done")

	LOC :: gamedb.Form_ID(0x0000_0B01)
	data := []gamedb.Condition{{function = 606, op = .Equal, value = 2, param1 = u64(LOC), param2 = u64(FACTION)}}
	testing.expect(t, !conditions.all(&ctx, data), "unset keyword data reads 0")
	ws.keyword_data[{LOC, FACTION}] = 2
	testing.expect(t, conditions.all(&ctx, data), "GetKeywordDataForLocation")
	glob := []gamedb.Condition{{function = 74, op = .Equal, value = 3, param1 = u64(GLOB)}}
	worldstate.set_global(&ws, GLOB, 3)
	testing.expect(t, conditions.all(&ctx, glob), "GetGlobalValue")

	member := []gamedb.Condition{{function = 71, op = .Equal, value = 1, param1 = u64(FACTION)}}
	rank := []gamedb.Condition{{function = 73, op = .Equal, value = -1, param1 = u64(FACTION)}}
	testing.expect(t, !conditions.all(&ctx, member) && conditions.all(&ctx, rank), "not in the faction")
	worldstate.faction_set_rank(&ws, ws.player, FACTION, -1)
	testing.expect(t, !conditions.all(&ctx, member) && conditions.all(&ctx, rank), "rank -1 is not a member")
	worldstate.faction_set_rank(&ws, ws.player, FACTION, 0)
	testing.expect(t, conditions.all(&ctx, member), "rank 0 is")
}

// The story manager tree: nodes hang under their parent in sibling order, a quest node lists its
// quests with reset hours, and a QUST splits its conditions at NEXT.
@(test)
test_story_records :: proc(t: ^testing.T) {
	u32b :: proc(v: u32) -> [4]u8 {b: [4]u8; put_u32(b[:], 0, v); return b}
	f32b :: proc(v: f32) -> [4]u8 {b: [4]u8; put_f32(b[:], 0, v); return b}
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0900)
	field(&tes4, "HEDR", hedr[:])

	nodes := make([dynamic]u8, 0, 512);defer delete(nodes)
	root := make([dynamic]u8, 0, 32);defer delete(root)
	record(&nodes, "SMBN", 0, 0x0000_0801, root[:])
	ev := make([dynamic]u8, 0, 64);defer delete(ev)
	p := u32b(0x0801);field(&ev, "PNAM", p[:])
	field(&ev, "ENAM", transmute([]u8)string("KILL"))
	record(&nodes, "SMEN", 0, 0x0000_0802, ev[:])
	// Two quest nodes under the event, the second authored first: 0x804 comes after 0x803.
	q2 := make([dynamic]u8, 0, 64);defer delete(q2)
	p = u32b(0x0802);field(&q2, "PNAM", p[:])
	s := u32b(0x0803);field(&q2, "SNAM", s[:])
	record(&nodes, "SMQN", 0, 0x0000_0804, q2[:])
	q1 := make([dynamic]u8, 0, 128);defer delete(q1)
	field(&q1, "PNAM", p[:])
	ctda(&q1, 72, 0, 0, 1, 0x0000_0D01, 0)
	fl := u32b(0x0001_0000);field(&q1, "DNAM", fl[:])
	qa := u32b(0x0C01);field(&q1, "NNAM", qa[:])
	r := f32b(24);field(&q1, "RNAM", r[:])
	qb := u32b(0x0C02);field(&q1, "NNAM", qb[:])
	record(&nodes, "SMQN", 0, 0x0000_0803, q1[:])

	quests := make([dynamic]u8, 0, 256);defer delete(quests)
	qu := make([dynamic]u8, 0, 128);defer delete(qu)
	dnam: [12]u8;dnam[1] = 0x01 // Run Once
	field(&qu, "DNAM", dnam[:])
	field(&qu, "ENAM", transmute([]u8)string("KILL"))
	ctda(&qu, 58, 0, 0, 10, 0x0000_0C01, 0) // a dialogue condition
	field(&qu, "NEXT", {})
	ctda(&qu, 72, 0, 0, 1, 0x0000_0D01, 7, param3 = conditions.EVENT_ACTOR_1) // the event's victim
	ctda(&qu, 46, 0, 0, 1, 0, 7, param3 = conditions.EVENT_ACTOR_1)
	idx: [3]u8;field(&qu, "INDX", idx[:])
	ctda(&qu, 74, 0, 0, 1, 0x0000_0E01, 0) // a stage log condition: in neither list
	record(&quests, "QUST", 0, 0x0000_0C01, qu[:])

	out := make([dynamic]u8, 0, 1024);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("SMBN"), 0, nodes[:])
	group(&out, transmute([]u8)string("QUST"), 0, quests[:])
	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	testing.expect_value(t, len(db.story_roots), 1)
	e, eok := gamedb.story_node_of(&db, 0x0000_0802)
	testing.expect(t, eok && e.kind == .Event && string(e.event[:]) == "KILL", "event node")
	if testing.expect_value(t, len(e.children), 2) {
		testing.expect_value(t, e.children[0], gamedb.Form_ID(0x0000_0803))
		testing.expect_value(t, e.children[1], gamedb.Form_ID(0x0000_0804))
	}
	n, _ := gamedb.story_node_of(&db, 0x0000_0803)
	testing.expect_value(t, n.flags, u32(gamedb.STORY_DO_ALL_BEFORE_REPEATING))
	testing.expect_value(t, len(n.conditions), 1)
	if testing.expect_value(t, len(n.quests), 2) {
		testing.expect_value(t, n.quests[0], gamedb.Story_Quest{0x0000_0C01, 1})
		testing.expect_value(t, n.quests[1], gamedb.Story_Quest{0x0000_0C02, 0})
	}

	q, _ := gamedb.quest_baseline_of(&db, 0x0000_0C01)
	testing.expect(t, q.run_once && string(q.event[:]) == "KILL", "run once, keyed to KILL")
	testing.expect_value(t, len(q.dialogue_conditions), 1)
	testing.expect_value(t, len(q.event_conditions), 2)
	if len(q.event_conditions) == 2 {testing.expect_value(t, q.event_conditions[0].run_on, esm.Condition_Run_On.EventData)}
}

// The story manager walks the tree: node and quest conditions, the event consumed by the first start,
// Hours Until Reset, Random nodes in rounds, the story-only start rule and a failing required alias.
@(test)
test_story_manager :: proc(t: ^testing.T) {
	u32b :: proc(v: u32) -> [4]u8 {b: [4]u8; put_u32(b[:], 0, v); return b}
	f32b :: proc(v: f32) -> [4]u8 {b: [4]u8; put_f32(b[:], 0, v); return b}
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0900)
	field(&tes4, "HEDR", hedr[:])

	ROOT, EVENT, STACKED, RANDOM, LATER :: u32(0x801), u32(0x802), u32(0x803), u32(0x804), u32(0x805)
	QA, QB, QC, QD, QE, QSTORY :: u32(0xC01), u32(0xC02), u32(0xC03), u32(0xC04), u32(0xC05), u32(0xC06)
	nodes := make([dynamic]u8, 0, 1024);defer delete(nodes)
	record(&nodes, "SMBN", 0, ROOT, {})
	ev := make([dynamic]u8, 0, 64);defer delete(ev)
	p := u32b(ROOT);field(&ev, "PNAM", p[:])
	field(&ev, "ENAM", transmute([]u8)string("SCPT"))
	record(&nodes, "SMEN", 0, EVENT, ev[:])
	// STACKED (value1 == 1): QA, QB with a day's reset. RANDOM (value1 == 2): QC, QD. LATER: QE.
	quest_node :: proc(nodes: ^[dynamic]u8, form, previous: u32, value1: f32, flags: u32, quests: []u32, reset: f32) {
		b := make([dynamic]u8, 0, 128);defer delete(b)
		p := u32b(0x802);field(&b, "PNAM", p[:])
		if previous != 0 {s := u32b(previous);field(&b, "SNAM", s[:])}
		ctda(&b, 576, 0, 0, value1, 2 | conditions.EVENT_VALUE_1 << 16, 0) // GetEventData GetValue V1
		d := u32b(flags);field(&b, "DNAM", d[:])
		for q in quests {
			n := u32b(q);field(&b, "NNAM", n[:])
			r := f32b(reset * 24);field(&b, "RNAM", r[:])
		}
		record(nodes, "SMQN", 0, form, b[:])
	}
	quest_node(&nodes, STACKED, 0, 1, 0, {QA, QB}, 24)
	quest_node(&nodes, RANDOM, STACKED, 2, gamedb.STORY_RANDOM, {QC, QD}, 0)
	quest_node(&nodes, LATER, RANDOM, 1, 0, {QE}, 0)

	quests := make([dynamic]u8, 0, 1024);defer delete(quests)
	for q in ([]u32{QA, QB, QC, QD, QE, QSTORY}) {
		b := make([dynamic]u8, 0, 128);defer delete(b)
		dnam: [12]u8;field(&b, "DNAM", dnam[:])
		field(&b, "ENAM", transmute([]u8)string("SCPT"))
		field(&b, "NEXT", {})
		// QA wants actor 1 to be of base 0xD01; the events here send the player.
		if q == QA {ctda(&b, 576, 0, 0, 1, 0 | conditions.EVENT_ACTOR_1 << 16, 0, param2 = 0xD01)}
		if q == QSTORY {
			// A required Unique_Actor alias whose NPC_ is never placed: the start fails.
			id := u32b(0);field(&b, "ALST", id[:])
			fl := u32b(0);field(&b, "FNAM", fl[:])
			ua := u32b(0xD99);field(&b, "ALUA", ua[:])
			field(&b, "ALED", {})
		}
		record(&quests, "QUST", 0, q, b[:])
	}

	out := make([dynamic]u8, 0, 4096);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("SMBN"), 0, nodes[:])
	group(&out, transmute([]u8)string("QUST"), 0, quests[:])
	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	c := script.Call{ws = &ws, db = &db}
	running :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, q: u32) -> bool {return worldstate.quest_running(ws, db, gamedb.Form_ID(q))}
	send :: proc(c: ^script.Call, value1: i32) -> bool {
		return script.story_event(c, {type = worldstate.STORY_SCRIPT, ref1 = c.ws.player, value1 = value1})
	}

	testing.expect(t, !send(&c, 9), "no node takes value 9")
	testing.expect(t, send(&c, 1), "value 1 starts a quest")
	testing.expect(t, !running(&ws, &db, QA) && running(&ws, &db, QB), "QA's conditions fail, QB starts")
	testing.expect(t, !running(&ws, &db, QE), "the start consumed the event")
	testing.expect_value(t, ws.quest_events[gamedb.Form_ID(QB)].value1, i32(1))
	testing.expect_value(t, len(ws.story_quests), 1)

	worldstate.quest_set_running(&ws, gamedb.Form_ID(QB), false)
	testing.expect(t, send(&c, 1), "QB waits out its reset, so LATER's QE starts")
	testing.expect(t, running(&ws, &db, QE), "QE")
	ws.clock.hours += 25
	testing.expect(t, send(&c, 1) && running(&ws, &db, QB), "a day later QB starts again")

	testing.expect(t, send(&c, 2), "a random pick")
	first := QC if running(&ws, &db, QC) else QD
	worldstate.quest_set_running(&ws, gamedb.Form_ID(first), false)
	testing.expect(t, send(&c, 2), "a second pick")
	testing.expect(t, running(&ws, &db, QC ~ QD ~ first), "the round runs the other quest first")

	worldstate.quest_set_running(&ws, gamedb.Form_ID(QA), false)
	by_script := script.Call{ws = &ws, db = &db, self = gamedb.Form_ID(QA)}
	testing.expect(t, !script.n_quest_start(&by_script, nil).(bool), "Quest.Start refuses a quest with an event")
	testing.expect(t, !script.story_event(&c, {type = {'K', 'I', 'L', 'L'}}), "no KILL node")
	testing.expect(t, !script.start_quest(&c, gamedb.Form_ID(QSTORY)), "a required alias stays empty")
	testing.expect(t, !running(&ws, &db, QSTORY), "so the quest does not run")
}

// Alias fills: a world search with Match Conditions takes a different ref for each alias, Force Into
// copies one, dead actors do not fit (so a required alias fails the start), a search picks in rounds,
// From Event reads the event, and Create_Ref makes its ref at another alias.
@(test)
test_alias_fills :: proc(t: ^testing.T) {
	BANDIT, OTHER, MADE :: gamedb.Form_ID(0xB01), gamedb.Form_ID(0xB02), gamedb.Form_ID(0xB03)
	A, B, C :: gamedb.Form_ID(0xA01), gamedb.Form_ID(0xA02), gamedb.Form_ID(0xA03)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref)
	defer delete(db.ref_by_id)
	db.ref_by_id[A] = {form_id = A, base = BANDIT, pos = {10, 0, 0}, persistent = true}
	db.ref_by_id[B] = {form_id = B, base = BANDIT, persistent = true}
	db.ref_by_id[C] = {form_id = C, base = OTHER, persistent = true}
	db.persistent_refs = {A, B, C}
	gamedb.index_search(&db)
	defer gamedb.search_index_destroy(&db)
	db.quest_baseline = make(map[gamedb.Form_ID]gamedb.Quest_Baseline)
	defer delete(db.quest_baseline)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	c := script.Call{ws = &ws, db = &db}

	bandit := []gamedb.Condition{{function = 72, op = .Equal, value = 1, param1 = u64(BANDIT)}}
	search :: proc(id: u32, conds: []gamedb.Condition, flags: u32 = 0, force_into: i32 = -1) -> gamedb.Quest_Alias {
		return {id = id, fill = .Matching, alias = -1, force_into = force_into, flags = flags, conditions = conds}
	}
	ref_in :: proc(ws: ^worldstate.World_State, q: gamedb.Form_ID, id: i32) -> gamedb.Form_ID {return worldstate.alias_ref(ws, q, id)}

	Q1, Q2, Q3, Q4, Q5 :: gamedb.Form_ID(0xC01), gamedb.Form_ID(0xC02), gamedb.Form_ID(0xC03), gamedb.Form_ID(0xC04), gamedb.Form_ID(0xC05)
	q1 := []gamedb.Quest_Alias{search(0, bandit, force_into = 2), search(1, bandit), {id = 2, alias = -1, force_into = -1}}
	db.quest_baseline[Q1] = {aliases = q1}
	testing.expect(t, script.start_quest(&c, Q1), "Q1 starts")
	x, y := ref_in(&ws, Q1, 0), ref_in(&ws, Q1, 1)
	testing.expect(t, x != y && (x == A || x == B) && (y == A || y == B), "two bandits, not the same one")
	testing.expect_value(t, ref_in(&ws, Q1, 2), x)

	worldstate.set_dead(&ws, A, 0, true)
	worldstate.set_dead(&ws, B, 0, true)
	q2 := []gamedb.Quest_Alias{search(0, bandit)}
	db.quest_baseline[Q2] = {aliases = q2}
	testing.expect(t, !script.start_quest(&c, Q2), "no living bandit: a required alias fails the start")
	q2[0].flags = esm.ALIAS_ALLOW_DEAD
	testing.expect(t, script.start_quest(&c, Q2), "Allow Dead")
	worldstate.set_dead(&ws, A, 0, false)
	worldstate.set_dead(&ws, B, 0, false)

	q3 := []gamedb.Quest_Alias{search(0, bandit, esm.ALIAS_ALLOW_RESERVED)}
	db.quest_baseline[Q3] = {aliases = q3}
	testing.expect(t, script.start_quest(&c, Q3), "Q3 starts")
	first := ref_in(&ws, Q3, 0)
	worldstate.quest_set_running(&ws, Q3, false)
	testing.expect(t, script.start_quest(&c, Q3), "Q3 again")
	testing.expect(t, ref_in(&ws, Q3, 0) != first, "the round takes the other bandit")

	q4 := []gamedb.Quest_Alias{{id = 0, fill = .Matching, alias = -1, force_into = -1, event_member = conditions.EVENT_ACTOR_1, conditions = bandit}}
	db.quest_baseline[Q4] = {aliases = q4}
	testing.expect(t, !script.start_quest(&c, Q4, &{ref1 = C}), "the event's actor is no bandit")
	testing.expect(t, script.start_quest(&c, Q4, &{ref1 = B}), "this one is")
	testing.expect_value(t, ref_in(&ws, Q4, 0), B)

	// Location_Ref: the living ref of type BOSS in location alias 0.
	LOC, BOSS :: gamedb.Form_ID(0xD01), gamedb.Form_ID(0xD02)
	Q6 :: gamedb.Form_ID(0xC06)
	db.locations = make(map[gamedb.Form_ID]gamedb.Location)
	defer delete(db.locations)
	db.locations[LOC] = {special_refs = {{BOSS, A}, {BOSS, C}, {0xD03, B}}}
	worldstate.set_dead(&ws, C, 0, true)
	q6 := []gamedb.Quest_Alias{{id = 0, location = true, fill = .Specific, target = LOC, alias = -1, force_into = -1}, {id = 1, fill = .Location_Ref, target = BOSS, alias = 0, force_into = -1, flags = esm.ALIAS_ALLOW_RESERVED}}
	db.quest_baseline[Q6] = {aliases = q6}
	testing.expect(t, script.start_quest(&c, Q6), "Q6 starts")
	testing.expect_value(t, ref_in(&ws, Q6, 1), A)
	worldstate.set_dead(&ws, C, 0, false)

	// A location From Event: a cleared location does not fit unless Allow Cleared.
	Q7 :: gamedb.Form_ID(0xC07)
	q7 := []gamedb.Quest_Alias{{id = 0, location = true, fill = .Matching, alias = -1, force_into = -1, event_member = conditions.EVENT_LOCATION_1}}
	db.quest_baseline[Q7] = {aliases = q7}
	testing.expect(t, script.start_quest(&c, Q7, &{location1 = LOC}), "Q7 takes the event's location")
	is_loc := []gamedb.Condition{{function = 605, op = .Equal, value = 1, param1 = 0, param2 = u64(LOC)}}
	qctx := conditions.Context{db = &db, ws = &ws, quest = Q7}
	testing.expect(t, conditions.all(&qctx, is_loc), "LocAliasIsLocation")
	worldstate.quest_set_running(&ws, Q7, false)
	ws.cleared[LOC] = true
	testing.expect(t, !script.start_quest(&c, Q7, &{location1 = LOC}), "a cleared location does not fit")
	q7[0].flags = esm.ALIAS_ALLOW_CLEARED
	testing.expect(t, script.start_quest(&c, Q7, &{location1 = LOC}), "Allow Cleared")

	// Alias data: its factions, keywords, flags and spells count only while it holds the ref, and
	// clearing it leaves the ref's own membership alone. Its items and display name stay.
	Q8, GUILD, OWN, MARKED :: gamedb.Form_ID(0xC08), gamedb.Form_ID(0xE01), gamedb.Form_ID(0xE02), gamedb.Form_ID(0xE03)
	WARD, COIN, TITLE :: gamedb.Form_ID(0xE04), gamedb.Form_ID(0xE05), gamedb.Form_ID(0xE06)
	db.names = make(map[gamedb.Form_ID]string)
	defer delete(db.names)
	db.names[BANDIT] = "Bandit"
	db.messages = make(map[gamedb.Form_ID]gamedb.Message)
	defer delete(db.messages)
	db.messages[TITLE] = {title = "<BaseName> the Marked"}
	q8 := []gamedb.Quest_Alias{{
		id = 0, fill = .Specific, target = B, alias = -1, force_into = -1,
		flags = esm.ALIAS_ALLOW_RESERVED | esm.ALIAS_ESSENTIAL | esm.ALIAS_PROTECTED,
		factions = {GUILD, OWN}, keywords = {MARKED}, spells = {WARD}, items = {{COIN, 3}}, display_name = TITLE,
	}}
	db.quest_baseline[Q8] = {aliases = q8}
	worldstate.faction_set_rank(&ws, B, OWN, 2)
	testing.expect(t, script.start_quest(&c, Q8), "Q8 starts")
	testing.expect(t, worldstate.in_faction(&ws, &db, B, GUILD), "a member through the alias")
	testing.expect(t, worldstate.has_keyword(&ws, &db, B, MARKED), "the alias's keyword")
	testing.expect(t, worldstate.actor_flag(&ws, &db, B, esm.ACBS_ESSENTIAL) && worldstate.actor_flag(&ws, &db, B, esm.ACBS_PROTECTED), "essential and protected")
	testing.expect(t, worldstate.has_spell(&ws, &db, B, WARD), "the alias's spell")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, B, COIN), i32(3))
	testing.expect_value(t, worldstate.display_name(&ws, &db, B), "Bandit the Marked")
	own, _ := worldstate.faction_rank(&ws, &db, B, OWN)
	testing.expect_value(t, own, i32(2))
	script.clear_aliases(&c, Q8)
	testing.expect(t, !worldstate.in_faction(&ws, &db, B, GUILD) && !worldstate.has_keyword(&ws, &db, B, MARKED), "gone with the alias")
	testing.expect(t, !worldstate.actor_flag(&ws, &db, B, esm.ACBS_ESSENTIAL) && !worldstate.has_spell(&ws, &db, B, WARD), "flags and spells go too")
	testing.expect(t, worldstate.in_faction(&ws, &db, B, OWN), "its own membership stays")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, B, COIN), i32(3))
	testing.expect_value(t, worldstate.display_name(&ws, &db, B), "Bandit the Marked")
	q8[0].flags |= esm.ALIAS_CLEARS_NAME
	worldstate.quest_set_running(&ws, Q8, false)
	testing.expect(t, script.start_quest(&c, Q8), "Q8 starts again")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, B, COIN), i32(6))
	script.clear_aliases(&c, Q8)
	testing.expect_value(t, worldstate.display_name(&ws, &db, B), "Bandit")

	// A Quest Object the player carries cannot be dropped or stored, save in a Quest Object of its quest.
	Q9, BOX :: gamedb.Form_ID(0xC09), gamedb.Form_ID(0xA09)
	q9 := []gamedb.Quest_Alias{{id = 0, fill = .Specific, target = C, alias = -1, force_into = -1, flags = esm.ALIAS_ALLOW_RESERVED | esm.ALIAS_QUEST_OBJECT}}
	db.quest_baseline[Q9] = {aliases = q9}
	ws.carried[C] = ws.player
	testing.expect(t, script.start_quest(&c, Q9), "Q9 starts")
	testing.expect(t, worldstate.quest_object_kept(&ws, &db, ws.player, OTHER), "no drop")
	testing.expect(t, worldstate.quest_object_kept(&ws, &db, ws.player, OTHER, BOX), "no store")
	worldstate.fill_alias(&ws, formid.alias_handle(Q9, 1) or_else 0, BOX)
	q9b := []gamedb.Quest_Alias{q9[0], {id = 1, alias = -1, force_into = -1, flags = esm.ALIAS_QUEST_OBJECT}}
	db.quest_baseline[Q9] = {aliases = q9b}
	testing.expect(t, !worldstate.quest_object_kept(&ws, &db, ws.player, OTHER, BOX), "a Quest Object box of the quest takes it")
	testing.expect(t, worldstate.holds_quest_object(&ws, &db, ws.player), "its holder is never cleaned up")
	delete_key(&ws.carried, C)

	q5 := []gamedb.Quest_Alias{{id = 0, fill = .Specific, target = A, alias = -1, force_into = -1, flags = esm.ALIAS_ALLOW_RESERVED}, {id = 1, fill = .Create_Ref, target = MADE, alias = 0, force_into = -1}}
	db.quest_baseline[Q5] = {aliases = q5}
	testing.expect(t, script.start_quest(&c, Q5), "Q5 starts")
	made := ref_in(&ws, Q5, 1)
	testing.expect(t, worldstate.ref_base(&ws, &db, made) == MADE && worldstate.ref_pos(&ws, &db, made) == {10, 0, 0}, "made at alias 0")
}

// LCTN special refs: the master list plus the added ones, minus the removed ones. A later override
// with only ACSR (Dawnguard's Bleak Falls Barrow) edits the master list; it does not replace it.
@(test)
test_location_special_refs :: proc(t: ^testing.T) {
	entry :: proc(b: ^[dynamic]u8, ref_type, ref: u32) {
		e: [16]u8;put_u32(e[:], 0, ref_type);put_u32(e[:], 4, ref)
		append(b, ..e[:])
	}
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0900)
	field(&tes4, "HEDR", hedr[:])
	lcsr := make([dynamic]u8, 0, 64);defer delete(lcsr)
	entry(&lcsr, 0xD02, 0xA01)
	entry(&lcsr, 0xD03, 0xA02)
	acsr := make([dynamic]u8, 0, 32);defer delete(acsr)
	entry(&acsr, 0xD02, 0xA03)
	loc := make([dynamic]u8, 0, 128);defer delete(loc)
	field(&loc, "LCSR", lcsr[:])
	field(&loc, "ACSR", acsr[:])
	rc: [4]u8;put_u32(rc[:], 0, 0xA02);field(&loc, "RCSR", rc[:])
	locs := make([dynamic]u8, 0, 256);defer delete(locs)
	record(&locs, "LCTN", 0, 0x0000_0B01, loc[:])
	db := gamedb.build(build_locations(tes4[:], locs[:]))
	defer gamedb.destroy(&db)
	bosses := gamedb.location_special_refs(&db, 0x0000_0B01, 0x0000_0D02)
	testing.expect(t, len(bosses) == 2 && bosses[0] == 0xA01 && bosses[1] == 0xA03, "master and added")
	testing.expect_value(t, len(gamedb.location_special_refs(&db, 0x0000_0B01, 0x0000_0D03)), 0)
	testing.expect(t, gamedb.has_ref_type(&db, 0xA03, 0xD02) && !gamedb.has_ref_type(&db, 0xA02, 0xD03), "ref types, minus the removed")

	over := make([dynamic]u8, 0, 32);defer delete(over)
	added := make([dynamic]u8, 0, 32);defer delete(added)
	entry(&added, 0xD02, 0xA04)
	field(&over, "ACSR", added[:])
	record(&locs, "LCTN", 0, 0x0000_0B01, over[:])
	db2 := gamedb.build(build_locations(tes4[:], locs[:]))
	defer gamedb.destroy(&db2)
	bosses = gamedb.location_special_refs(&db2, 0x0000_0B01, 0x0000_0D02)
	testing.expect(t, len(bosses) == 2 && bosses[0] == 0xA01 && bosses[1] == 0xA04, "override edits the master list")
	testing.expect_value(t, len(gamedb.location_special_refs(&db2, 0x0000_0B01, 0x0000_0D03)), 1)
}

@(private = "file")
build_locations :: proc(tes4, locs: []u8) -> []u8 {
	out := make([dynamic]u8, 0, 512, context.temp_allocator)
	record(&out, "TES4", 0, 0, tes4)
	group(&out, transmute([]u8)string("LCTN"), 0, locs)
	return out[:]
}

// Dialogue records: a topic's INFOs sit in its child group (type 7) and keep their PNAM order; an
// INFO carries its flags, reset hours, responses, conditions and links; a branch names its topic.
@(test)
test_dialogue_records :: proc(t: ^testing.T) {
	u32b :: proc(v: u32) -> [4]u8 {b: [4]u8; put_u32(b[:], 0, v); return b}
	tes4 := make([dynamic]u8, 0, 32);defer delete(tes4)
	hedr: [12]u8;put_f32(hedr[:], 0, 1.7);put_u32(hedr[:], 8, 0x0000_0900)
	field(&tes4, "HEDR", hedr[:])

	TOPIC, FIRST, SECOND, BRANCH :: u32(0x0901), u32(0x0902), u32(0x0903), u32(0x0904)
	dial := make([dynamic]u8, 0, 64);defer delete(dial)
	field(&dial, "FULL", transmute([]u8)string("Tell me about the war.\x00"))
	q := u32b(0x0C01);field(&dial, "QNAM", q[:])
	field(&dial, "DATA", []u8{0, 0, 0, 0})
	field(&dial, "SNAM", transmute([]u8)string("CUST"))

	second := make([dynamic]u8, 0, 128);defer delete(second) // authored first, but it follows FIRST
	p := u32b(FIRST);field(&second, "PNAM", p[:])
	enam: [4]u8;enam[0] = u8(gamedb.INFO_GOODBYE);put_u16(enam[:], 2, 5461) // 2 hours
	field(&second, "ENAM", enam[:])
	trdt: [24]u8;trdt[12] = 1
	field(&second, "TRDT", trdt[:])
	field(&second, "NAM1", transmute([]u8)string("Ask someone else.\x00"))
	ctda(&second, 72, 0, 0, 1, 0x0000_0D01, 0)
	first := make([dynamic]u8, 0, 64);defer delete(first)
	link := u32b(TOPIC);field(&first, "TCLT", link[:])
	infos := make([dynamic]u8, 0, 256);defer delete(infos)
	record(&infos, "INFO", 0, SECOND, second[:])
	record(&infos, "INFO", 0, FIRST, first[:])

	br := make([dynamic]u8, 0, 64);defer delete(br)
	field(&br, "QNAM", q[:])
	d := u32b(gamedb.BRANCH_TOP_LEVEL);field(&br, "DNAM", d[:])
	st := u32b(TOPIC);field(&br, "SNAM", st[:])

	dials := make([dynamic]u8, 0, 512);defer delete(dials)
	record(&dials, "DIAL", 0, TOPIC, dial[:])
	label := u32b(TOPIC)
	group(&dials, label[:], 7, infos[:])
	branches := make([dynamic]u8, 0, 128);defer delete(branches)
	record(&branches, "DLBR", 0, BRANCH, br[:])
	out := make([dynamic]u8, 0, 1024);defer delete(out)
	record(&out, "TES4", 0, 0, tes4[:])
	group(&out, transmute([]u8)string("DIAL"), 0, dials[:])
	group(&out, transmute([]u8)string("DLBR"), 0, branches[:])
	db := gamedb.build(out[:])
	defer gamedb.destroy(&db)

	topic, tok := gamedb.topic_of(&db, gamedb.Form_ID(TOPIC))
	testing.expect(t, tok && topic.quest == 0x0C01 && string(topic.subtype_name[:]) == "CUST", "the topic")
	testing.expect_value(t, gamedb.name_of(&db, gamedb.Form_ID(TOPIC)), "Tell me about the war.")
	if testing.expect_value(t, len(topic.infos), 2) {
		testing.expect(t, topic.infos[0] == gamedb.Form_ID(FIRST) && topic.infos[1] == gamedb.Form_ID(SECOND), "PNAM order")
	}
	info, _ := gamedb.info_of(&db, gamedb.Form_ID(SECOND))
	testing.expect(t, info.topic == gamedb.Form_ID(TOPIC) && info.flags & gamedb.INFO_GOODBYE != 0, "topic and flags")
	testing.expect(t, abs(info.reset_hours - 2) < 0.01, "reset hours")
	if testing.expect_value(t, len(info.responses), 1) {
		testing.expect(t, info.responses[0].number == 1 && info.responses[0].text == "Ask someone else.", "the response")
	}
	testing.expect_value(t, len(info.conditions), 1)
	f, _ := gamedb.info_of(&db, gamedb.Form_ID(FIRST))
	testing.expect(t, len(f.links) == 1 && f.links[0] == gamedb.Form_ID(TOPIC), "TCLT links")
	b, _ := gamedb.branch_of(&db, gamedb.Form_ID(BRANCH))
	testing.expect(t, b.start == gamedb.Form_ID(TOPIC) && b.flags == gamedb.BRANCH_TOP_LEVEL, "the branch")
}

// The tail functions over data we hold: dead counts, carried items, spell targets, object types,
// faction relations, and resting stubs for systems not built yet.
@(test)
test_condition_tail :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	GUARD, NPC, ARMOR, RING, CHEST, SPELL, FACTION_A, FACTION_B, OTHER, OTHER_NPC :: gamedb.Form_ID(0xE01), gamedb.Form_ID(0xE02), gamedb.Form_ID(0xE03), gamedb.Form_ID(0xE04), gamedb.Form_ID(0xE05), gamedb.Form_ID(0xE06), gamedb.Form_ID(0xE07), gamedb.Form_ID(0xE08), gamedb.Form_ID(0xE09), gamedb.Form_ID(0xE0A)
	db: gamedb.DB
	db.ref_by_id = make(map[gamedb.Form_ID]gamedb.Ref)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base)
	db.form_kinds = make(map[gamedb.Form_ID]gamedb.Form_Kind)
	db.factions = make(map[gamedb.Form_ID]gamedb.Faction)
	defer {delete(db.ref_by_id);delete(db.actors);delete(db.form_kinds);delete(db.factions)}
	db.ref_by_id[GUARD] = {form_id = GUARD, base = NPC}
	db.ref_by_id[RING] = {form_id = RING, base = ARMOR}
	db.ref_by_id[OTHER] = {form_id = OTHER, base = OTHER_NPC}
	db.actors[NPC] = {factions = []gamedb.Faction_Membership{{FACTION_A, 0}, {formid.IS_GUARD_FACTION, 0}}}
	db.actors[OTHER_NPC] = {factions = []gamedb.Faction_Membership{{FACTION_B, 0}}}
	db.form_kinds[ARMOR] = .Armor
	db.factions[FACTION_A] = {relations = []gamedb.Faction_Relation{{faction = FACTION_B, combat = .Enemy}}}
	ctx := conditions.Context{db = &db, ws = &ws, subject = GUARD}
	cond :: proc(fn: u16, p1: gamedb.Form_ID = 0, value: f32 = 1) -> []gamedb.Condition {
		c := make([]gamedb.Condition, 1, context.temp_allocator)
		c[0] = {function = fn, op = .Equal, value = value, param1 = u64(p1)}
		return c
	}

	testing.expect(t, conditions.all(&ctx, cond(84, NPC, 0)), "no NPC dead yet")
	worldstate.set_dead(&ws, GUARD, 0, true)
	testing.expect(t, conditions.all(&ctx, cond(84, NPC, 1)), "GetDeadCount counts the base's dead")
	testing.expect(t, conditions.all(&ctx, cond(432, 13)), "GetIsObjectType: an actor")
	testing.expect(t, conditions.all(&ctx, cond(449, OTHER, 1)), "GetFactionRelation: enemies")
	testing.expect(t, conditions.all(&ctx, cond(503)), "GetAllowWorldInteractions rests at 1")
	testing.expect(t, conditions.all(&ctx, cond(125)), "IsGuard: in IsGuardFaction")
	actorstate.request(&ws.states, GUARD, actorstate.SNEAK)
	testing.expect(t, conditions.all(&ctx, cond(286)), "IsSneaking")
	testing.expect(t, conditions.all(&ctx, cond(62, 0, 0)), "IsRaining rests at 0")

	ctx.subject = RING
	testing.expect(t, conditions.all(&ctx, cond(432, 1)), "GetIsObjectType: armor")
	ws.carried[RING] = CHEST
	testing.expect(t, conditions.all(&ctx, cond(624, CHEST)), "GetInContainer")
}

// The Workstream L tail: reads over stores the natives share, and IsMoving at rest.
@(test)
test_condition_tail_queries :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ACTOR, NPC, KILLER :: gamedb.Form_ID(0xF01), gamedb.Form_ID(0xF02), gamedb.Form_ID(0xF03)
	db: gamedb.DB
	defer delete(db.ref_by_id)
	db.ref_by_id[ACTOR] = {form_id = ACTOR, base = NPC}
	ctx := conditions.Context{db = &db, ws = &ws, subject = ACTOR}
	holds :: proc(ctx: ^conditions.Context, fn: u16, value: f32, p1: gamedb.Form_ID = 0) -> bool {
		c := []gamedb.Condition{{function = fn, op = .Equal, value = value, param1 = u64(p1)}}
		return conditions.all(ctx, c)
	}

	testing.expect(t, holds(&ctx, 698, 1), "IsAllowedToFly by default")
	worldstate.set_allow_flying(&ws, ACTOR, false)
	testing.expect(t, holds(&ctx, 698, 0), "SetAllowFlying(false) grounds it")
	testing.expect(t, holds(&ctx, 408, 0, KILLER), "nobody killed it")
	ws.killers[ACTOR] = KILLER
	testing.expect(t, holds(&ctx, 408, 1, KILLER), "IsKiller")
	testing.expect(t, holds(&ctx, 5, 0), "unlocked")
	worldstate.set_locked(&ws, ACTOR, 0, true)
	testing.expect(t, holds(&ctx, 5, 1), "GetLocked")
	worldstate.set_open(&ws, ACTOR, 0, true)
	testing.expect(t, holds(&ctx, 157, 1), "GetOpenState: open")
	testing.expect(t, holds(&ctx, 726, 0), "a placed ref exists")
	worldstate.set_deleted(&ws, ACTOR, 0)
	testing.expect(t, holds(&ctx, 726, 1), "a deleted ref does not")
	testing.expect(t, holds(&ctx, 79, 0), "GetQuestVariable is deprecated")
	testing.expect(t, holds(&ctx, 25, 0), "IsMoving rests at 0")
	testing.expect(t, holds(&ctx, 638, 0), "an acquaintance")
	worldstate.rel_set(&ws, &db, ACTOR, ws.player, 1)
	testing.expect(t, holds(&ctx, 638, 1), "a friend")
}

// Package data parameters read the package the conditions belong to (ForceGreet's "Player must be
// detected" branches): GetDetected(<data slot ref>) and GetNumericPackageData(<slot>).
@(test)
test_conditions_package_data :: proc(t: ^testing.T) {
	NPC :: gamedb.Form_ID(0xA1)
	PACK :: gamedb.Form_ID(0xB1)
	db: gamedb.DB
	db.packages = make(map[gamedb.Form_ID]gamedb.Package, context.temp_allocator)
	db.packages[PACK] = {inputs = {{index = 0x11, value = gamedb.Package_Target{kind = .SpecificRef, form = formid.PLAYER}}, {index = 0x4f, value = true}}}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	ctx := conditions.Context{db = &db, ws = &ws, subject = NPC, pack = PACK}

	detected := []gamedb.Condition{{function = 45, op = .Equal, value = 1, flags = {.Use_Pack_Data}, param1 = 0x11}}
	must := []gamedb.Condition{{function = 612, op = .Equal, value = 1, param1 = 0x4f}}
	testing.expect(t, !conditions.all(&ctx, detected), "the player is not detected yet")
	testing.expect(t, conditions.all(&ctx, must), "the Bool slot reads 1")
	worldstate.set_awareness(&ws, NPC, ws.player, {1, true})
	testing.expect(t, conditions.all(&ctx, detected), "detected through the data slot")
}
