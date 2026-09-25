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

@(private = "file")
gear_db :: proc(db: ^gamedb.DB) {
	db.equip_slots = make(map[gamedb.Form_ID]gamedb.Equip_Slot, context.temp_allocator)
	db.equip_slots[gamedb.Form_ID(Gear.Helmet)] = {kind = .Armor, biped = 0x01}
	db.equip_slots[gamedb.Form_ID(Gear.Hood)] = {kind = .Armor, biped = 0x03}
	db.equip_slots[gamedb.Form_ID(Gear.Shield)] = {kind = .Armor, biped = 0x200, etyp = gamedb.EQUP_SHIELD}
	db.equip_slots[gamedb.Form_ID(Gear.Greatsword)] = {kind = .Weapon, etyp = gamedb.EQUP_BOTH_HANDS, weapon_type = 5}
	db.equip_slots[gamedb.Form_ID(Gear.Dagger)] = {kind = .Weapon, etyp = gamedb.EQUP_EITHER_HAND, weapon_type = 2}
	db.equip_slots[gamedb.Form_ID(Gear.Mace)] = {kind = .Weapon, etyp = gamedb.EQUP_EITHER_HAND, weapon_type = 4}
	db.equip_slots[gamedb.Form_ID(Gear.Flames)] = {kind = .Spell, etyp = gamedb.EQUP_LEFT_HAND}
	db.equip_slots[gamedb.Form_ID(Gear.Robes)] = {kind = .Armor, biped = 0x04}
}

@(private = "file")
hands :: proc(left, right: gamedb.Form_ID) -> [worldstate.Hand]gamedb.Form_ID {
	return {.Left = left, .Right = right, .Voice = 0}
}

// Armor sharing a slot comes off first; a shield takes the left hand and a both-hands weapon takes
// both; an either-hand item goes right, then left, then replaces right.
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
	eq := worldstate.equipment(&ws, &db, A)
	testing.expect(t, !worldstate.is_equipped(&ws, &db, A, F(.Shield)) && eq.hands == hands(F(.Greatsword), F(.Greatsword)), "two-hander takes both hands")
	worldstate.equip(&ws, &db, A, F(.Flames))
	testing.expect(t, eq.hands == hands(F(.Flames), 0), "a left-hand spell clears the two-hander")

	worldstate.unequip_all(&ws, &db, A)
	worldstate.equip(&ws, &db, A, F(.Dagger))
	worldstate.equip(&ws, &db, A, F(.Mace))
	testing.expect(t, eq.hands == hands(F(.Mace), F(.Dagger)), "either-hand fills right, then left")

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
