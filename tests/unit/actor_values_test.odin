package unit_tests

import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import "../../src/worldstate"

// An auto-calc NPC_'s base values: the race's start, its ACBS offset and the class share of the
// level-up points, whole sets first and the rest heaviest first, ties to the higher index.
@(test)
test_actor_value_base :: proc(t: ^testing.T) {
	F :: gamedb.Form_ID
	GUARD, TEMPLATED, RACE, CLASS :: F(0x100), F(0x101), F(0x200), F(0x300)
	db: gamedb.DB
	defer {delete(db.actors);delete(db.races);delete(db.classes)}

	race: gamedb.Race
	race.info.health, race.info.magicka, race.info.stamina, race.info.carry_weight = 50, 50, 50, 300
	race.info.bonuses[0] = {skill = 6, bonus = 5} // OneHanded +5
	race.info.bonus_count = 1
	db.races[RACE] = race
	class: gamedb.Class
	class.info.health_weight, class.info.magicka_weight = 1, 1
	class.info.skill_weights[0], class.info.skill_weights[3], class.info.skill_weights[4] = 2, 1, 1 // OneHanded, Block, Smithing
	db.classes[CLASS] = class
	db.actors[GUARD] = {flags = esm.ACBS_AUTO_CALC_STATS, level = 3, race = RACE, class = CLASS, health_off = -10, ai = {1, 3, 0, 0, 0, 0}}
	db.actors[TEMPLATED] = {level = 40, template = GUARD, template_flags = esm.ACBS_TEMPLATE_STATS | esm.ACBS_TEMPLATE_TRAITS}

	base :: proc(db: ^gamedb.DB, form: gamedb.Form_ID, av: string) -> f32 {return gamedb.actor_value_base(db, form, av)}
	// 20 attribute points split 10/10; health adds 5 per level above 1 and the -10 offset.
	testing.expect_value(t, base(&db, GUARD, "Health"), f32(50 - 10 + 10 + 10))
	testing.expect_value(t, base(&db, GUARD, "Magicka"), f32(60))
	testing.expect_value(t, base(&db, GUARD, "Stamina"), f32(50))
	// 16 skill points over weights 2/1/1: sets of 4 give 8/4/4 and 0 are left.
	testing.expect_value(t, base(&db, GUARD, "OneHanded"), f32(15 + 5 + 8))
	testing.expect_value(t, base(&db, GUARD, "Block"), f32(19))
	class.info.skill_weights[0] = 3
	db.classes[CLASS] = class
	// 16 points over 3/1/1: sets of 3 give 9/3/3, 1 left, to the heaviest: OneHanded 10.
	testing.expect_value(t, base(&db, GUARD, "OneHanded"), f32(15 + 5 + 10))
	class.info.skill_weights[0] = 1
	db.classes[CLASS] = class
	// 16 over 1/1/1: sets of 5 each, 1 left, the tie goes to the highest index: Smithing.
	testing.expect_value(t, base(&db, GUARD, "Smithing"), f32(21))
	testing.expect_value(t, base(&db, GUARD, "Block"), f32(20))

	testing.expect_value(t, base(&db, GUARD, "Confidence"), f32(3)) // AIDT
	testing.expect_value(t, base(&db, GUARD, "CarryWeight"), f32(300)) // race
	testing.expect_value(t, base(&db, GUARD, "HealRateMult"), f32(100)) // implicit
	testing.expect_value(t, base(&db, TEMPLATED, "Health"), base(&db, GUARD, "Health")) // stats and race from the template
}

// Regen restores rate% of max per second after the pause a drop starts; reaching 0 pauses longer.
// A rate of 0 never regenerates.
@(test)
test_actor_value_regen :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	A :: gamedb.Form_ID(0xA1)
	STILL :: gamedb.Form_ID(0xA2)
	for actor in ([]gamedb.Form_ID{A, STILL}) {worldstate.av_set_base(&ws, actor, "Health", 100)}
	worldstate.av_set_base(&ws, A, "HealRate", 10)
	ws.ai.loaded[A] = true // loaded: every tick

	worldstate.av_damage(&ws, nil, A, "Health", 50)
	worldstate.av_damage(&ws, nil, STILL, "Health", 50)
	worldstate.av_regen(&ws, nil, 0.5)
	testing.expect_value(t, worldstate.av_current(&ws, nil, A, "Health"), 50) // paused
	worldstate.av_regen(&ws, nil, 1.5)
	testing.expect_value(t, worldstate.av_current(&ws, nil, A, "Health"), 60)
	testing.expect_value(t, worldstate.av_current(&ws, nil, STILL, "Health"), 50)

	worldstate.av_damage(&ws, nil, A, "Health", 60)
	worldstate.av_regen(&ws, nil, 4)
	testing.expect_value(t, worldstate.av_current(&ws, nil, A, "Health"), 0) // the longer pause
	worldstate.av_regen(&ws, nil, 100)
	testing.expect_value(t, worldstate.av_current(&ws, nil, A, "Health"), 100) // never past max

	// Outside the loaded cells an actor regenerates on its turn, with every second it is owed: here
	// a wait's 2 s arrive on a tick that is not its turn.
	ws2: worldstate.World_State
	worldstate.init(&ws2)
	defer worldstate.destroy(&ws2)
	FAR :: gamedb.Form_ID(0xAE) // 0xAE % REGEN_TURNS == 0: its turn is every 6th tick
	worldstate.av_set_base(&ws2, FAR, "Health", 100)
	worldstate.av_set_base(&ws2, FAR, "HealRate", 10)
	worldstate.av_damage(&ws2, nil, FAR, "Health", 50)
	for s in ([]f32{0.5, 0.5, 2, 0.5, 0.5}) {worldstate.av_regen(&ws2, nil, s)}
	testing.expect_value(t, worldstate.av_current(&ws2, nil, FAR, "Health"), 50) // not its turn yet
	worldstate.av_regen(&ws2, nil, 0.5)
	testing.expect_value(t, worldstate.av_current(&ws2, nil, FAR, "Health"), 85) // 4.5 s owed, less the 1 s pause
}

