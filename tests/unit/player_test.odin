package unit_tests

// PlayerRef (0x14) means the actor the player controls: taking over an NPC moves it there.

import "core:slice"
import "core:testing"
import "../../src/conditions"
import "../../src/formid"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

@(test)
test_player_ref_follows_control :: proc(t: ^testing.T) {
	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	testing.expect_value(t, ws.player, formid.START_CHARACTER)

	NPC :: gamedb.Form_ID(0x0001_2345)
	QUEST :: gamedb.Form_ID(0xA00)
	ws.player = NPC
	testing.expect_value(t, worldstate.resolve(&ws, formid.PLAYER), NPC)
	testing.expect_value(t, worldstate.resolve(&ws, QUEST), QUEST)

	alias, _ := formid.alias_handle(QUEST, 0)
	worldstate.fill_alias(&ws, alias, formid.PLAYER)
	testing.expect_value(t, worldstate.alias_ref(&ws, QUEST, 0), NPC)
	testing.expect(t, slice.contains(worldstate.aliases_of(&ws, NPC), alias), "a PlayerRef alias holds the controlled actor")
	testing.expect_value(t, len(worldstate.aliases_of(&ws, formid.START_CHARACTER)), 0)

	vm: slua.VM
	ok := slua.init(&vm, &reg, script.Call{ws = &ws, db = &db})
	defer slua.destroy(&vm)
	testing.expect(t, ok, "VM init")
	testing.expect(t, slua.do_string(&vm, `assert(ref(0x14) == ref(0x12345)); assert(ref(0x14) ~= ref(0x12346))`), "PlayerRef equals the controlled actor")
	testing.expect(t, slua.do_string(&vm, `Game.GetPlayer():SetScale(2.0)`), "a method on PlayerRef")
	d, _ := worldstate.get(&ws, NPC)
	testing.expect_value(t, d.scale, f32(2))

	ctx := conditions.Context{db = &db, ws = &ws, subject = NPC}
	is_player := [1]gamedb.Condition{{function = 136, op = .Equal, value = 1, param1 = u64(formid.PLAYER)}} // GetIsReference PlayerRef
	testing.expect(t, conditions.all(&ctx, is_player[:]), "GetIsReference PlayerRef on the controlled actor")
}
