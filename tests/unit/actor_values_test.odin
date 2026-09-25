package unit_tests

import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"

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
