package script

// Crime natives. Vanilla names them for the player: a Faction's crime gold is ref 0x14's bounty.

import "../formid"
import "../worldstate"

register_crime :: proc(reg: ^Registry) {
	register(reg, "Faction", "GetCrimeGold", n_get_crime_gold)
	register(reg, "Faction", "GetCrimeGoldViolent", n_get_crime_gold_violent)
	register(reg, "Faction", "GetCrimeGoldNonViolent", n_get_crime_gold_nonviolent)
	register(reg, "Faction", "SetCrimeGold", n_set_crime_gold)
	register(reg, "Faction", "SetCrimeGoldViolent", n_set_crime_gold_violent)
	register(reg, "Faction", "ModCrimeGold", n_mod_crime_gold)
	register(reg, "Faction", "CanPayCrimeGold", n_can_pay_crime_gold)
	register(reg, "Faction", "PlayerPayCrimeGold", n_player_pay_crime_gold)
	register(reg, "Faction", "SetPlayerEnemy", n_set_player_enemy)
	register(reg, "Game", "SetPlayerReportCrime", n_set_player_report_crime)
}

@(private = "file")
player_bounty :: proc(c: ^Call) -> worldstate.Bounty {
	return worldstate.wanted(c.ws, formid.PLAYER, c.self).bounty
}

n_get_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.total(player_bounty(c))
}

n_get_crime_gold_violent :: proc(c: ^Call, args: []Value) -> Value {
	return player_bounty(c).violent
}

n_get_crime_gold_nonviolent :: proc(c: ^Call, args: []Value) -> Value {
	return player_bounty(c).nonviolent
}

n_set_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	b := player_bounty(c)
	b.nonviolent = arg_i32(args, 0, 0)
	worldstate.set_faction_bounty(c.ws, formid.PLAYER, c.self, b)
	return nil
}

n_set_crime_gold_violent :: proc(c: ^Call, args: []Value) -> Value {
	b := player_bounty(c)
	b.violent = arg_i32(args, 0, 0)
	worldstate.set_faction_bounty(c.ws, formid.PLAYER, c.self, b)
	return nil
}

// ModCrimeGold(aiAmount, abViolent = false)
n_mod_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	b := player_bounty(c)
	if arg_bool(args, 1, false) {b.violent += arg_i32(args, 0, 0)} else {b.nonviolent += arg_i32(args, 0, 0)}
	worldstate.set_faction_bounty(c.ws, formid.PLAYER, c.self, b)
	return nil
}

n_can_pay_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	return worldstate.inv_count(c.ws, c.db, formid.PLAYER, formid.GOLD) >= worldstate.total(player_bounty(c))
}

// PlayerPayCrimeGold(abRemoveStolenItems = true, abGoToJail = true): the gold goes and the bounty
// clears.
// (hole pay-fine-args :tags combat :sev gap :needs (crime-owners jail)) abRemoveStolenItems takes nothing (no item is marked stolen) and abGoToJail does nothing; unsourced what it does after a paid fine.
n_player_pay_crime_gold :: proc(c: ^Call, args: []Value) -> Value {
	move_items(c, {base = formid.GOLD, from = formid.PLAYER, count = worldstate.total(player_bounty(c))})
	worldstate.pay_bounty(c.ws, formid.PLAYER, c.self)
	return nil
}

n_set_player_enemy :: proc(c: ^Call, args: []Value) -> Value {
	w := worldstate.wanted(c.ws, formid.PLAYER, c.self)
	w.enemy = arg_bool(args, 0, true)
	worldstate.set_wanted(c.ws, formid.PLAYER, c.self, w)
	return nil
}

n_set_player_report_crime :: proc(c: ^Call, args: []Value) -> Value {
	worldstate.set_reports_crime(c.ws, formid.PLAYER, arg_bool(args, 0, true))
	return nil
}