// A skill is latched: its capacity is its level, and training stops at a separate soft cap. A pool
// is its own stock under its capacity, the cap, so a raised cap does not raise it. A static value
// takes no cap.
@(test)
test_actor_value_kinds :: proc(t: ^testing.T) {
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	A :: gamedb.Form_ID(0xA1)

	worldstate.av_set_base(&ws, A, "OneHanded", 30)
	worldstate.av_mod(&ws, A, "OneHanded", 20)
	testing.expect(t, worldstate.av_set_cap(&ws, A, "OneHanded", 150), "a skill takes a cap")
	testing.expect_value(t, worldstate.av_max(&ws, nil, A, "OneHanded"), 50)
	testing.expect_value(t, worldstate.av_train_cap(&ws, nil, A, "OneHanded"), 150)

	worldstate.av_create(&ws, "Mana", 10, .Pool)
	mana, _ := worldstate.av_name(&ws, "Mana")
	testing.expect_value(t, worldstate.av_max(&ws, nil, A, mana), 100)
	worldstate.av_set_cap(&ws, A, mana, 150)
	testing.expect(t, worldstate.av_max(&ws, nil, A, mana) == 150 && worldstate.av_current(&ws, nil, A, mana) == 10, "a raised cap leaves the stock")

	worldstate.av_set_base(&ws, A, "Health", 100)
	worldstate.av_damage(&ws, nil, A, "Health", 20)
	worldstate.av_mod(&ws, A, "Health", 50)
	testing.expect_value(t, worldstate.av_current(&ws, nil, A, "Health"), 130)
	testing.expect(t, !worldstate.av_set_cap(&ws, A, "SpeedMult", 500), "a static value has no cap")
}

// An actor's bounds: its own OBND, else its traits template's, else its race's, else human.
@(test)
test_actor_bounds :: proc(t: ^testing.T) {
	RACE :: gamedb.Form_ID(0x10)
	OWN :: gamedb.Form_ID(0x20)
	TEMPLATED :: gamedb.Form_ID(0x21)
	BARE :: gamedb.Form_ID(0x22)
	OTHER :: gamedb.Form_ID(0x23)
	box := [2][3]f32{{-10, -10, 0}, {10, 10, 50}}
	race_box := [2][3]f32{{-5, -5, 0}, {5, 5, 20}}
	db: gamedb.DB
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.race_bounds = make(map[gamedb.Form_ID][2][3]f32, context.temp_allocator)
	db.actors[OWN] = {bounds = box}
	db.actors[TEMPLATED] = {template = OWN, template_flags = esm.ACBS_TEMPLATE_TRAITS}
	db.actors[BARE] = {race = RACE}
	db.actors[OTHER] = {race = 0x11}
	db.race_bounds[RACE] = race_box

	testing.expect_value(t, gamedb.actor_bounds(&db, OWN), box)
	testing.expect_value(t, gamedb.actor_bounds(&db, TEMPLATED), box)
	testing.expect_value(t, gamedb.actor_bounds(&db, BARE), race_box)
	testing.expect_value(t, gamedb.actor_bounds(&db, OTHER), gamedb.HUMAN_BOUNDS)
}

// Sprinting spends 7 stamina a second, 2% more per unit of worn armor weight; a held weapon's weight
// does not count.
@(test)
test_sprint_drain :: proc(t: ^testing.T) {
	F :: gamedb.Form_ID
	A, ARMOR, SWORD :: F(0x14), F(0x100), F(0x101)
	db: gamedb.DB
	defer {delete(db.base_weight);delete(db.equip_slots)}
	db.base_weight[ARMOR], db.base_weight[SWORD] = 20, 10
	db.equip_slots[ARMOR], db.equip_slots[SWORD] = {kind = .Armor}, {kind = .Weapon}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	testing.expect_value(t, worldstate.sprint_drain(&ws, &db, A), 7)
	eq := worldstate.equipment(&ws, &db, A)
	append(&eq.worn, worldstate.Worn{item = ARMOR}, worldstate.Worn{item = SWORD})
	testing.expect(t, abs(worldstate.sprint_drain(&ws, &db, A) - 9.8) < 1e-4)
}
