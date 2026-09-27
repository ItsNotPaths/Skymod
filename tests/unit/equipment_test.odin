package unit_tests

import "core:os"
import "core:testing"
import "../../src/gamedb"
import "../../src/worldstate"

@(private = "file")
Gear :: enum gamedb.Form_ID {
	Helmet = 0x100,
	Hood   = 0x101, // head + hair
	Shield = 0x102,
	Greatsword = 0x103,
	Dagger = 0x104,
	Mace   = 0x105,
	Flames = 0x106, // left-hand spell
	Robes  = 0x107,
}

// Skyrim.esm's EQUP forms built from the two hands.
@(private = "file")
SHIELD :: gamedb.Form_ID(0x141E8)
@(private = "file")
BOTH_HANDS :: gamedb.Form_ID(0x13F45)
@(private = "file")
EITHER_HAND :: gamedb.Form_ID(0x13F44)
@(private = "file")
LEFT := [1]gamedb.Form_ID{gamedb.EQUP_LEFT_HAND}
@(private = "file")
TWO_HANDS := [2]gamedb.Form_ID{gamedb.EQUP_LEFT_HAND, gamedb.EQUP_RIGHT_HAND}

@(private = "file")
gear_db :: proc(db: ^gamedb.DB) {
	db.equip_slots = make(map[gamedb.Form_ID]gamedb.Equip_Slot, context.temp_allocator)
	db.equip_slots[gamedb.Form_ID(Gear.Helmet)] = {kind = .Armor, biped = 0x01}
	db.equip_slots[gamedb.Form_ID(Gear.Hood)] = {kind = .Armor, biped = 0x03}
	db.equip_slots[gamedb.Form_ID(Gear.Shield)] = {kind = .Armor, biped = 0x200, etyp = SHIELD}
	db.equip_slots[gamedb.Form_ID(Gear.Greatsword)] = {kind = .Weapon, etyp = BOTH_HANDS, weapon_type = 5}
	db.equip_slots[gamedb.Form_ID(Gear.Dagger)] = {kind = .Weapon, etyp = EITHER_HAND, weapon_type = 2}
	db.equip_slots[gamedb.Form_ID(Gear.Mace)] = {kind = .Weapon, etyp = EITHER_HAND, weapon_type = 4}
	db.equip_slots[gamedb.Form_ID(Gear.Flames)] = {kind = .Spell, etyp = gamedb.EQUP_LEFT_HAND}
	db.equip_types = make(map[gamedb.Form_ID]gamedb.Equip_Type, context.temp_allocator)
	db.equip_types[SHIELD] = {parents = LEFT[:], use_all = true}
	db.equip_types[BOTH_HANDS] = {parents = TWO_HANDS[:], use_all = true}
	db.equip_types[EITHER_HAND] = {parents = TWO_HANDS[:]}
	db.equip_slots[gamedb.Form_ID(Gear.Robes)] = {kind = .Armor, biped = 0x04}
}

@(private = "file")
hands :: proc(ws: ^worldstate.World_State, db: ^gamedb.DB, actor: gamedb.Form_ID) -> [2]gamedb.Form_ID {
	return {worldstate.in_slot(ws, db, actor, .LeftHand), worldstate.in_slot(ws, db, actor, .RightHand)}
}

// Armor sharing a slot comes off first; a shield takes the left hand and a both-hands weapon takes
// both; an either-hand item goes to the hand asked for, else the right.
@(test)
test_equip_slots :: proc(t: ^testing.T) {
	A :: gamedb.Form_ID(0xA)
	F :: proc(g: Gear) -> gamedb.Form_ID {return gamedb.Form_ID(g)}
	db: gamedb.DB
	gear_db(&db)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.equip(&ws, &db, A, F(.Helmet))
	worldstate.equip(&ws, &db, A, F(.Hood))
	testing.expect(t, !worldstate.is_equipped(&ws, &db, A, F(.Helmet)) && worldstate.is_equipped(&ws, &db, A, F(.Hood)), "hood replaces helmet")
	testing.expect(t, len(ws.equip_changes) == 3 && !ws.equip_changes[1].on && ws.equip_changes[2].on, "off before on")

	worldstate.equip(&ws, &db, A, F(.Shield))
	worldstate.equip(&ws, &db, A, F(.Greatsword))
	testing.expect(t, !worldstate.is_equipped(&ws, &db, A, F(.Shield)) && hands(&ws, &db, A) == {F(.Greatsword), F(.Greatsword)}, "two-hander takes both hands")
	worldstate.equip(&ws, &db, A, F(.Flames))
	testing.expect(t, hands(&ws, &db, A) == {F(.Flames), 0}, "a left-hand spell clears the two-hander")

	worldstate.unequip_all(&ws, &db, A)
	worldstate.equip(&ws, &db, A, F(.Dagger))
	worldstate.equip(&ws, &db, A, F(.Mace))
	testing.expect(t, hands(&ws, &db, A) == {0, F(.Mace)}, "either-hand replaces the right")
	worldstate.equip(&ws, &db, A, F(.Dagger), gamedb.Slot.LeftHand)
	testing.expect(t, hands(&ws, &db, A) == {F(.Dagger), F(.Mace)}, "the left hand when asked")

	worldstate.equip(&ws, &db, A, F(.Robes), keep = true)
	testing.expect(t, worldstate.equip(&ws, &db, A, F(.Hood)), "a kept item only blocks what shares its slot")
	db.equip_slots[F(.Hood)] = {kind = .Armor, biped = 0x07}
	testing.expect(t, !worldstate.equip(&ws, &db, A, F(.Hood)), "a kept item blocks another equip")
}

// An actor wears its outfit on the first read, and the gear counts as its items; the worn set
// survives a save, and a reset puts the outfit back.
@(test)
test_outfit_worn :: proc(t: ^testing.T) {
	NPC :: gamedb.Form_ID(0x200)
	OUTFIT :: gamedb.Form_ID(0x201)
	db: gamedb.DB
	gear_db(&db)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[NPC] = {outfit = OUTFIT}
	db.outfits = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.outfits[OUTFIT] = {gamedb.Form_ID(Gear.Robes), gamedb.Form_ID(Gear.Hood)}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, gamedb.Form_ID(Gear.Robes)), "outfit worn")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, NPC, gamedb.Form_ID(Gear.Hood)), 1)
	testing.expect_value(t, len(ws.equip_changes), 0)
	worldstate.unequip(&ws, &db, NPC, gamedb.Form_ID(Gear.Hood))

	path := "test_equipment.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	testing.expect(t, !worldstate.is_equipped(&ws, &db, NPC, gamedb.Form_ID(Gear.Hood)) && worldstate.is_equipped(&ws, &db, NPC, gamedb.Form_ID(Gear.Robes)), "worn set saved")

	worldstate.drop_inventory(&ws, NPC)
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, gamedb.Form_ID(Gear.Hood)), "a reset puts the outfit back")
}

// SetOutfit takes the old outfit's gear off and out of the pack, puts the new gear in and on, and
// the change survives a save and a reset.
@(test)
test_set_outfit :: proc(t: ^testing.T) {
	NPC :: gamedb.Form_ID(0x200)
	OLD :: gamedb.Form_ID(0x201)
	NEW :: gamedb.Form_ID(0x202)
	hood, helmet, dagger := gamedb.Form_ID(Gear.Hood), gamedb.Form_ID(Gear.Helmet), gamedb.Form_ID(Gear.Dagger)
	db: gamedb.DB
	gear_db(&db)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[NPC] = {outfit = OLD}
	db.outfits = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.outfits[OLD] = {hood}
	db.outfits[NEW] = {helmet}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.equip(&ws, &db, NPC, dagger) // not outfit gear: stays
	worldstate.set_outfit(&ws, &db, NPC, NEW)
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, helmet), "new gear worn")
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, dagger), "other gear kept")
	testing.expect_value(t, worldstate.inv_count(&ws, &db, NPC, hood), 0)
	testing.expect_value(t, worldstate.inv_count(&ws, &db, NPC, helmet), 1)

	path := "test_set_outfit.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	worldstate.drop_inventory(&ws, NPC)
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, helmet) && !worldstate.is_equipped(&ws, &db, NPC, hood), "a reset keeps the new outfit")
}

// An NPC puts armor from its pack back on where nothing is worn.
@(test)
test_wear_spare_armor :: proc(t: ^testing.T) {
	NPC :: gamedb.Form_ID(0x200)
	OUTFIT :: gamedb.Form_ID(0x201)
	hood := gamedb.Form_ID(Gear.Hood)
	db: gamedb.DB
	gear_db(&db)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[NPC] = {outfit = OUTFIT}
	db.outfits = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.outfits[OUTFIT] = {hood}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.unequip(&ws, &db, NPC, hood)
	worldstate.wear_spare_armor(&ws, &db, NPC)
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, hood), "outfit back on")
}

// A sleeper changes into its sleep outfit and back on waking, and a save between keeps it straight.
@(test)
test_sleep_outfit :: proc(t: ^testing.T) {
	NPC :: gamedb.Form_ID(0x200)
	DAY :: gamedb.Form_ID(0x201)
	NIGHT :: gamedb.Form_ID(0x202)
	hood, robes := gamedb.Form_ID(Gear.Hood), gamedb.Form_ID(Gear.Robes)
	db: gamedb.DB
	gear_db(&db)
	db.actors = make(map[gamedb.Form_ID]gamedb.Actor_Base, context.temp_allocator)
	db.actors[NPC] = {outfit = DAY, sleep_outfit = NIGHT}
	db.outfits = make(map[gamedb.Form_ID][]gamedb.Form_ID, context.temp_allocator)
	db.outfits[DAY] = {hood}
	db.outfits[NIGHT] = {robes}
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)

	worldstate.set_sleeping(&ws, &db, NPC, true)
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, robes) && !worldstate.is_equipped(&ws, &db, NPC, hood), "asleep in the sleep outfit")
	testing.expect_value(t, worldstate.sleep_state(&ws, NPC), worldstate.SEATED)

	path := "test_sleep_outfit.skysave"
	defer os.remove(path)
	testing.expect(t, worldstate.save_to_file(&ws, path, {save_number = 1}), "save")
	_, ok := worldstate.load_from_file(&ws, path)
	testing.expect(t, ok, "load")
	worldstate.set_sleeping(&ws, &db, NPC, false)
	testing.expect(t, worldstate.is_equipped(&ws, &db, NPC, hood) && !worldstate.is_equipped(&ws, &db, NPC, robes), "awake in the day outfit")
}

// No two biped bits share an engine slot, so every plugin item keeps exactly its Skyrim conflicts.
@(test)
test_biped_slots_disjoint :: proc(t: ^testing.T) {
	seen: gamedb.Slots
	for s, i in gamedb.BIPED_SLOTS {
		testing.expectf(t, s != {} && s & seen == {}, "biped slot %d", 30 + i)
		seen += s
	}
}
